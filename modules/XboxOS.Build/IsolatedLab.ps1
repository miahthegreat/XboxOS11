# Milestone 6B — Isolated disposable-image lab infrastructure (simulation only).
# No Hyper-V provisioning, no DISM mutation, Layer D remains disabled.

$script:XboxOSIsolatedLabEngineVersion = '6.1.1-b'
$script:XboxOSLabTopologySchemaVersion = 'lab-topology-v1'
$script:XboxOSLabIsolationSchemaVersion = 'lab-isolation-v1.1'
$script:XboxOSLabOwnershipSchemaVersion = 'lab-ownership-v1.1'
$script:XboxOSLabSnapshotSchemaVersion = 'lab-snapshot-v1'
$script:XboxOSLabTransactionSchemaVersion = 'lab-transaction-v1'
$script:XboxOSLabEvidenceSchemaVersion = 'lab-evidence-v1.1'
$script:XboxOSLabKeyPolicySchemaVersion = 'lab-key-policy-v1'
$script:XboxOSLabEvidenceChainSchemaVersion = 'lab-evidence-chain-v1'

$script:XboxOSLabTransactionStates = @(
    'InfrastructurePlanned',
    'ConfigurationValidated',
    'AwaitingReview',
    'LabProvisioningBlocked',
    'SimulationReady',
    'SimulationCompleted',
    'Aborted',
    'RecoveryRequired',
    # Named only so fail-closed tests can assert they are unreachable:
    'RealProvisioning',
    'WritableExecution',
    'LiveMutation'
)

$script:XboxOSLabTransactionTransitions = @{
    'InfrastructurePlanned'   = @('ConfigurationValidated', 'LabProvisioningBlocked', 'Aborted')
    'ConfigurationValidated'  = @('AwaitingReview', 'SimulationReady', 'LabProvisioningBlocked', 'Aborted')
    'AwaitingReview'          = @('SimulationReady', 'LabProvisioningBlocked', 'Aborted')
    'SimulationReady'         = @('SimulationCompleted', 'LabProvisioningBlocked', 'Aborted', 'RecoveryRequired')
    'SimulationCompleted'     = @('LabProvisioningBlocked', 'RecoveryRequired', 'Aborted')
    'LabProvisioningBlocked'  = @('RecoveryRequired', 'Aborted')
    'Aborted'                 = @('RecoveryRequired')
    'RecoveryRequired'        = @()
    'RealProvisioning'        = @()
    'WritableExecution'       = @()
    'LiveMutation'            = @()
}

$script:XboxOSLabUsedNonces = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

function Get-XboxOSIsolatedLabEngineVersion { return $script:XboxOSIsolatedLabEngineVersion }
function Get-XboxOSLabTopologySchemaVersion { return $script:XboxOSLabTopologySchemaVersion }
function Get-XboxOSLabIsolationSchemaVersion { return $script:XboxOSLabIsolationSchemaVersion }
function Get-XboxOSLabOwnershipSchemaVersion { return $script:XboxOSLabOwnershipSchemaVersion }
function Get-XboxOSLabSnapshotSchemaVersion { return $script:XboxOSLabSnapshotSchemaVersion }
function Get-XboxOSLabTransactionSchemaVersion { return $script:XboxOSLabTransactionSchemaVersion }
function Get-XboxOSLabEvidenceSchemaVersion { return $script:XboxOSLabEvidenceSchemaVersion }
function Get-XboxOSLabKeyPolicySchemaVersion { return $script:XboxOSLabKeyPolicySchemaVersion }
function Get-XboxOSLabEvidenceChainSchemaVersion { return $script:XboxOSLabEvidenceChainSchemaVersion }

function Get-XboxOSLabRealProvisioningEnabled { return $false }
function Get-XboxOSLabHypervisorCommandsInvoked { return $false }

function Get-XboxOSLabEvidenceLabel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ExternalValidated', 'InlineSimulation', 'NotValidated')]
        [string]$EvidenceMode
    )

    switch ($EvidenceMode) {
        'ExternalValidated' { return 'ExternalValidatedEvidence' }
        'InlineSimulation' { return 'InlineSimulationEvidence' }
        default { return 'NotValidated' }
    }
}

function Assert-XboxOSIsolatedLabSafetyInvariants {
    [CmdletBinding()]
    param([object]$Report = $null)

    Assert-XboxOSExperimentSafetyInvariants -Report $Report
    if (Get-XboxOSLabRealProvisioningEnabled) {
        throw 'Safety invariant violated: labRealProvisioningEnabled must be False.'
    }
    if (Get-XboxOSLabHypervisorCommandsInvoked) {
        throw 'Safety invariant violated: labHypervisorCommandsInvoked must be False.'
    }
    if ($null -eq $Report) { return }
    foreach ($flag in @('labRealProvisioningEnabled', 'labHypervisorCommandsInvoked', 'layerDActivated')) {
        if ($Report.PSObject.Properties[$flag] -and $Report.$flag) {
            throw ("Safety invariant violated: {0} must be False." -f $flag)
        }
    }
}

function Import-XboxOSLabTopologyCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Lab topology catalog not found: $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$raw.schemaVersion -ne (Get-XboxOSLabTopologySchemaVersion)) {
        throw ("Lab topology schema mismatch: expected {0}, got {1}" -f (Get-XboxOSLabTopologySchemaVersion), $raw.schemaVersion)
    }
    foreach ($req in @('provider', 'vm', 'paths', 'network', 'credentials', 'snapshots', 'cleanup')) {
        if (-not $raw.PSObject.Properties[$req] -or $null -eq $raw.$req) {
            throw ("Lab topology missing required section '{0}'." -f $req)
        }
    }
    return $raw
}

function Test-XboxOSLabPathHasReparsePoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    # Simulation-safe: inspect existing path attributes only; do not create paths.
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ present = $false; hasReparsePoint = $false; notes = @('Path does not exist; reparse check deferred.') }
    }
    try {
        $item = Get-Item -LiteralPath $Path -Force
        $reparse = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        return [pscustomobject]@{ present = $true; hasReparsePoint = $reparse; notes = @() }
    }
    catch {
        return [pscustomobject]@{ present = $true; hasReparsePoint = $true; notes = @("Unable to inspect attributes: $($_.Exception.Message)") }
    }
}

function Test-XboxOSLabInfrastructureBoundaries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Topology,
        [string]$ExpectedIsoSha256 = '',
        [string]$OwnerId = 'lab-sim-operator',
        [switch]$SimulateExistingMountConflict,
        [switch]$SimulateStaleHive
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $paths = $Topology.paths

    foreach ($name in @('workspaceRoot', 'evidenceRoot', 'virtualDiskRoot', 'sourceIsoPath')) {
        if (-not $paths.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$paths.$name)) {
            [void]$errors.Add(("Topology paths.{0} is required." -f $name))
        }
    }

    $canon = @{}
    foreach ($name in @('workspaceRoot', 'evidenceRoot', 'virtualDiskRoot', 'sourceIsoPath')) {
        if (-not $paths.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$paths.$name)) { continue }
        $shape = Test-XboxOSExperimentPathIsUnsafeShape -Path ([string]$paths.$name)
        if (-not $shape.valid) {
            foreach ($e in @($shape.errors)) { [void]$errors.Add(("paths.{0}: {1}" -f $name, $e)) }
            continue
        }
        $canon[$name] = $shape.canonical
        if (Test-XboxOSCloudSynchronizedPath -Path $shape.canonical) {
            [void]$errors.Add(("paths.{0} must be outside OneDrive/cloud-sync locations." -f $name))
        }
        $rp = Test-XboxOSLabPathHasReparsePoint -Path $shape.canonical
        if ($rp.hasReparsePoint) {
            [void]$errors.Add(("paths.{0} is a reparse point / junction / symlink boundary; rejected." -f $name))
        }
    }

    $winRoot = $env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($winRoot)) { $winRoot = 'C:\Windows' }
    foreach ($name in @('workspaceRoot', 'evidenceRoot', 'virtualDiskRoot')) {
        if (-not $canon.ContainsKey($name)) { continue }
        try {
            if (Test-XboxOSPathEqualsOrUnder -Path $canon[$name] -ParentPath $winRoot) {
                [void]$errors.Add(("paths.{0} must not target host Windows directories." -f $name))
            }
        }
        catch {
            [void]$errors.Add(("Unable to validate paths.{0} against host Windows root." -f $name))
        }
        # Reserved system volumes heuristic
        if ($canon[$name] -match '(?i)^[A-Za-z]:\\(Windows|Program Files|Program Files \(x86\)|ProgramData)(\\+|$)') {
            [void]$errors.Add(("paths.{0} targets a reserved host system volume area." -f $name))
        }
    }

    if ($canon.ContainsKey('workspaceRoot') -and $canon.ContainsKey('sourceIsoPath')) {
        $isoParent = Split-Path -Parent $canon['sourceIsoPath']
        if ($isoParent) {
            try {
                if (Test-XboxOSPathEqualsOrUnder -Path $canon['workspaceRoot'] -ParentPath $isoParent) {
                    [void]$errors.Add('Workspace must not be under the source-image parent directory.')
                }
            }
            catch {
                [void]$errors.Add(("Unable to evaluate workspace against source-image parent: {0}" -f $_.Exception.Message))
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedIsoSha256) -and $ExpectedIsoSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
            [void]$errors.Add('ExpectedIsoSha256 must be a 64-character hex SHA-256 when provided.')
        }
        $wsUnderIso = Test-XboxOSPathEqualsOrUnder -Path $canon['workspaceRoot'] -ParentPath $canon['sourceIsoPath']
        $isoUnderWs = Test-XboxOSPathEqualsOrUnder -Path $canon['sourceIsoPath'] -ParentPath $canon['workspaceRoot']
        if ($wsUnderIso -or $isoUnderWs) {
            [void]$errors.Add('Source/workspace path overlap is forbidden.')
        }
    }

    # Non-overlapping roots among workspace, evidence, vhd
    $roots = @('workspaceRoot', 'evidenceRoot', 'virtualDiskRoot') | Where-Object { $canon.ContainsKey($_) }
    for ($i = 0; $i -lt $roots.Count; $i++) {
        for ($j = $i + 1; $j -lt $roots.Count; $j++) {
            $a = $canon[$roots[$i]]; $b = $canon[$roots[$j]]
            if ((Test-XboxOSPathEqualsOrUnder -Path $a -ParentPath $b) -or (Test-XboxOSPathEqualsOrUnder -Path $b -ParentPath $a)) {
                [void]$errors.Add(("Path roots overlap: {0} and {1}." -f $roots[$i], $roots[$j]))
            }
        }
    }

    if ($SimulateExistingMountConflict) {
        [void]$errors.Add('Existing mount-state conflict simulated; fail closed.')
    }
    if ($SimulateStaleHive) {
        [void]$errors.Add('Untracked registry hive ownership simulated; fail closed.')
    }

    $wsToken = ''
    if ($canon.ContainsKey('workspaceRoot')) {
        $ownedWim = Join-Path $canon['workspaceRoot'] 'install-pro-disposable.wim'
        $wsToken = Get-XboxOSUtf8Sha256Hex -Text ('{0}|{1}|{2}' -f $OwnerId, $canon['workspaceRoot'], $ownedWim)
    }

    $net = $Topology.network
    if ([bool]$net.productionBridgeAllowed) {
        [void]$errors.Add('Production network bridge is forbidden by infrastructure boundary policy.')
    }
    if ([bool]$net.hostAdminSharesAllowed) {
        [void]$errors.Add('Host administrative share access is forbidden.')
    }

    return [pscustomobject]@{
        schemaVersion                 = 'lab-boundary-v1'
        valid                         = [bool]($errors.Count -eq 0)
        errors                        = [string[]]@($errors.ToArray())
        warnings                      = [string[]]@($warnings.ToArray())
        canonicalPaths                = [pscustomobject]$canon
        ownedWorkspaceIdentity        = $wsToken
        sourceIsoImmutable            = $true
        expectedIsoSha256             = $ExpectedIsoSha256
        filesystemMutationPerformed   = $false
        hypervisorCommandsInvoked     = $false
        planningPermissionOnly        = $true
        notes                         = @(
            'Valid configuration is permission to plan infrastructure, not permission to create it.'
            'No Hyper-V/DISM commands were invoked.'
        )
    }
}

function Test-XboxOSLabVmIsolationPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Topology,
        [switch]$RequireOnlineMicrosoftServices
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]
    $vm = $Topology.vm
    $net = $Topology.network
    $cred = $Topology.credentials

    if (-not [bool]$vm.dedicatedDisposable) {
        [void]$errors.Add('VM must be a dedicated disposable instance.')
    }
    if ([bool]$vm.productionDomainMembership) {
        [void]$errors.Add('Production domain membership is forbidden.')
    }
    if ([bool]$cred.inheritHostCredentials) {
        [void]$errors.Add('Inherited host credentials are forbidden.')
    }
    if ($net.PSObject.Properties['inheritedProductionCredentialsAllowed'] -and [bool]$net.inheritedProductionCredentialsAllowed) {
        [void]$errors.Add('Network policy must not allow inherited production credentials.')
    }
    if ([bool]$net.unrestrictedSharedFoldersAllowed) {
        [void]$errors.Add('Unrestricted shared folders are forbidden.')
    }
    if ([bool]$net.productionBridgeAllowed) {
        [void]$errors.Add('Production network bridge is forbidden.')
    }
    if ([bool]$net.hostAdminSharesAllowed) {
        [void]$errors.Add('Access to host administrative shares is forbidden.')
    }
    if (-not $net.outboundAllowlist -or @($net.outboundAllowlist).Count -eq 0) {
        [void]$errors.Add('Explicit outbound network allowlist is required.')
    }
    if ([bool]$cred.storeSecretsInRepo) {
        [void]$errors.Add('Storing guest secrets in the repository is forbidden.')
    }
    if ([string]$cred.guestCredentialMode -ne 'EphemeralLabOnly') {
        [void]$errors.Add('Guest credentials must be EphemeralLabOnly.')
    }

    $offlineDefault = [bool]$net.offlineValidationDefault
    if ($RequireOnlineMicrosoftServices -and $offlineDefault) {
        [void]$notes.Add('Online Microsoft Store/Xbox/WU tests require a separately reviewed connectivity profile; default remains offline validation.')
    }
    elseif ($offlineDefault) {
        [void]$notes.Add('Offline validation is the default; Store/Xbox auth/WU connectivity tests remain EnvironmentLimited until a reviewed online profile exists.')
    }

    $policyValid = [bool]($errors.Count -eq 0)
    [void]$notes.Add('PolicyValidated means the declared topology satisfies isolation policy; it does not prove a virtual switch exists or that network isolation was inspected.')
    [void]$notes.Add('Milestone 6B does not query or modify the hypervisor; HypervisorNotInspected and NetworkIsolationNotVerified are expected.')

    return [pscustomobject]@{
        schemaVersion                        = Get-XboxOSLabIsolationSchemaVersion
        valid                                = $policyValid
        policyValidationStatus               = $(if ($policyValid) { 'PolicyValidated' } else { 'PolicyInvalid' })
        configurationStatus                  = 'ConfigurationDeclared'
        hypervisorInspectionStatus           = 'HypervisorNotInspected'
        networkIsolationVerificationStatus   = 'NetworkIsolationNotVerified'
        environmentLimitationStatus          = 'EnvironmentLimited'
        actualIsolationVerified              = $false
        errors                               = [string[]]@($errors.ToArray())
        notes                                = [string[]]@($notes.ToArray())
        dedicatedDisposableVm                = [bool]$vm.dedicatedDisposable
        productionDomainMembership           = [bool]$vm.productionDomainMembership
        isolationMode                        = [string]$net.isolationMode
        declaredIsolationMode                = [string]$net.isolationMode
        offlineValidationDefault             = $offlineDefault
        inventsFunctionalResults             = $false
        futureEvidenceSlots                  = [pscustomobject]@{
            vmEvidence             = $null
            virtualSwitchEvidence  = $null
            firewallEvidence       = $null
            networkingEvidence     = $null
        }
    }
}

function New-XboxOSLabOwnershipRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LabId,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$OwnerId,
        [Parameter(Mandatory)][string]$PlanHash,
        [Parameter(Mandatory)][string]$ReadinessBindingDigest,
        [Parameter(Mandatory)][string]$SourceIsoSha256,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$ExperimentPlanHash,
        [Parameter(Mandatory)][string]$InventoryFingerprint,
        [string[]]$EvidenceReferences = @()
    )

    foreach ($pair in @(
            @{ n = 'LabId'; v = $LabId },
            @{ n = 'VmId'; v = $VmId },
            @{ n = 'WorkspaceId'; v = $WorkspaceId },
            @{ n = 'PlanHash'; v = $PlanHash },
            @{ n = 'ReadinessBindingDigest'; v = $ReadinessBindingDigest },
            @{ n = 'SourceIsoSha256'; v = $SourceIsoSha256 },
            @{ n = 'ExperimentPlanHash'; v = $ExperimentPlanHash },
            @{ n = 'InventoryFingerprint'; v = $InventoryFingerprint }
        )) {
        if ([string]::IsNullOrWhiteSpace($pair.v)) {
            throw ("Ownership record missing required identity field: {0}" -f $pair.n)
        }
    }

    $tokenMaterial = '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}' -f `
        $LabId, $VmId, $WorkspaceId, $OwnerId, $WorkspaceRoot, $SourceIsoSha256, `
        $PlanHash, $ReadinessBindingDigest, $ExperimentPlanHash, $InventoryFingerprint
    $token = Get-XboxOSUtf8Sha256Hex -Text $tokenMaterial
    $bindingDigest = Get-XboxOSUtf8Sha256Hex -Text (ConvertTo-XboxOSCanonicalJson -Value ([ordered]@{
                labId                  = $LabId
                vmId                   = $VmId
                workspaceId            = $WorkspaceId
                planHash               = $PlanHash
                readinessBindingDigest = $ReadinessBindingDigest
                experimentPlanHash     = $ExperimentPlanHash
                inventoryFingerprint   = $InventoryFingerprint
                sourceIsoSha256        = $SourceIsoSha256
            }))

    return [pscustomobject]@{
        schemaVersion            = Get-XboxOSLabOwnershipSchemaVersion
        labId                    = $LabId
        vmId                     = $VmId
        workspaceId              = $WorkspaceId
        ownerId                  = $OwnerId
        ownershipToken           = $token
        ownershipBindingDigest   = $bindingDigest
        planHash                 = $PlanHash
        readinessBindingDigest   = $ReadinessBindingDigest
        experimentPlanHash       = $ExperimentPlanHash
        inventoryFingerprint     = $InventoryFingerprint
        sourceIsoSha256          = $SourceIsoSha256
        workspaceRoot            = $WorkspaceRoot
        recoveryState            = 'NotRequired'
        evidenceReferences       = @($EvidenceReferences)
        ownershipIsAuthorization = $false
        realProvisioningEnabled  = $false
        notes                    = @(
            'Ownership digests are integrity checks, not trusted authorization signatures.'
            'Layer D remains disabled.'
        )
    }
}

function Test-XboxOSLabOwnershipRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Record,
        [Parameter(Mandatory)][string]$ExpectedLabId,
        [Parameter(Mandatory)][string]$ExpectedVmId,
        [Parameter(Mandatory)][string]$ExpectedPlanHash,
        [Parameter(Mandatory)][string]$ExpectedReadinessBindingDigest,
        [Parameter(Mandatory)][string]$ExpectedSourceIsoSha256,
        [string]$ExpectedExperimentPlanHash = '',
        [string]$ExpectedInventoryFingerprint = ''
    )

    $errors = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace([string]$Record.labId) -or [string]::IsNullOrWhiteSpace([string]$Record.vmId) -or [string]::IsNullOrWhiteSpace([string]$Record.workspaceId)) {
        [void]$errors.Add('Ambiguous or missing lab/VM/workspace identity.')
    }
    if ([string]$Record.labId -ne $ExpectedLabId) { [void]$errors.Add('Lab identity mismatch.') }
    if ([string]$Record.vmId -ne $ExpectedVmId) { [void]$errors.Add('VM identity mismatch.') }
    if ([string]$Record.planHash -ne $ExpectedPlanHash) { [void]$errors.Add('Plan hash mismatch on ownership record.') }
    if ([string]$Record.readinessBindingDigest -ne $ExpectedReadinessBindingDigest) { [void]$errors.Add('Readiness binding digest mismatch on ownership record.') }
    if ([string]$Record.sourceIsoSha256 -ne $ExpectedSourceIsoSha256) { [void]$errors.Add('Source ISO hash mismatch on ownership record.') }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedExperimentPlanHash)) {
        if (-not $Record.PSObject.Properties['experimentPlanHash'] -or [string]$Record.experimentPlanHash -ne $ExpectedExperimentPlanHash) {
            [void]$errors.Add('Experiment plan hash mismatch on ownership record.')
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedInventoryFingerprint)) {
        if (-not $Record.PSObject.Properties['inventoryFingerprint'] -or [string]$Record.inventoryFingerprint -ne $ExpectedInventoryFingerprint) {
            [void]$errors.Add('Inventory fingerprint mismatch on ownership record.')
        }
    }
    $recomputed = Get-XboxOSUtf8Sha256Hex -Text ('{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}' -f `
            $Record.labId, $Record.vmId, $Record.workspaceId, $Record.ownerId, $Record.workspaceRoot, $Record.sourceIsoSha256, `
            $Record.planHash, $Record.readinessBindingDigest, $Record.experimentPlanHash, $Record.inventoryFingerprint)
    if ([string]$Record.ownershipToken -ne $recomputed) {
        [void]$errors.Add('Forged or incorrect lab ownership token.')
    }
    if ($Record.PSObject.Properties['ownershipIsAuthorization'] -and [bool]$Record.ownershipIsAuthorization) {
        [void]$errors.Add('Ownership record must not claim authorization signature trust.')
    }
    return [pscustomobject]@{
        valid  = [bool]($errors.Count -eq 0)
        errors = [string[]]@($errors.ToArray())
    }
}

function New-XboxOSLabSnapshotRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Ownership,
        [Parameter(Mandatory)][ValidateSet('PreExperimentBaseline', 'PostInfrastructureValidation', 'PreFunctionalValidation', 'RecoveryCheckpoint')]
        [string]$Purpose,
        [string[]]$EvidenceReferences = @()
    )

    $snapshotId = ('snap-{0}-{1}' -f $Purpose, [guid]::NewGuid().ToString('N').Substring(0, 12))
    return [pscustomobject]@{
        schemaVersion          = Get-XboxOSLabSnapshotSchemaVersion
        snapshotId             = $snapshotId
        labId                  = [string]$Ownership.labId
        vmId                   = [string]$Ownership.vmId
        workspaceId            = [string]$Ownership.workspaceId
        ownershipToken         = [string]$Ownership.ownershipToken
        planHash               = [string]$Ownership.planHash
        readinessBindingDigest = [string]$Ownership.readinessBindingDigest
        experimentPlanHash     = [string]$Ownership.experimentPlanHash
        inventoryFingerprint   = [string]$Ownership.inventoryFingerprint
        sourceIsoSha256        = [string]$Ownership.sourceIsoSha256
        purpose                = $Purpose
        capturedUtc            = [datetime]::UtcNow.ToUniversalTime().ToString('o')
        recoveryState          = 'NotRequired'
        evidenceReferences     = @($EvidenceReferences)
        simulatedOnly          = $true
    }
}

function Test-XboxOSLabSnapshotBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Snapshot,
        [Parameter(Mandatory)][object]$Ownership
    )

    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($pair in @(
            @{ n = 'labId'; a = [string]$Snapshot.labId; b = [string]$Ownership.labId },
            @{ n = 'vmId'; a = [string]$Snapshot.vmId; b = [string]$Ownership.vmId },
            @{ n = 'workspaceId'; a = [string]$Snapshot.workspaceId; b = [string]$Ownership.workspaceId },
            @{ n = 'ownershipToken'; a = [string]$Snapshot.ownershipToken; b = [string]$Ownership.ownershipToken },
            @{ n = 'planHash'; a = [string]$Snapshot.planHash; b = [string]$Ownership.planHash },
            @{ n = 'readinessBindingDigest'; a = [string]$Snapshot.readinessBindingDigest; b = [string]$Ownership.readinessBindingDigest },
            @{ n = 'experimentPlanHash'; a = [string]$Snapshot.experimentPlanHash; b = [string]$Ownership.experimentPlanHash },
            @{ n = 'inventoryFingerprint'; a = [string]$Snapshot.inventoryFingerprint; b = [string]$Ownership.inventoryFingerprint },
            @{ n = 'sourceIsoSha256'; a = [string]$Snapshot.sourceIsoSha256; b = [string]$Ownership.sourceIsoSha256 }
        )) {
        if ($pair.a -ne $pair.b) {
            [void]$errors.Add(("Snapshot {0} mismatch relative to lab ownership." -f $pair.n))
        }
    }
    return [pscustomobject]@{
        valid  = [bool]($errors.Count -eq 0)
        errors = [string[]]@($errors.ToArray())
    }
}

function Test-XboxOSLabKeyPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TrustRootLabel,
        [Parameter(Mandatory)][ValidateSet('lab-only', 'test-only', 'production-forbidden')]
        [string]$Scope,
        [datetime]$ExpiresUtc = [datetime]::UtcNow.AddHours(8),
        [datetime]$AsOfUtc = [datetime]::UtcNow,
        [string]$Nonce = $null,
        [string]$OperatorRole = 'operator',
        [string]$AuthorizerRole = 'authorizer',
        [switch]$ClaimProductionTrust,
        [switch]$ReplayNonce
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]

    if ($Scope -eq 'production-forbidden') {
        [void]$errors.Add('production-forbidden key scope cannot authorize lab mutation.')
    }
    if ($ClaimProductionTrust) {
        [void]$errors.Add('Test PEM fixtures must not claim production trust.')
    }
    if ($TrustRootLabel -match '(?i)test' -and $Scope -ne 'test-only') {
        [void]$errors.Add('Test trust roots must use test-only scope.')
    }
    if ($ExpiresUtc.ToUniversalTime() -le $AsOfUtc.ToUniversalTime()) {
        [void]$errors.Add('Lab key / approval is expired.')
    }
    if ([string]::IsNullOrWhiteSpace($Nonce)) {
        $Nonce = [guid]::NewGuid().ToString('N')
    }
    if ($ReplayNonce) {
        [void]$script:XboxOSLabUsedNonces.Add($Nonce)
        [void]$errors.Add('Approval nonce replay detected.')
    }
    elseif (-not $script:XboxOSLabUsedNonces.Add($Nonce)) {
        [void]$errors.Add('Approval nonce replay detected.')
    }
    if ($OperatorRole -eq $AuthorizerRole) {
        [void]$errors.Add('Operator and authorizer roles must be separated.')
    }

    [void]$notes.Add('Signatures and simulated consent never activate Layer D or writable image mutation.')
    [void]$notes.Add('Custody/rotation/revocation requirements are validated as policy fields; production HSM custody is not introduced.')

    return [pscustomobject]@{
        schemaVersion              = Get-XboxOSLabKeyPolicySchemaVersion
        valid                      = [bool]($errors.Count -eq 0)
        errors                     = [string[]]@($errors.ToArray())
        notes                      = [string[]]@($notes.ToArray())
        trustRootLabel             = $TrustRootLabel
        scope                      = $Scope
        custody                    = 'documented-not-production'
        rotationRequired           = $true
        revocationSupported        = $true
        replayPrevention           = $true
        roleSeparationRequired     = $true
        activatesLayerD            = $false
        grantsWritableMutation     = $false
    }
}

function Assert-XboxOSLabTransactionTransition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )

    if ($script:XboxOSLabTransactionStates -notcontains $From) {
        throw ("Unknown lab transaction state '{0}'." -f $From)
    }
    if ($script:XboxOSLabTransactionStates -notcontains $To) {
        throw ("Unknown lab transaction state '{0}'." -f $To)
    }
    $writableBlocked = @('RealProvisioning', 'WritableExecution', 'LiveMutation')
    if ($writableBlocked -contains $To) {
        throw ("Real infrastructure provisioning / writable-execution transition '{0}' is not reachable in Milestone 6B." -f $To)
    }
    $allowed = @($script:XboxOSLabTransactionTransitions[$From])
    if ($allowed -notcontains $To) {
        throw ("Invalid lab transaction transition: {0} -> {1}." -f $From, $To)
    }
    return $true
}

function New-XboxOSLabTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LabId,
        [string]$InitialState = 'InfrastructurePlanned'
    )

    if ($script:XboxOSLabTransactionStates -notcontains $InitialState) {
        throw ("Unknown initial lab state '{0}'." -f $InitialState)
    }
    return [pscustomobject]@{
        schemaVersion                 = Get-XboxOSLabTransactionSchemaVersion
        labId                         = $LabId
        state                         = $InitialState
        history                       = @([pscustomobject]@{ utc = [datetime]::UtcNow; state = $InitialState; note = 'Created' })
        realDismExecutionEnabled      = $false
        modifyingCommandsInvoked      = $false
        executionAuthorized           = $false
        servicingAuthorized           = $false
        experimentalMutationEnabled   = $false
        experimentalExecutionAuthorized = $false
        labRealProvisioningEnabled    = $false
        labHypervisorCommandsInvoked  = $false
        layerDActivated               = $false
    }
}

function Set-XboxOSLabTransactionState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Transaction,
        [Parameter(Mandatory)][string]$To,
        [string]$Note = ''
    )

    Assert-XboxOSLabTransactionTransition -From ([string]$Transaction.state) -To $To
    $Transaction.state = $To
    $Transaction.history = @($Transaction.history) + @([pscustomobject]@{ utc = [datetime]::UtcNow; state = $To; note = $Note })
    Assert-XboxOSIsolatedLabSafetyInvariants -Report $Transaction
    return $Transaction
}

function Invoke-XboxOSLabSimulatedFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Transaction,
        [Parameter(Mandatory)]
        [ValidateSet(
            'IsoHashMismatch',
            'WorkspaceOwnershipMismatch',
            'VmIdentityMismatch',
            'SnapshotMismatch',
            'StaleMountMetadata',
            'UntrackedRegistryHive',
            'EvidenceSubstitution',
            'InterruptedExperiment',
            'CleanupVerificationFailure'
        )]
        [string]$FailureKind
    )

    $note = ("Simulated fail-closed: {0}" -f $FailureKind)
    if ([string]$Transaction.state -in @('SimulationReady', 'SimulationCompleted', 'ConfigurationValidated', 'AwaitingReview', 'LabProvisioningBlocked')) {
        $null = Set-XboxOSLabTransactionState -Transaction $Transaction -To Aborted -Note $note
        $null = Set-XboxOSLabTransactionState -Transaction $Transaction -To RecoveryRequired -Note ("RecoveryRequired after {0}" -f $FailureKind)
    }
    elseif ([string]$Transaction.state -eq 'InfrastructurePlanned') {
        $null = Set-XboxOSLabTransactionState -Transaction $Transaction -To Aborted -Note $note
        $null = Set-XboxOSLabTransactionState -Transaction $Transaction -To RecoveryRequired -Note ("RecoveryRequired after {0}" -f $FailureKind)
    }
    else {
        throw ("Cannot inject failure from state {0}." -f $Transaction.state)
    }

    return [pscustomobject]@{
        failureKind                    = $FailureKind
        state                          = [string]$Transaction.state
        globalDismCleanupPerformed     = $false
        unrelatedHiveUnloadPerformed   = $false
        realProvisioningAttempted      = $false
        notes                          = @(
            'Fail-closed simulation only.'
            'No global DISM cleanup and no unload of unrelated registry hives.'
        )
    }
}

function New-XboxOSLabFunctionalTestPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$FunctionalValidationCatalog,
        [switch]$VmEnvironment
    )

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($t in @($FunctionalValidationCatalog.tests)) {
        $status = 'NotExecuted'
        $limit = $null
        $id = [string]$t.testId
        if ($VmEnvironment) {
            if ($id -match 'graphics|dx|gpu|controller-usb-bt|xinput|gameinput|anticheat') {
                $status = 'EnvironmentLimited'
                $limit = 'GPU passthrough and/or physical controller / anti-cheat surfaces are not assumed available in a disposable VM.'
            }
            elseif ($id -match 'store|xbox-auth|wufb|gaming-services|xbox-fse|network|audio|servicing-recovery|game-launch') {
                $status = 'MissingEvidence'
                $limit = 'Requires controlled runtime evidence in an authorized lab run; not invented by Milestone 6B.'
            }
        }
        [void]$rows.Add([pscustomobject]@{
                testId                = $id
                capabilityId          = [string]$t.capabilityId
                plannedStatus         = $status
                environmentLimitation = $limit
                claimedPassed         = $false
                failureSeverity       = [string]$t.failureSeverity
                abortBehavior         = [string]$t.abortBehavior
            })
    }

    return [pscustomobject]@{
        schemaVersion = 'lab-functional-test-plan-v1'
        tests         = [object[]]@($rows.ToArray())
        inventsResults = $false
        notes         = @(
            'Statuses are NotExecuted, EnvironmentLimited, or MissingEvidence — never Passed without runtime evidence.'
        )
    }
}

function New-XboxOSLabEvidenceManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Ownership,
        [Parameter(Mandatory)][object]$Topology,
        [Parameter(Mandatory)][object]$FunctionalTestPlan,
        [Parameter(Mandatory)][object]$Transaction,
        [Parameter(Mandatory)][object]$BoundaryResult,
        [Parameter(Mandatory)][object]$IsolationResult,
        [object]$Git = $null,
        [string]$ExperimentPlanHash = '',
        [ValidateSet('ExternalValidated', 'InlineSimulation', 'NotValidated')]
        [string]$EvidenceMode = 'NotValidated',
        [string]$EvidenceLabel = 'NotValidated',
        [string[]]$ArtifactHashes = @(),
        [string]$CleanupStatus = 'NotPerformed-SimulationOnly'
    )

    $envDigest = Get-XboxOSUtf8Sha256Hex -Text (ConvertTo-XboxOSCanonicalJson -Value ([ordered]@{
                provider = [string]$Topology.provider.kind
                vm       = [ordered]@{
                    generation = [string]$Topology.vm.generation
                    firmware   = [string]$Topology.vm.firmware
                    cpuCount   = [int]$Topology.vm.cpuCount
                    memoryGiB  = [int]$Topology.vm.memoryGiB
                    diskGiB    = [int]$Topology.vm.diskGiB
                }
                network  = [ordered]@{
                    isolationMode = [string]$Topology.network.isolationMode
                    offlineDefault = [bool]$Topology.network.offlineValidationDefault
                }
            }))

    $missing = @(
        @($FunctionalTestPlan.tests | Where-Object { $_.plannedStatus -in @('MissingEvidence', 'EnvironmentLimited', 'NotExecuted') } | ForEach-Object { $_.testId })
    )

    return [pscustomobject]@{
        schemaVersion              = Get-XboxOSLabEvidenceSchemaVersion
        reportNamespace            = 'm6b'
        evidenceMode               = $EvidenceMode
        evidenceLabel              = $EvidenceLabel
        gitCommitSha               = $(if ($Git -and $Git.PSObject.Properties['gitCommitSha']) { [string]$Git.gitCommitSha } else { 'Unknown' })
        sourceIsoSha256            = [string]$Ownership.sourceIsoSha256
        experimentPlanHash         = $ExperimentPlanHash
        planHash                   = [string]$Ownership.planHash
        inventoryFingerprint       = [string]$Ownership.inventoryFingerprint
        readinessBindingDigest     = [string]$Ownership.readinessBindingDigest
        ownershipBindingDigest     = $(if ($Ownership.PSObject.Properties['ownershipBindingDigest']) { [string]$Ownership.ownershipBindingDigest } else { '' })
        labId                      = [string]$Ownership.labId
        vmId                       = [string]$Ownership.vmId
        environmentConfigurationDigest = $envDigest
        artifactHashes             = @($ArtifactHashes)
        simulationStatus           = [string]$Transaction.state
        testCoverage               = @(
            $FunctionalTestPlan.tests | ForEach-Object {
                [pscustomobject]@{ testId = $_.testId; plannedStatus = $_.plannedStatus }
            }
        )
        missingEvidence            = $missing
        cleanupStatus              = $CleanupStatus
        recoveryRequirements       = @(
            'Do not modify source ISO or host OS',
            'Discard owned disposable artifacts only',
            'Verify no unrelated hive unload',
            'Retain m6b evidence namespace; never overwrite M1-M6A baselines'
        )
        boundaryValid              = [bool]$BoundaryResult.valid
        isolationPolicyValid       = [bool]$IsolationResult.valid
        isolationPolicyStatus      = $(if ($IsolationResult.PSObject.Properties['policyValidationStatus']) { [string]$IsolationResult.policyValidationStatus } else { 'Unknown' })
        actualIsolationVerified    = $false
        hypervisorInspectionStatus = 'HypervisorNotInspected'
        networkIsolationVerificationStatus = 'NetworkIsolationNotVerified'
        realProvisioningEnabled    = $false
        layerDActivated            = $false
        preservesPriorBaselines    = $true
        generatedUtc               = [datetime]::UtcNow
    }
}

function Test-XboxOSLabEvidenceChain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CompatJsonPath,
        [Parameter(Mandatory)][string]$ReadinessJsonPath,
        [Parameter(Mandatory)][string]$ExperimentPlanJsonPath,
        [Parameter(Mandatory)][object]$RemoveAppsManifest,
        [Parameter(Mandatory)][object]$DisableFeaturesManifest,
        [Parameter(Mandatory)][object]$CompatibilityManifest,
        [ValidateSet('ExternalValidated', 'InlineSimulation')]
        [string]$EvidenceMode = 'ExternalValidated'
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]
    $label = Get-XboxOSLabEvidenceLabel -EvidenceMode $EvidenceMode

    foreach ($pair in @(
            @{ n = 'CompatJsonPath'; p = $CompatJsonPath },
            @{ n = 'ReadinessJsonPath'; p = $ReadinessJsonPath },
            @{ n = 'ExperimentPlanJsonPath'; p = $ExperimentPlanJsonPath }
        )) {
        if ([string]::IsNullOrWhiteSpace($pair.p) -or -not (Test-Path -LiteralPath $pair.p)) {
            [void]$errors.Add(("Missing required evidence report ({0}): {1}" -f $pair.n, $pair.p))
        }
    }
    if ($errors.Count -gt 0) {
        return [pscustomobject]@{
            schemaVersion          = Get-XboxOSLabEvidenceChainSchemaVersion
            valid                  = $false
            evidenceMode           = $EvidenceMode
            evidenceLabel          = $label
            errors                 = [string[]]@($errors.ToArray())
            notes                  = [string[]]@('Authoritative mode requires M1/M4 + M5 + M6A reports; no silent skip.')
            planHash               = $null
            inventoryFingerprint   = $null
            readinessBindingDigest = $null
            experimentPlanHash     = $null
            sourceIsoSha256        = $null
            activatesProvisioning  = $false
            activatesLayerD        = $false
        }
    }

    try {
        $inventory = Import-XboxOSInventoryFromCompatReport -Path $CompatJsonPath
    }
    catch {
        [void]$errors.Add(("Failed to import M1/M4 compatibility inventory: {0}" -f $_.Exception.Message))
        $inventory = $null
    }

    if ($null -ne $inventory) {
        if ($EvidenceMode -eq 'ExternalValidated' -and [string]$inventory.verificationStatus -ne 'Authoritative') {
            [void]$errors.Add(("Authoritative M1/M4 inventory required; got verificationStatus '{0}'." -f $inventory.verificationStatus))
        }
    }

    $plan = $null
    if ($null -ne $inventory -and $errors.Count -eq 0) {
        $plan = New-XboxOSServicingPlan `
            -Inventory $inventory `
            -RemoveAppsManifest $RemoveAppsManifest `
            -DisableFeaturesManifest $DisableFeaturesManifest `
            -CompatibilityManifest $CompatibilityManifest
    }

    $readyFile = $null
    $bind = $null
    if ($errors.Count -eq 0) {
        try {
            $readyFile = Get-Content -LiteralPath $ReadinessJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            [void]$errors.Add(("Malformed M5 readiness report: {0}" -f $_.Exception.Message))
        }
    }
    if ($null -ne $readyFile -and $null -ne $plan) {
        $bind = Test-XboxOSReadinessReportBinding `
            -Report $readyFile `
            -Plan $plan `
            -EvidenceMode $EvidenceMode `
            -RequireAuthoritativeProvenance:($EvidenceMode -eq 'ExternalValidated')
        if (-not $bind.valid) {
            foreach ($e in @($bind.errors)) { [void]$errors.Add(("M5 readiness binding: {0}" -f $e)) }
        }
    }

    $expReport = $null
    $expPlan = $null
    # Always attempt M6A load so missing/malformed reports are explicit even when earlier steps failed.
    try {
        $expReport = Get-Content -LiteralPath $ExperimentPlanJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        [void]$errors.Add(("Malformed M6A experiment plan report: {0}" -f $_.Exception.Message))
    }

    if ($null -ne $expReport) {
        if (-not $expReport.PSObject.Properties['experimentPlan'] -or $null -eq $expReport.experimentPlan) {
            [void]$errors.Add('M6A report missing experimentPlan.')
        }
        else {
            $expPlan = $expReport.experimentPlan
        }
        if ($expReport.PSObject.Properties['decision'] -and [string]$expReport.decision -ne 'BlockedForExecution') {
            [void]$errors.Add(("M6A decision must be BlockedForExecution; got '{0}'." -f $expReport.decision))
        }
        foreach ($flag in @(
                'realDismExecutionEnabled', 'modifyingCommandsInvoked', 'executionAuthorized', 'servicingAuthorized',
                'experimentalMutationEnabled', 'experimentalExecutionAuthorized'
            )) {
            if (-not $expReport.PSObject.Properties[$flag]) {
                [void]$errors.Add(("M6A report missing safety flag '{0}'." -f $flag))
            }
            elseif ([bool]$expReport.$flag) {
                [void]$errors.Add(("M6A report safety flag '{0}' must be False." -f $flag))
            }
        }
        if ($EvidenceMode -eq 'ExternalValidated') {
            $mode = if ($expReport.PSObject.Properties['evidenceMode']) { [string]$expReport.evidenceMode } else { '' }
            if ($mode -ne 'ExternalValidated') {
                [void]$errors.Add(("Authoritative lab mode requires M6A evidenceMode ExternalValidated; got '{0}'." -f $mode))
            }
        }
        if (-not $expReport.PSObject.Properties['readinessBindingDigest'] -or [string]::IsNullOrWhiteSpace([string]$expReport.readinessBindingDigest)) {
            [void]$errors.Add('M6A report missing readinessBindingDigest.')
        }
    }

    if ($null -ne $plan -and $null -ne $expPlan -and $null -ne $bind) {
        if ([string]$expPlan.servicingPlanContentHash -ne [string]$plan.contentHash) {
            [void]$errors.Add('M6A servicingPlanContentHash does not match recomputed M2 plan contentHash.')
        }
        if ([string]$expPlan.inventoryFingerprint -ne [string]$plan.inventoryFingerprint) {
            [void]$errors.Add('M6A inventoryFingerprint does not match recomputed M2 inventory fingerprint.')
        }
        if ([string]$expReport.readinessBindingDigest -ne [string]$bind.readinessBindingDigest) {
            [void]$errors.Add('M6A readinessBindingDigest does not match recomputed M5 binding digest.')
        }
        if ([string]$expPlan.readinessBindingDigest -ne [string]$bind.readinessBindingDigest) {
            [void]$errors.Add('Embedded experiment plan readinessBindingDigest does not match recomputed M5 digest.')
        }
        if ([string]$expPlan.sourceIsoSha256 -ne [string]$plan.sourceImage.isoSha256) {
            [void]$errors.Add('Contradictory source ISO SHA256 between M6A plan and recomputed M2 plan.')
        }
        if ([string]$expPlan.editionName -ne [string]$plan.sourceImage.editionName) {
            [void]$errors.Add('Edition mismatch between M6A plan and recomputed M2 plan.')
        }
        if ([string]$expPlan.buildNumber -ne [string]$plan.sourceImage.buildNumber) {
            [void]$errors.Add('Build number mismatch between M6A plan and recomputed M2 plan.')
        }
        if ([string]$expPlan.sourceIndex -ne [string]$plan.sourceImage.sourceIndex) {
            [void]$errors.Add('Source index mismatch between M6A plan and recomputed M2 plan.')
        }

        try {
            $recomputedExpHash = Get-XboxOSExperimentPlanContentHashFromPlan -ExperimentPlan $expPlan
            if ([string]$expPlan.contentHash -ne $recomputedExpHash) {
                [void]$errors.Add('M6A experiment plan contentHash does not match recomputed canonical hash (altered or incomplete evidence).')
            }
        }
        catch {
            [void]$errors.Add(("Unable to recompute M6A experiment plan content hash: {0}" -f $_.Exception.Message))
        }

        if (-not $expPlan.PSObject.Properties['git'] -or $null -eq $expPlan.git -or
            [string]::IsNullOrWhiteSpace([string]$expPlan.git.gitCommitSha) -or [string]$expPlan.git.gitCommitSha -eq 'Unknown') {
            [void]$errors.Add('M6A experiment plan missing git/evidence provenance.')
        }

        $eligiblePlan = @($plan.operations | Where-Object { [string]$_.status -eq 'Eligible' } | ForEach-Object { [string]$_.operationId } | Sort-Object)
        $expOps = @($expPlan.operations | ForEach-Object { [string]$_.operationId } | Sort-Object)
        foreach ($oid in $expOps) {
            if ($eligiblePlan -notcontains $oid) {
                [void]$errors.Add(("Forged or non-Eligible operation in M6A plan: {0}" -f $oid))
            }
        }
        foreach ($op in @($expPlan.operations)) {
            $tid = if ($op.PSObject.Properties['targetIdentity']) { [string]$op.targetIdentity } else { '' }
            if ([string]::IsNullOrWhiteSpace($tid)) {
                [void]$errors.Add(("M6A operation missing targetIdentity: {0}" -f $op.operationId))
            }
            $planOp = @($plan.operations | Where-Object { [string]$_.operationId -eq [string]$op.operationId } | Select-Object -First 1)
            if (-not $planOp) {
                [void]$errors.Add(("M6A operation not present in recomputed M2 plan: {0}" -f $op.operationId))
            }
            elseif ([string]$planOp.targetIdentity -ne $tid) {
                [void]$errors.Add(("M6A targetIdentity mismatch for {0}." -f $op.operationId))
            }
        }
    }

    [void]$notes.Add('Evidence-chain agreement is integrity evidence only; it does not authorize provisioning or Layer D.')
    [void]$notes.Add(("Evidence label: {0}" -f $label))

    $valid = [bool]($errors.Count -eq 0 -and $null -ne $plan -and $null -ne $bind -and $null -ne $expPlan)
    return [pscustomobject]@{
        schemaVersion          = Get-XboxOSLabEvidenceChainSchemaVersion
        valid                  = $valid
        evidenceMode           = $EvidenceMode
        evidenceLabel          = $label
        errors                 = [string[]]@($errors.ToArray() | Select-Object -Unique)
        notes                  = [string[]]@($notes.ToArray())
        planHash               = $(if ($plan) { [string]$plan.contentHash } else { $null })
        inventoryFingerprint   = $(if ($plan) { [string]$plan.inventoryFingerprint } else { $null })
        readinessBindingDigest = $(if ($bind) { [string]$bind.readinessBindingDigest } else { $null })
        experimentPlanHash     = $(if ($expPlan) { [string]$expPlan.contentHash } else { $null })
        sourceIsoSha256        = $(if ($plan) { [string]$plan.sourceImage.isoSha256 } elseif ($expPlan) { [string]$expPlan.sourceIsoSha256 } else { $null })
        editionName            = $(if ($plan) { [string]$plan.sourceImage.editionName } else { $null })
        buildNumber            = $(if ($plan) { [string]$plan.sourceImage.buildNumber } else { $null })
        sourceIndex            = $(if ($plan) { [string]$plan.sourceImage.sourceIndex } else { $null })
        plan                   = $plan
        readinessReport        = $readyFile
        experimentReport       = $expReport
        activatesProvisioning  = $false
        activatesLayerD        = $false
    }
}

function Invoke-XboxOSIsolatedLabSimulate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Topology,
        [Parameter(Mandatory)][object]$FunctionalValidationCatalog,
        [Parameter(Mandatory)][string]$PlanHash,
        [Parameter(Mandatory)][string]$ReadinessBindingDigest,
        [Parameter(Mandatory)][string]$SourceIsoSha256,
        [Parameter(Mandatory)][string]$ExperimentPlanHash,
        [Parameter(Mandatory)][string]$InventoryFingerprint,
        [string]$OwnerId = 'lab-sim-operator',
        [string]$RepoRoot = $null,
        [ValidateSet('ExternalValidated', 'InlineSimulation', 'NotValidated')]
        [string]$EvidenceMode = 'NotValidated',
        [object]$EvidenceChain = $null,
        [switch]$SimulateOperatorReview,
        [ValidateSet(
            '',
            'IsoHashMismatch',
            'WorkspaceOwnershipMismatch',
            'VmIdentityMismatch',
            'SnapshotMismatch',
            'StaleMountMetadata',
            'UntrackedRegistryHive',
            'EvidenceSubstitution',
            'InterruptedExperiment',
            'CleanupVerificationFailure'
        )]
        [string]$InjectFailure = ''
    )

    Assert-XboxOSIsolatedLabSafetyInvariants

    if ([string]$Topology.provider.kind -ne 'Simulation' -and [bool]$Topology.provider.assumesHypervisorInstalled) {
        throw 'Non-simulation providers that assume a hypervisor are not executable in Milestone 6B defaults.'
    }
    if ([string]::IsNullOrWhiteSpace($ExperimentPlanHash) -or [string]::IsNullOrWhiteSpace($InventoryFingerprint)) {
        throw 'ExperimentPlanHash and InventoryFingerprint are required for lab ownership binding.'
    }

    $labId = ('lab-{0}' -f [datetime]::UtcNow.ToString('yyyyMMddHHmmssfff'))
    $vmId = ([string]$Topology.vm.vmIdTemplate) -replace '\{labId\}', $labId
    $workspaceId = ('ws-{0}' -f $labId)
    $evidenceLabel = Get-XboxOSLabEvidenceLabel -EvidenceMode $EvidenceMode

    $tx = New-XboxOSLabTransaction -LabId $labId
    $boundary = Test-XboxOSLabInfrastructureBoundaries `
        -Topology $Topology `
        -ExpectedIsoSha256 $SourceIsoSha256 `
        -OwnerId $OwnerId `
        -SimulateExistingMountConflict:($InjectFailure -eq 'StaleMountMetadata') `
        -SimulateStaleHive:($InjectFailure -eq 'UntrackedRegistryHive')

    $isolation = Test-XboxOSLabVmIsolationPolicy -Topology $Topology
    $keyPolicy = Test-XboxOSLabKeyPolicy -TrustRootLabel 'test-approval-fixture' -Scope test-only -OperatorRole operator -AuthorizerRole authorizer

    $blockers = New-Object System.Collections.Generic.List[string]
    if (-not $boundary.valid) { foreach ($e in @($boundary.errors)) { [void]$blockers.Add($e) } }
    if (-not $isolation.valid) { foreach ($e in @($isolation.errors)) { [void]$blockers.Add($e) } }
    if (-not $keyPolicy.valid) { foreach ($e in @($keyPolicy.errors)) { [void]$blockers.Add($e) } }
    if ($EvidenceMode -eq 'NotValidated') {
        [void]$blockers.Add('Evidence mode NotValidated; lab readiness refuses unvalidated evidence.')
    }
    if ($null -ne $EvidenceChain -and -not [bool]$EvidenceChain.valid) {
        foreach ($e in @($EvidenceChain.errors)) { [void]$blockers.Add(("Evidence chain: {0}" -f $e)) }
    }

    # Milestone 6B.1: do not query or modify the hypervisor.
    $hypervisorNotes = @(
        'HypervisorNotInspected: Milestone 6B does not query or modify the hypervisor.'
        'Declared IsolatedSwitch policy is ConfigurationDeclared only; NetworkIsolationNotVerified.'
    )

    $wsRoot = if ($boundary.canonicalPaths.PSObject.Properties['workspaceRoot']) { [string]$boundary.canonicalPaths.workspaceRoot } else { [string]$Topology.paths.workspaceRoot }
    $ownership = New-XboxOSLabOwnershipRecord `
        -LabId $labId `
        -VmId $vmId `
        -WorkspaceId $workspaceId `
        -OwnerId $OwnerId `
        -PlanHash $PlanHash `
        -ReadinessBindingDigest $ReadinessBindingDigest `
        -SourceIsoSha256 $SourceIsoSha256 `
        -WorkspaceRoot $wsRoot `
        -ExperimentPlanHash $ExperimentPlanHash `
        -InventoryFingerprint $InventoryFingerprint `
        -EvidenceReferences @('m6a-experiment-plan', 'm5-readiness', 'm1-m4-compat-inventory')

    $ownCheck = Test-XboxOSLabOwnershipRecord `
        -Record $ownership `
        -ExpectedLabId $labId `
        -ExpectedVmId $vmId `
        -ExpectedPlanHash $PlanHash `
        -ExpectedReadinessBindingDigest $ReadinessBindingDigest `
        -ExpectedSourceIsoSha256 $SourceIsoSha256 `
        -ExpectedExperimentPlanHash $ExperimentPlanHash `
        -ExpectedInventoryFingerprint $InventoryFingerprint
    if (-not $ownCheck.valid) { foreach ($e in @($ownCheck.errors)) { [void]$blockers.Add($e) } }

    $snapshot = New-XboxOSLabSnapshotRecord -Ownership $ownership -Purpose PreExperimentBaseline -EvidenceReferences @('m6a-experiment-plan', 'm5-readiness', $ExperimentPlanHash)
    $snapBind = Test-XboxOSLabSnapshotBinding -Snapshot $snapshot -Ownership $ownership
    if (-not $snapBind.valid) { foreach ($e in @($snapBind.errors)) { [void]$blockers.Add($e) } }

    if ($InjectFailure -eq 'SnapshotMismatch') {
        $snapshot.labId = 'other-lab'
        $snapBind = Test-XboxOSLabSnapshotBinding -Snapshot $snapshot -Ownership $ownership
        foreach ($e in @($snapBind.errors)) { [void]$blockers.Add($e) }
    }
    if ($InjectFailure -eq 'VmIdentityMismatch') {
        [void]$blockers.Add('VM identity mismatch.')
    }
    if ($InjectFailure -eq 'WorkspaceOwnershipMismatch') {
        $ownership.ownershipToken = ('F' * 64)
        $ownCheck = Test-XboxOSLabOwnershipRecord -Record $ownership -ExpectedLabId $labId -ExpectedVmId $vmId -ExpectedPlanHash $PlanHash -ExpectedReadinessBindingDigest $ReadinessBindingDigest -ExpectedSourceIsoSha256 $SourceIsoSha256 -ExpectedExperimentPlanHash $ExperimentPlanHash -ExpectedInventoryFingerprint $InventoryFingerprint
        foreach ($e in @($ownCheck.errors)) { [void]$blockers.Add($e) }
    }
    if ($InjectFailure -eq 'IsoHashMismatch') {
        [void]$blockers.Add('ISO hash mismatch.')
    }
    if ($InjectFailure -eq 'EvidenceSubstitution') {
        [void]$blockers.Add('Evidence substitution detected.')
    }
    if ($InjectFailure -eq 'InterruptedExperiment') {
        [void]$blockers.Add('Interrupted experiment simulated.')
    }
    if ($InjectFailure -eq 'CleanupVerificationFailure') {
        [void]$blockers.Add('Cleanup verification failure simulated.')
    }

    $funcPlan = New-XboxOSLabFunctionalTestPlan -FunctionalValidationCatalog $FunctionalValidationCatalog -VmEnvironment

    $decision = 'LabProvisioningBlocked'
    if ($boundary.valid -and $isolation.valid -and $keyPolicy.valid -and $snapBind.valid -and $blockers.Count -eq 0) {
        # Still block real provisioning always; simulation path may reach SimulationCompleted
        $null = Set-XboxOSLabTransactionState -Transaction $tx -To ConfigurationValidated -Note 'Topology and boundaries validated'
        if ($SimulateOperatorReview) {
            $null = Set-XboxOSLabTransactionState -Transaction $tx -To AwaitingReview -Note 'Operator review simulated'
        }
        $null = Set-XboxOSLabTransactionState -Transaction $tx -To SimulationReady -Note 'Simulation-only readiness'
        $null = Set-XboxOSLabTransactionState -Transaction $tx -To SimulationCompleted -Note 'Infrastructure simulation completed'
        # Hard block: never provision
        $null = Set-XboxOSLabTransactionState -Transaction $tx -To LabProvisioningBlocked -Note 'Milestone 6B structurally blocks real lab provisioning and Layer D'
        $decision = 'LabProvisioningBlocked'
        [void]$blockers.Add('Milestone 6B final decision is LabProvisioningBlocked; real provisioning and Layer D remain disabled.')
    }
    else {
        $null = Set-XboxOSLabTransactionState -Transaction $tx -To LabProvisioningBlocked -Note 'Configuration or policy failed closed'
        if ($InjectFailure -in @('InterruptedExperiment', 'CleanupVerificationFailure', 'IsoHashMismatch', 'EvidenceSubstitution', 'SnapshotMismatch', 'VmIdentityMismatch', 'WorkspaceOwnershipMismatch', 'StaleMountMetadata', 'UntrackedRegistryHive')) {
            $null = Invoke-XboxOSLabSimulatedFailure -Transaction $tx -FailureKind $InjectFailure
            $decision = 'RecoveryRequired'
        }
    }

    # Ensure LabProvisioningBlocked is always the production outcome when not RecoveryRequired
    if ($decision -ne 'RecoveryRequired' -and [string]$tx.state -ne 'LabProvisioningBlocked') {
        if ([string]$tx.state -eq 'SimulationCompleted') {
            $null = Set-XboxOSLabTransactionState -Transaction $tx -To LabProvisioningBlocked -Note 'Force block after simulation'
        }
        $decision = 'LabProvisioningBlocked'
    }

    $git = Get-XboxOSReportTraceability -RepoRoot $RepoRoot
    $evidence = New-XboxOSLabEvidenceManifest `
        -Ownership $ownership `
        -Topology $Topology `
        -FunctionalTestPlan $funcPlan `
        -Transaction $tx `
        -BoundaryResult $boundary `
        -IsolationResult $isolation `
        -Git $git `
        -ExperimentPlanHash $ExperimentPlanHash `
        -EvidenceMode $EvidenceMode `
        -EvidenceLabel $evidenceLabel

    $report = [pscustomobject]@{
        reportSchemaVersion               = 'isolated-lab-report-v1.1'
        engineVersion                     = Get-XboxOSIsolatedLabEngineVersion
        decision                          = $decision
        transactionState                  = [string]$tx.state
        topologySchemaVersion             = Get-XboxOSLabTopologySchemaVersion
        providerKind                      = [string]$Topology.provider.kind
        evidenceMode                      = $EvidenceMode
        evidenceLabel                     = $evidenceLabel
        evidenceChain                     = $EvidenceChain
        hypervisorInspectionStatus        = 'HypervisorNotInspected'
        hypervisorNotes                   = [string[]]$hypervisorNotes
        boundary                          = $boundary
        isolation                         = $isolation
        keyPolicy                         = $keyPolicy
        ownership                         = $ownership
        snapshot                          = $snapshot
        functionalTestPlan                = $funcPlan
        evidenceManifest                  = $evidence
        transaction                       = $tx
        blockers                          = [string[]]@($blockers.ToArray() | Select-Object -Unique)
        authorizationLayers               = [pscustomobject]@{
            layerA_Planning                 = 'Reused from M6A'
            layerB_OperatorConsent          = 'Reused from M6A; simulated review optional'
            layerC_ExperimentalRiskAcceptance = 'Reused from M6A; not execution authorization'
            layerD_ExecutionAuthorization   = 'Structurally disabled'
            layerE_FunctionalValidation     = 'Catalog bound; results not invented'
        }
        realDismExecutionEnabled          = $false
        modifyingCommandsInvoked          = $false
        executionAuthorized               = $false
        servicingAuthorized               = $false
        experimentalMutationEnabled       = $false
        experimentalExecutionAuthorized   = $false
        labRealProvisioningEnabled        = $false
        labHypervisorCommandsInvoked      = $false
        layerDActivated                   = $false
        generatedUtc                      = [datetime]::UtcNow
        notes                             = @(
            'Milestone 6B.1 simulates lab infrastructure readiness only.'
            'Valid configuration is permission to plan, not to provision.'
            'PolicyValidated isolation is not actual hypervisor/network verification.'
            'Layer D and writable DISM remain unauthorized.'
            ("Evidence label: {0}" -f $evidenceLabel)
        )
    }

    Assert-XboxOSIsolatedLabSafetyInvariants -Report $report
    return $report
}

function Save-XboxOSIsolatedLabReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Report,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$Stem = 'XboxOS11-isolated-lab-m6b',
        [string]$RepoRoot = $null
    )

    Assert-XboxOSIsolatedLabSafetyInvariants -Report $Report
    if ($OutputDirectory -match '(?i)OneDrive') {
        throw "Refusing to write lab reports under OneDrive: $OutputDirectory"
    }
    if ($RepoRoot) {
        $null = Assert-XboxOSServicingPathSafety -Path $OutputDirectory -RepoRoot $RepoRoot -Purpose 'isolated lab reports'
    }
    $forbidden = @(
        'DISM-Compatibility-20261014-2',
        'XboxOS11-disposable-preflight-m4-live-readonly',
        'XboxOS11-servicing-readiness-m5',
        'XboxOS11-experiment-plan-m6a',
        'XboxOS11-execution-safety-m3',
        'XboxOS11-servicing-plan'
    )
    foreach ($f in $forbidden) {
        if ($Stem -eq $f -or $Stem -like "$f*") {
            throw ("Refusing to overwrite Milestone 1-6A baseline stem: {0}" -f $Stem)
        }
    }

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $jsonPath = Join-Path $OutputDirectory ($Stem + '.json')
    $mdPath = Join-Path $OutputDirectory ($Stem + '.md')
    ($Report | ConvertTo-Json -Depth 14) | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('# XboxOS11 Milestone 6B — Isolated Lab Readiness (simulation)')
    [void]$lines.Add('')
    [void]$lines.Add(('Engine: `{0}`' -f $Report.engineVersion))
    [void]$lines.Add(('Decision: **{0}**' -f $Report.decision))
    [void]$lines.Add(('Transaction state: `{0}`' -f $Report.transactionState))
    [void]$lines.Add(('Provider: `{0}`' -f $Report.providerKind))
    [void]$lines.Add('')
    [void]$lines.Add('## Safety flags (must remain False)')
    [void]$lines.Add('')
    [void]$lines.Add('| Flag | Value |')
    [void]$lines.Add('|------|-------|')
    foreach ($flag in @(
            'realDismExecutionEnabled', 'modifyingCommandsInvoked', 'executionAuthorized', 'servicingAuthorized',
            'experimentalMutationEnabled', 'experimentalExecutionAuthorized',
            'labRealProvisioningEnabled', 'labHypervisorCommandsInvoked', 'layerDActivated'
        )) {
        [void]$lines.Add(('| `{0}` | {1} |' -f $flag, $Report.$flag))
    }
    [void]$lines.Add('')
    [void]$lines.Add(('Evidence mode: `{0}` (`{1}`)' -f $Report.evidenceMode, $Report.evidenceLabel))
    [void]$lines.Add('')
    [void]$lines.Add('## Isolation')
    [void]$lines.Add('')
    [void]$lines.Add(('Policy valid: `{0}` (`{1}`)' -f $Report.isolation.valid, $Report.isolation.policyValidationStatus))
    [void]$lines.Add(('Declared mode: `{0}` (`{1}`)' -f $Report.isolation.declaredIsolationMode, $Report.isolation.configurationStatus))
    [void]$lines.Add(('Hypervisor: `{0}`' -f $Report.isolation.hypervisorInspectionStatus))
    [void]$lines.Add(('Network verification: `{0}`' -f $Report.isolation.networkIsolationVerificationStatus))
    [void]$lines.Add(('Actual isolation verified: `{0}`' -f $Report.isolation.actualIsolationVerified))
    [void]$lines.Add('')
    [void]$lines.Add('## Blockers')
    [void]$lines.Add('')
    foreach ($b in @($Report.blockers)) {
        [void]$lines.Add(('- {0}' -f $b))
    }
    [void]$lines.Add('')
    [void]$lines.Add('No hypervisor provisioning or DISM mutation was performed.')
    ($lines -join "`n") + "`n" | Set-Content -LiteralPath $mdPath -Encoding UTF8

    return [pscustomobject]@{ JsonPath = $jsonPath; MarkdownPath = $mdPath }
}

function Reset-XboxOSLabNonceRegistry {
    [CmdletBinding()]
    param()
    $script:XboxOSLabUsedNonces.Clear()
}
