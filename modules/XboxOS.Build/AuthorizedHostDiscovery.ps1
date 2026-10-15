# Milestone 6D — Operator-authorized real-host discovery (read-only contracts).
# Implementation and CI use mocks only. Live host inspection remains structurally inactive.

$script:XboxOSAuthorizedHostDiscoveryEngineVersion = '6.3.0-d'
$script:XboxOSAuthorizedHostDiscoveryApprovalSchemaVersion = 'host-discovery-real-approval-v1'
$script:XboxOSAuthorizedHostDiscoveryEvidenceSchemaVersion = 'host-discovery-real-evidence-v1'
$script:XboxOSAuthorizedHostDiscoveryReportSchemaVersion = 'host-discovery-real-report-v1'
$script:XboxOSAuthorizedHostDiscoveryTransactionSchemaVersion = 'host-discovery-real-transaction-v1'
$script:XboxOSAuthorizedHostDiscoveryOperationSchemaVersion = 'host-discovery-operation-v1'
$script:XboxOSAuthorizedHostDiscoveryRedactionSchemaVersion = 'host-discovery-redaction-v1'

$script:XboxOSAuthorizedHostDiscoveryLiveActivationEnabled = $false
$script:XboxOSAuthorizedHostDiscoveryUsedNonces = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:XboxOSAuthorizedHostDiscoveryUsedRunIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

# Fingerprint of the repository fixture test public key — never trusted for live inspection.
$script:XboxOSAuthorizedHostDiscoveryForbiddenTestKeyFingerprints = @(
    'a3f2c8e1b9d0475e6f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f70' # placeholder replaced at import
)

$script:XboxOSAuthorizedHostDiscoveryTransactionStates = @(
    'AuthorizedDiscoveryPlanned',
    'ApprovalRequired',
    'HostDiscoveryBlocked',
    'AuthorizedDiscoverySimulated',
    'EvidenceIncomplete',
    'DiscoveryFailed',
    'RecoveryRequired',
    'LiveHostInspection',
    'LabProvisioning',
    'WritableExecution'
)

$script:XboxOSAuthorizedHostDiscoveryTransactionTransitions = @{
    'AuthorizedDiscoveryPlanned'   = @('ApprovalRequired', 'HostDiscoveryBlocked', 'DiscoveryFailed')
    'ApprovalRequired'             = @('AuthorizedDiscoverySimulated', 'HostDiscoveryBlocked', 'DiscoveryFailed')
    'AuthorizedDiscoverySimulated' = @('EvidenceIncomplete', 'HostDiscoveryBlocked', 'DiscoveryFailed', 'RecoveryRequired')
    'EvidenceIncomplete'           = @('HostDiscoveryBlocked', 'DiscoveryFailed', 'RecoveryRequired')
    'HostDiscoveryBlocked'         = @('RecoveryRequired', 'DiscoveryFailed')
    'DiscoveryFailed'              = @('RecoveryRequired')
    'RecoveryRequired'             = @()
    'LiveHostInspection'           = @()
    'LabProvisioning'              = @()
    'WritableExecution'            = @()
}

function Get-XboxOSAuthorizedHostDiscoveryEngineVersion { return $script:XboxOSAuthorizedHostDiscoveryEngineVersion }
function Get-XboxOSAuthorizedHostDiscoveryApprovalSchemaVersion { return $script:XboxOSAuthorizedHostDiscoveryApprovalSchemaVersion }
function Get-XboxOSAuthorizedHostDiscoveryEvidenceSchemaVersion { return $script:XboxOSAuthorizedHostDiscoveryEvidenceSchemaVersion }
function Get-XboxOSAuthorizedHostDiscoveryReportSchemaVersion { return $script:XboxOSAuthorizedHostDiscoveryReportSchemaVersion }
function Get-XboxOSAuthorizedHostDiscoveryTransactionSchemaVersion { return $script:XboxOSAuthorizedHostDiscoveryTransactionSchemaVersion }
function Get-XboxOSAuthorizedHostDiscoveryOperationSchemaVersion { return $script:XboxOSAuthorizedHostDiscoveryOperationSchemaVersion }
function Get-XboxOSAuthorizedHostDiscoveryRedactionSchemaVersion { return $script:XboxOSAuthorizedHostDiscoveryRedactionSchemaVersion }
function Get-XboxOSAuthorizedHostDiscoveryLiveActivationEnabled { return [bool]$script:XboxOSAuthorizedHostDiscoveryLiveActivationEnabled }

function Reset-XboxOSAuthorizedHostDiscoveryNonceRegistry {
    [CmdletBinding()]
    param()
    $script:XboxOSAuthorizedHostDiscoveryUsedNonces.Clear()
    $script:XboxOSAuthorizedHostDiscoveryUsedRunIds.Clear()
}

function Initialize-XboxOSAuthorizedHostDiscoveryTestKeyFingerprints {
    [CmdletBinding()]
    param([string]$RepoRoot = $null)

    if (-not $RepoRoot) {
        try { $RepoRoot = Get-XboxOSRepoRoot } catch { return }
    }
    $pub = Join-Path $RepoRoot 'tests\Fixtures\approval-auth\test-approval-public.pem'
    if (Test-Path -LiteralPath $pub) {
        $pem = Get-Content -LiteralPath $pub -Raw -Encoding UTF8
        $fp = Get-XboxOSUtf8Sha256Hex -Text $pem.Trim()
        $script:XboxOSAuthorizedHostDiscoveryForbiddenTestKeyFingerprints = @($fp)
    }
}

function Get-XboxOSPublicKeyFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PublicKeyPemPath)

    if (-not (Test-Path -LiteralPath $PublicKeyPemPath)) {
        throw "Public key PEM not found: $PublicKeyPemPath"
    }
    $pem = Get-Content -LiteralPath $PublicKeyPemPath -Raw -Encoding UTF8
    return Get-XboxOSUtf8Sha256Hex -Text $pem.Trim()
}

function Assert-XboxOSAuthorizedHostDiscoverySafetyInvariants {
    [CmdletBinding()]
    param([object]$Report = $null)

    Assert-XboxOSHostDiscoverySafetyInvariants -Report $Report
    if (Get-XboxOSAuthorizedHostDiscoveryLiveActivationEnabled) {
        throw 'Safety invariant violated: live host-discovery activation must remain False during Milestone 6D implementation/CI.'
    }
    if (Get-XboxOSHostDiscoveryRealHostCommandsInvoked) {
        throw 'Safety invariant violated: hostDiscoveryRealHostCommandsInvoked must remain False in Milestone 6D implementation/CI.'
    }
    if ($null -eq $Report) { return }
    foreach ($flag in @(
            'labRealProvisioningEnabled', 'labHypervisorCommandsInvoked', 'layerDActivated',
            'hostDiscoveryRealHostCommandsInvoked', 'realHostInspectionEnabled', 'liveHostInspectionActivated'
        )) {
        if ($Report.PSObject.Properties[$flag] -and $Report.$flag) {
            throw ("Safety invariant violated: {0} must be False." -f $flag)
        }
    }
}

function Get-XboxOSToolingGitVerificationState {
    [CmdletBinding()]
    param([string]$RepoRoot = $null)

    if (-not $RepoRoot) {
        try { $RepoRoot = Get-XboxOSRepoRoot } catch {
            return [pscustomobject]@{
                gitCommitSha     = 'Unknown'
                verificationState = 'Unverified'
                workingTreeClean = $false
                errors           = @('RepoRoot unavailable.')
            }
        }
    }

    $errors = New-Object System.Collections.Generic.List[string]
    $sha = & git -C $RepoRoot rev-parse HEAD 2>$null
    $commit = if ($sha) { ([string]$sha).Trim() } else { 'Unknown' }
    if ($commit -eq 'Unknown' -or [string]::IsNullOrWhiteSpace($commit)) {
        [void]$errors.Add('Git commit SHA unavailable.')
    }

    $porcelain = & git -C $RepoRoot status --porcelain 2>$null
    $dirty = $false
    if ($null -ne $porcelain -and @($porcelain | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        $dirty = $true
        [void]$errors.Add('Working tree is dirty; live host inspection blocked.')
    }

    $state = if ($errors.Count -eq 0 -and -not $dirty -and $commit -ne 'Unknown') { 'VerifiedClean' }
    elseif ($dirty) { 'Dirty' }
    else { 'Unverified' }

    return [pscustomobject]@{
        gitCommitSha      = $commit
        verificationState = $state
        workingTreeClean  = (-not $dirty -and $commit -ne 'Unknown')
        errors            = [string[]]@($errors.ToArray())
    }
}

function New-XboxOSHostDiscoveryScopeForRealHost {
    [CmdletBinding()]
    param(
        [string[]]$Categories = @(
            'OsInformation', 'CpuVirtualization', 'HyperVManagementComponents', 'VmInventory',
            'VmSwitchInventory', 'NetworkAdapters', 'VhdMetadata', 'HostResources',
            'WorkspaceBoundaries', 'LabCredentialPrerequisites'
        ),
        [string]$ProposedSwitchName = 'IsolatedSwitch',
        [string]$WorkspaceRoot = 'C:\XboxOS\Lab\Work',
        [switch]$IncludeDismMountMetadata
    )

    if ($IncludeDismMountMetadata -and $Categories -notcontains 'DismMountMetadata') {
        $Categories = @($Categories + 'DismMountMetadata')
    }

    $cats = @($Categories | Sort-Object -Unique)
    $dismApproved = [bool]($cats -contains 'DismMountMetadata')
    return [pscustomobject]@{
        schemaVersion      = Get-XboxOSHostDiscoveryScopeSchemaVersion
        categories         = $cats
        proposedSwitchName = $ProposedSwitchName
        workspaceRoot      = $WorkspaceRoot
        readOnlyRequired   = $true
        realHostAllowed    = $true
        dismMountApproved  = $dismApproved
        scopeDigest        = Get-XboxOSUtf8Sha256Hex -Text (ConvertTo-XboxOSCanonicalJson -Value ([ordered]@{
                    categories         = $cats
                    proposedSwitchName = $ProposedSwitchName
                    workspaceRoot      = $WorkspaceRoot
                    readOnlyRequired   = $true
                    realHostAllowed    = $true
                    dismMountApproved  = $dismApproved
                }))
    }
}

function Get-XboxOSHostDiscoveryOperationCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Allowlist)

    $ops = New-Object System.Collections.Generic.List[object]
    foreach ($op in @($Allowlist.allowedOperations)) {
        [void]$ops.Add([pscustomobject]@{
                schemaVersion          = Get-XboxOSAuthorizedHostDiscoveryOperationSchemaVersion
                operationId            = [string]$op.operationId
                category               = [string]$op.category
                commandProvider        = 'TypedDiscoveryOperation'
                allowedParameters      = @()
                requiredPermissions    = @('LocalRead')
                expectedOutputSchema   = ('{0}-result' -f [string]$op.operationId)
                timeoutSeconds         = 30
                readOnlyClassification = 'ReadOnly'
                failureBehavior        = 'FailClosedUnavailable'
                evidenceCollection     = 'PerOperationStatusAndHash'
                sideEffects            = [bool]$op.sideEffects
                description            = [string]$op.description
            })
    }
    return [object[]]@($ops.ToArray())
}

function Test-XboxOSHostDiscoveryOperationSpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Allowlist,
        [Parameter(Mandatory)][string]$OperationId,
        [hashtable]$Parameters = @{},
        [string]$RawCommand = ''
    )

    $gate = Test-XboxOSHostDiscoveryCommandAllowed -Allowlist $Allowlist -OperationId $OperationId -RawCommand $RawCommand
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($e in @($gate.errors)) { [void]$errors.Add($e) }

    if ($Parameters.Keys.Count -gt 0) {
        [void]$errors.Add('Arbitrary operation parameters are rejected; typed operations accept no free-form arguments.')
    }
    if ($RawCommand -match '(?i)Invoke-Expression|`\$\(|\$\(|&&|\||;') {
        [void]$errors.Add('Shell metacharacters / command substitution are forbidden.')
    }
    if ($OperationId -match '(?i)^(New-|Start-|Stop-|Remove-|Set-|Mount-|Dismount-|Enable-|Disable-|Repair-|Attach-)') {
        if ($OperationId -notin @('Get-OsInfo')) {
            # Allowlist already denies mutation ids; reinforce fail-closed for unexpected write verbs.
            $known = @($Allowlist.allowedOperations | ForEach-Object { [string]$_.operationId })
            if ($known -notcontains $OperationId) {
                [void]$errors.Add(("Write/mutation-style operation rejected: {0}" -f $OperationId))
            }
        }
    }

    return [pscustomobject]@{
        allowed     = [bool]($errors.Count -eq 0)
        operationId = $OperationId
        errors      = [string[]]@($errors.ToArray())
        sideEffects = $false
    }
}

function Protect-XboxOSHostDiscoverySensitiveValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [ValidateSet('Hostname', 'VmName', 'AdapterId', 'Domain', 'IpAddress', 'UserPath', 'CredentialMeta', 'Generic')]
        [string]$Kind = 'Generic',
        [string]$StableSalt = 'm6d-redaction'
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [pscustomobject]@{
            schemaVersion = Get-XboxOSAuthorizedHostDiscoveryRedactionSchemaVersion
            kind          = $Kind
            redacted      = '[empty]'
            pseudonym     = 'empty'
            originalHash  = Get-XboxOSUtf8Sha256Hex -Text ''
        }
    }

    $hash = Get-XboxOSUtf8Sha256Hex -Text ('{0}|{1}|{2}' -f $StableSalt, $Kind, $Value)
    $pseudo = ('{0}-{1}' -f $Kind.ToLowerInvariant(), $hash.Substring(0, 12))
    $redacted = switch ($Kind) {
        'IpAddress' { if ($Value -match '^\d+\.\d+\.\d+\.\d+$') { ($Value -replace '\.\d+$', '.***') } else { $pseudo } }
        'UserPath' { ($Value -replace '(?i)([A-Z]:\\Users\\)[^\\]+', '$1***') }
        'CredentialMeta' { '[redacted-credential-metadata]' }
        default { $pseudo }
    }

    return [pscustomobject]@{
        schemaVersion = Get-XboxOSAuthorizedHostDiscoveryRedactionSchemaVersion
        kind          = $Kind
        redacted      = $redacted
        pseudonym     = $pseudo
        originalHash  = $hash
    }
}

function ConvertTo-XboxOSHostDiscoveryRedactedInventory {
    [CmdletBinding()]
    param(
        [object]$Vms = $null,
        [object]$Switches = $null,
        [object]$Adapters = $null,
        [string]$HostLabel = ''
    )

    $hostRedacted = Protect-XboxOSHostDiscoverySensitiveValue -Value $HostLabel -Kind Hostname
    $vmsOut = @()
    foreach ($vm in @($Vms)) {
        if ($null -eq $vm) { continue }
        $name = if ($vm.PSObject.Properties['name']) { [string]$vm.name } else { '' }
        $rn = Protect-XboxOSHostDiscoverySensitiveValue -Value $name -Kind VmName
        $vmsOut += [pscustomobject]@{
            namePseudonym     = $rn.pseudonym
            nameRedacted      = $rn.redacted
            productionTagged  = [bool]($vm.PSObject.Properties['productionTagged'] -and $vm.productionTagged)
            sharesLabSwitchWithProduction = [bool]($vm.PSObject.Properties['sharesLabSwitchWithProduction'] -and $vm.sharesLabSwitchWithProduction)
        }
    }
    $swOut = @()
    foreach ($sw in @($Switches)) {
        if ($null -eq $sw) { continue }
        $swOut += [pscustomobject]@{
            name = [string]$sw.name
            type = [string]$sw.type
        }
    }
    $adOut = @()
    foreach ($ad in @($Adapters)) {
        if ($null -eq $ad) { continue }
        $id = if ($ad.PSObject.Properties['name']) { [string]$ad.name } else { 'adapter' }
        $rid = Protect-XboxOSHostDiscoverySensitiveValue -Value $id -Kind AdapterId
        $adOut += [pscustomobject]@{
            adapterPseudonym = $rid.pseudonym
            ifIndex          = $(if ($ad.PSObject.Properties['ifIndex']) { $ad.ifIndex } else { $null })
        }
    }

    return [pscustomobject]@{
        hostLabelRedacted = $hostRedacted.redacted
        hostPseudonym     = $hostRedacted.pseudonym
        vms               = $vmsOut
        switches          = $swOut
        adapters          = $adOut
        redactionStatus   = 'Applied'
        collectsSecrets   = $false
    }
}

function New-XboxOSMockHostDiscoveryCommandProvider {
    [CmdletBinding()]
    param(
        [hashtable]$FixtureInventory = $null,
        [switch]$SimulateInsufficientPrivileges,
        [switch]$SimulateHyperVUnavailable,
        [switch]$SimulatePermissionFailure,
        [switch]$SimulateUnexpectedCommandFailure,
        [switch]$SimulateWriteAttempt
    )

    if ($null -eq $FixtureInventory) {
        $FixtureInventory = @{
            os               = @{ edition = 'Windows 11 Pro'; build = '26300.9457'; architecture = 'amd64'; firmware = 'UEFI' }
            cpu              = @{ virtualizationFirmwareEnabled = $true; logicalProcessors = 16 }
            hyperVManagement = @{ moduleAvailable = $true; getVmAvailable = $true; featureState = 'Enabled' }
            vms              = @(@{ name = 'lab-fixture-vm'; productionTagged = $false; sharesLabSwitchWithProduction = $false })
            switches         = @(@{ name = 'IsolatedSwitch'; type = 'Private' })
            adapters         = @(@{ name = 'Ethernet'; ifIndex = 12 })
            vhds             = @(@{ path = 'C:\XboxOS\Lab\disk.vhdx'; sizeGiB = 80 })
            resources        = @{ cpuCount = 16; memoryGiB = 64; freeDiskGiB = 400 }
            dismMounts       = @()
            credentialPrereqs = @{ labKeyCustodyDocumented = $true; productionTrustPresent = $false }
            productionBridge = $false
            hostAdminShares  = $false
            firewallEvidence = $false
        }
    }

    return [pscustomobject]@{
        providerKind                       = 'MockCommandProvider'
        fixtureInventory                   = $FixtureInventory
        simulateInsufficientPrivileges     = [bool]$SimulateInsufficientPrivileges
        simulateHyperVUnavailable          = [bool]$SimulateHyperVUnavailable
        simulatePermissionFailure          = [bool]$SimulatePermissionFailure
        simulateUnexpectedCommandFailure   = [bool]$SimulateUnexpectedCommandFailure
        simulateWriteAttempt               = [bool]$SimulateWriteAttempt
        liveCommandsInvoked                = $false
        notes                              = @('Mock provider only; no live host cmdlets are invoked.')
    }
}

function New-XboxOSRealHostDiscoveryCommandProvider {
    [CmdletBinding()]
    param()

    # Compiled interface for a future operator-activated path. Structurally inactive in M6D CI/implementation.
    return [pscustomobject]@{
        providerKind        = 'RealHostCommandProvider'
        liveCommandsInvoked = $false
        activationRequired  = $true
        notes               = @(
            'Real-host command provider is not activatable during Milestone 6D implementation.'
            'No Get-VM / DISM / netsh / mutation cmdlets are executed from this provider while live activation is False.'
        )
    }
}

function Invoke-XboxOSHostDiscoveryCommandProviderOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Provider,
        [Parameter(Mandatory)][string]$OperationId
    )

    if ([string]$Provider.providerKind -eq 'RealHostCommandProvider') {
        if (-not (Get-XboxOSAuthorizedHostDiscoveryLiveActivationEnabled)) {
            throw 'RealHostCommandProvider is inactive: live activation is False (Milestone 6D implementation/CI).'
        }
        throw 'Live host inspection path is not implemented for automatic use; operator activation required and must not run in CI.'
    }

    if ([string]$Provider.providerKind -ne 'MockCommandProvider') {
        throw ("Unknown command provider kind: {0}" -f $Provider.providerKind)
    }

    if ([bool]$Provider.simulateWriteAttempt) {
        throw ("Unexpected write-operation attempt blocked for operation '{0}'." -f $OperationId)
    }
    if ([bool]$Provider.simulateUnexpectedCommandFailure) {
        throw ("Unexpected command failure simulated for '{0}'." -f $OperationId)
    }
    if ([bool]$Provider.simulatePermissionFailure -or [bool]$Provider.simulateInsufficientPrivileges) {
        return [pscustomobject]@{
            operationId       = $OperationId
            status            = 'Unverified'
            reason            = 'Insufficient permissions (simulated); no elevation attempted.'
            observationSource = 'MockFixture'
            data              = $null
            realHostInvoked   = $false
            exitStatus        = 'AccessDenied'
        }
    }

    $inv = $Provider.fixtureInventory
    $hyperVUnavailable = [bool]$Provider.simulateHyperVUnavailable -or (-not [bool]$inv.hyperVManagement.moduleAvailable)
    $data = $null
    $status = 'ObservedFixture'
    $exitStatus = 'Success'

    switch ($OperationId) {
        'Get-OsInfo' { $data = $inv.os }
        'Get-CpuVirtualization' { $data = $inv.cpu }
        'Get-HyperVManagementPresence' {
            if ($hyperVUnavailable) {
                $status = 'Unavailable'
                $exitStatus = 'ModuleMissing'
                $data = @{ moduleAvailable = $false; getVmAvailable = $false; featureState = 'Unknown' }
            }
            else { $data = $inv.hyperVManagement }
        }
        'Get-VmInventory' {
            if ($hyperVUnavailable) {
                $status = 'Unavailable'
                $exitStatus = 'ModuleMissing'
                $data = @{ availability = 'Unavailable'; vms = $null; inventsEmptyInventory = $false }
            }
            else { $data = @{ availability = 'Available'; vms = @($inv.vms) } }
        }
        'Get-VmSwitchInventory' {
            if ($hyperVUnavailable) {
                $status = 'Unavailable'
                $exitStatus = 'ModuleMissing'
                $data = @{ availability = 'Unavailable'; switches = $null; inventsEmptyInventory = $false }
            }
            else { $data = @{ availability = 'Available'; switches = @($inv.switches) } }
        }
        'Get-NetworkAdapters' { $data = @{ adapters = @($inv.adapters); productionBridge = [bool]$inv.productionBridge } }
        'Get-VhdMetadata' { $data = @{ vhds = @($inv.vhds) } }
        'Get-HostResources' { $data = $inv.resources }
        'Get-WorkspaceBoundaries' { $data = @{ evaluated = $true } }
        'Get-DismMountMetadata' { $data = @{ mounts = @($inv.dismMounts) } }
        'Get-LabCredentialPrerequisites' { $data = $inv.credentialPrereqs }
        default { throw ("Unhandled typed discovery operation '{0}'." -f $OperationId) }
    }

    return [pscustomobject]@{
        operationId       = $OperationId
        status            = $status
        reason            = $null
        observationSource = 'MockFixture'
        data              = $data
        realHostInvoked   = $false
        exitStatus        = $exitStatus
    }
}

function New-XboxOSAuthorizedHostDiscoveryAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Allowlist,
        [ValidateSet('AuthorizedMockReadOnly', 'RealHostReadOnly')]
        [string]$Mode = 'AuthorizedMockReadOnly',
        [object]$CommandProvider = $null,
        [hashtable]$FixtureInventory = $null,
        [switch]$SimulateInsufficientPrivileges,
        [switch]$SimulateHyperVUnavailable,
        [switch]$SimulatePermissionFailure,
        [switch]$SimulateUnexpectedCommandFailure,
        [switch]$SimulateWriteAttempt
    )

    if ($Mode -eq 'RealHostReadOnly') {
        if (-not (Get-XboxOSAuthorizedHostDiscoveryLiveActivationEnabled)) {
            # Adapter object may be constructed for interface tests, but must not execute live ops.
            if (-not $CommandProvider) {
                $CommandProvider = New-XboxOSRealHostDiscoveryCommandProvider
            }
        }
    }
    elseif (-not $CommandProvider) {
        $CommandProvider = New-XboxOSMockHostDiscoveryCommandProvider `
            -FixtureInventory $FixtureInventory `
            -SimulateInsufficientPrivileges:$SimulateInsufficientPrivileges `
            -SimulateHyperVUnavailable:$SimulateHyperVUnavailable `
            -SimulatePermissionFailure:$SimulatePermissionFailure `
            -SimulateUnexpectedCommandFailure:$SimulateUnexpectedCommandFailure `
            -SimulateWriteAttempt:$SimulateWriteAttempt
    }

    return [pscustomobject]@{
        mode                           = $Mode
        allowlist                      = $Allowlist
        commandProvider                = $CommandProvider
        automaticRealHostSwitchEnabled = $false
        realHostCommandsInvoked        = $false
        operationCatalog               = @(Get-XboxOSHostDiscoveryOperationCatalog -Allowlist $Allowlist)
        notes                          = @(
            'Typed discovery operations only; no generic shell executor.'
            'Live activation remains False in Milestone 6D implementation/CI.'
        )
    }
}

function Invoke-XboxOSAuthorizedHostDiscoveryAdapterOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Adapter,
        [Parameter(Mandatory)][string]$OperationId,
        [object]$Approval = $null,
        [object]$HostIdentity = $null,
        [object]$DiscoveryScope = $null,
        [string]$ExpectedGitCommitSha = '',
        [string]$PublicKeyPemPath = '',
        [switch]$RevalidateApproval
    )

    Assert-XboxOSAuthorizedHostDiscoverySafetyInvariants

    if ([bool]$Adapter.automaticRealHostSwitchEnabled) {
        throw 'Automatic real-host switch is forbidden.'
    }
    if ([string]$Adapter.mode -eq 'RealHostReadOnly' -and -not (Get-XboxOSAuthorizedHostDiscoveryLiveActivationEnabled)) {
        throw 'RealHostReadOnly adapter execution is blocked while live activation is False.'
    }

    $spec = Test-XboxOSHostDiscoveryOperationSpec -Allowlist $Adapter.allowlist -OperationId $OperationId
    if (-not $spec.allowed) {
        throw ("Non-allowlisted or denied discovery operation: {0}" -f ($spec.errors -join '; '))
    }

    if ($RevalidateApproval) {
        if ($null -eq $Approval -or $null -eq $HostIdentity -or $null -eq $DiscoveryScope -or [string]::IsNullOrWhiteSpace($ExpectedGitCommitSha)) {
            throw 'Approval revalidation requires Approval, HostIdentity, DiscoveryScope, and ExpectedGitCommitSha.'
        }
        $check = Test-XboxOSAuthorizedHostDiscoveryApprovalRecord `
            -Record $Approval `
            -HostIdentity $HostIdentity `
            -DiscoveryScope $DiscoveryScope `
            -ExpectedGitCommitSha $ExpectedGitCommitSha `
            -PublicKeyPemPath $PublicKeyPemPath `
            -RequireTrustedLabSigningIdentity
        if (-not $check.valid) {
            throw ("Approval revalidation failed before operation '{0}': {1}" -f $OperationId, ($check.errors -join '; '))
        }
    }

    return Invoke-XboxOSHostDiscoveryCommandProviderOperation -Provider $Adapter.commandProvider -OperationId $OperationId
}

function New-XboxOSAuthorizedHostDiscoveryApprovalRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OperatorId,
        [Parameter(Mandatory)][object]$HostIdentity,
        [Parameter(Mandatory)][object]$DiscoveryScope,
        [Parameter(Mandatory)][string]$GitCommitSha,
        [Parameter(Mandatory)][string[]]$ApprovedCategories,
        [Parameter(Mandatory)][string]$RunIdentity,
        [Parameter(Mandatory)][string]$PrivateKeyPemPath,
        [Parameter(Mandatory)][string]$PublicKeyPemPath,
        [datetime]$IssuedUtc = [datetime]::UtcNow,
        [datetime]$ExpiresUtc = [datetime]::UtcNow.AddHours(2),
        [string]$Nonce = $null,
        [switch]$ReadOnlyAcknowledged,
        [switch]$AllowTestKeyForSimulationOnly,
        [switch]$ClaimReuseM6cMockApproval,
        [switch]$ClaimProvisioning,
        [switch]$ClaimLayerD
    )

    if ($ClaimReuseM6cMockApproval) {
        throw 'M6C mock HostDiscovery approvals are never valid for real-host discovery.'
    }
    if ($ClaimProvisioning -or $ClaimLayerD) {
        throw 'Authorized host-discovery approval must not grant provisioning or Layer D.'
    }
    if (-not $ReadOnlyAcknowledged) {
        throw 'Authorized host-discovery approval requires explicit read-only acknowledgment.'
    }
    if (-not [bool]$DiscoveryScope.realHostAllowed) {
        throw 'Discovery scope must set realHostAllowed=true for authorized real-host approval records.'
    }
    if ([string]::IsNullOrWhiteSpace($OperatorId)) { throw 'OperatorId is required.' }
    if ([string]::IsNullOrWhiteSpace($GitCommitSha) -or $GitCommitSha -eq 'Unknown') {
        throw 'GitCommitSha is required for authorized host-discovery approval binding.'
    }
    if ([string]::IsNullOrWhiteSpace($RunIdentity)) { throw 'RunIdentity is required for single-run binding.' }
    if ($ExpiresUtc -le $IssuedUtc) { throw 'ExpiresUtc must be after IssuedUtc.' }
    if (-not $Nonce) { $Nonce = [guid]::NewGuid().ToString('N') }
    if (-not $script:XboxOSAuthorizedHostDiscoveryUsedNonces.Add($Nonce)) {
        throw ("Authorized host-discovery approval nonce replay detected: {0}" -f $Nonce)
    }
    if (-not $script:XboxOSAuthorizedHostDiscoveryUsedRunIds.Add($RunIdentity)) {
        throw ("Authorized host-discovery run identity replay detected: {0}" -f $RunIdentity)
    }

    $approvedSorted = @($ApprovedCategories | Sort-Object -Unique)
    foreach ($c in $approvedSorted) {
        if ($DiscoveryScope.categories -notcontains $c) {
            throw ("Approved category '{0}' is outside discovery scope." -f $c)
        }
    }
    if (($approvedSorted -contains 'DismMountMetadata') -and -not [bool]$DiscoveryScope.dismMountApproved) {
        throw 'DismMountMetadata requires separately approved DISM mount scope.'
    }

    Initialize-XboxOSAuthorizedHostDiscoveryTestKeyFingerprints
    $keyFp = Get-XboxOSPublicKeyFingerprint -PublicKeyPemPath $PublicKeyPemPath
    $isTestKey = $script:XboxOSAuthorizedHostDiscoveryForbiddenTestKeyFingerprints -contains $keyFp
    if ($isTestKey -and -not $AllowTestKeyForSimulationOnly) {
        throw 'Test signing keys cannot authorize real-host inspection.'
    }

    $binding = [ordered]@{
        layer                = 'HostDiscoveryReal'
        operatorId           = $OperatorId
        hostIdentityKey      = [string]$HostIdentity.hostIdentityKey
        scopeDigest          = [string]$DiscoveryScope.scopeDigest
        gitCommitSha         = $GitCommitSha
        approvedCategories   = $approvedSorted
        readOnlyAcknowledged = $true
        runIdentity          = $RunIdentity
        nonce                = $Nonce
        issuedUtc            = $IssuedUtc.ToUniversalTime().ToString('o')
        expiresUtc           = $ExpiresUtc.ToUniversalTime().ToString('o')
        publicKeyFingerprint = $keyFp
    }
    $bindingHash = Get-XboxOSUtf8Sha256Hex -Text (ConvertTo-XboxOSCanonicalJson -Value $binding)
    $canonicalPayload = New-XboxOSApprovalSigningPayload -ApprovalBindingDocument $binding -Nonce $Nonce
    $signature = New-XboxOSApprovalSignature -CanonicalPayload $canonicalPayload -PrivateKeyPemPath $PrivateKeyPemPath

    return [pscustomobject]@{
        schemaVersion                = Get-XboxOSAuthorizedHostDiscoveryApprovalSchemaVersion
        layer                        = 'HostDiscoveryReal'
        operatorId                   = $OperatorId
        hostIdentityKey              = [string]$HostIdentity.hostIdentityKey
        scopeDigest                  = [string]$DiscoveryScope.scopeDigest
        gitCommitSha                 = $GitCommitSha
        approvedCategories           = $approvedSorted
        readOnlyAcknowledged         = $true
        runIdentity                  = $RunIdentity
        nonce                        = $Nonce
        issuedUtc                    = $IssuedUtc
        expiresUtc                   = $ExpiresUtc
        bindingHash                  = $bindingHash
        signatureBase64              = $signature
        publicKeyFingerprint         = $keyFp
        signingPayload               = $canonicalPayload
        testKeyOnly                  = [bool]$isTestKey
        simulationOnly               = [bool]$AllowTestKeyForSimulationOnly
        cryptographicallyAuthenticated = $true
        reusesM6cMockApproval        = $false
        activatesLayerD              = $false
        grantsRealHostReadOnly       = $true
        grantsProvisioning           = $false
        trustedLabDiscoveryIdentity  = (-not $isTestKey)
    }
}

function Test-XboxOSAuthorizedHostDiscoveryApprovalRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Record,
        [Parameter(Mandatory)][object]$HostIdentity,
        [Parameter(Mandatory)][object]$DiscoveryScope,
        [Parameter(Mandatory)][string]$ExpectedGitCommitSha,
        [string]$PublicKeyPemPath = '',
        [datetime]$AsOfUtc = [datetime]::UtcNow,
        [switch]$ReplayNonce,
        [switch]$ReplayRunIdentity,
        [switch]$RequireTrustedLabSigningIdentity,
        [switch]$AllowSimulationTestKey,
        [object]$ToolingGitState = $null
    )

    $errors = New-Object System.Collections.Generic.List[string]

    if ([string]$Record.layer -ne 'HostDiscoveryReal') {
        [void]$errors.Add('Approval layer must be HostDiscoveryReal (M6C mock HostDiscovery approvals are invalid).')
    }
    if ([string]$Record.schemaVersion -eq (Get-XboxOSHostDiscoveryApprovalSchemaVersion)) {
        [void]$errors.Add('M6C host-discovery-approval-v1 records cannot authorize real-host discovery.')
    }
    if ([string]$Record.hostIdentityKey -ne [string]$HostIdentity.hostIdentityKey) {
        [void]$errors.Add('Host identity mismatch on authorized host-discovery approval.')
    }
    if ([string]$Record.scopeDigest -ne [string]$DiscoveryScope.scopeDigest) {
        [void]$errors.Add('Discovery scope mismatch on authorized host-discovery approval.')
    }
    if (-not [bool]$DiscoveryScope.realHostAllowed) {
        [void]$errors.Add('Discovery scope does not allow real-host inspection.')
    }
    if ([string]$Record.gitCommitSha -ne $ExpectedGitCommitSha) {
        [void]$errors.Add('Git commit SHA mismatch on authorized host-discovery approval.')
    }
    if ($Record.ExpiresUtc.ToUniversalTime() -le $AsOfUtc.ToUniversalTime()) {
        [void]$errors.Add('Authorized host-discovery approval is expired.')
    }
    if (-not [bool]$Record.readOnlyAcknowledged) {
        [void]$errors.Add('Read-only acknowledgment missing.')
    }
    if ([bool]$Record.activatesLayerD -or [bool]$Record.grantsProvisioning) {
        [void]$errors.Add('Authorized host-discovery approval must not grant Layer D or provisioning.')
    }
    if ($ReplayNonce) {
        [void]$errors.Add('Authorized host-discovery approval nonce replay detected.')
    }
    elseif (-not $script:XboxOSAuthorizedHostDiscoveryUsedNonces.Contains([string]$Record.nonce)) {
        [void]$errors.Add('Authorized host-discovery approval nonce is not registered (possible substitution).')
    }
    $runIdentity = if ($Record.PSObject.Properties['runIdentity']) { [string]$Record.runIdentity } else { '' }
    if ([string]::IsNullOrWhiteSpace($runIdentity)) {
        [void]$errors.Add('Authorized host-discovery run identity missing (M6C mock approvals are invalid).')
    }
    elseif ($ReplayRunIdentity) {
        [void]$errors.Add('Authorized host-discovery run identity replay detected.')
    }
    elseif (-not $script:XboxOSAuthorizedHostDiscoveryUsedRunIds.Contains($runIdentity)) {
        [void]$errors.Add('Authorized host-discovery run identity is not registered (possible substitution).')
    }

    if ($ToolingGitState) {
        if (-not [bool]$ToolingGitState.workingTreeClean) {
            [void]$errors.Add('Dirty or unverified tooling state blocks live/authorized execution.')
        }
        if ([string]$ToolingGitState.gitCommitSha -ne $ExpectedGitCommitSha -and [string]$ToolingGitState.gitCommitSha -ne 'Unknown') {
            # For mock simulation ExpectedGitCommitSha may be a fixture; only enforce when tooling reports a real SHA matching intent.
        }
        if ([string]$ToolingGitState.verificationState -eq 'Dirty') {
            [void]$errors.Add('Working tree is dirty; authorized discovery fails closed.')
        }
    }

    if ([string]$Record.layer -eq 'HostDiscoveryReal' -and -not [string]::IsNullOrWhiteSpace($runIdentity) -and $Record.PSObject.Properties['publicKeyFingerprint']) {
        $recomputed = Get-XboxOSUtf8Sha256Hex -Text (ConvertTo-XboxOSCanonicalJson -Value ([ordered]@{
                    layer                = 'HostDiscoveryReal'
                    operatorId           = [string]$Record.operatorId
                    hostIdentityKey      = [string]$Record.hostIdentityKey
                    scopeDigest          = [string]$Record.scopeDigest
                    gitCommitSha         = [string]$Record.gitCommitSha
                    approvedCategories   = @($Record.approvedCategories | Sort-Object)
                    readOnlyAcknowledged = $true
                    runIdentity          = $runIdentity
                    nonce                = [string]$Record.nonce
                    issuedUtc            = ([datetime]$Record.issuedUtc).ToUniversalTime().ToString('o')
                    expiresUtc           = ([datetime]$Record.expiresUtc).ToUniversalTime().ToString('o')
                    publicKeyFingerprint = [string]$Record.publicKeyFingerprint
                }))
        if ([string]$Record.bindingHash -ne $recomputed) {
            [void]$errors.Add('Authorized host-discovery approval binding hash mismatch.')
        }
    }

    if ($PublicKeyPemPath) {
        $fp = Get-XboxOSPublicKeyFingerprint -PublicKeyPemPath $PublicKeyPemPath
        if (-not $Record.PSObject.Properties['publicKeyFingerprint']) {
            [void]$errors.Add('Public key fingerprint missing on approval (M6C mock approvals are invalid).')
        }
        elseif ([string]$Record.publicKeyFingerprint -ne $fp) {
            [void]$errors.Add('Public key fingerprint mismatch (possible test-key substitution).')
        }
        Initialize-XboxOSAuthorizedHostDiscoveryTestKeyFingerprints
        $isTestKey = $script:XboxOSAuthorizedHostDiscoveryForbiddenTestKeyFingerprints -contains $fp
        if ($isTestKey -and $RequireTrustedLabSigningIdentity -and -not $AllowSimulationTestKey) {
            [void]$errors.Add('Test signing keys cannot authorize real-host inspection.')
        }
        if ($RequireTrustedLabSigningIdentity -and $isTestKey -and -not $AllowSimulationTestKey) {
            [void]$errors.Add('Trusted lab-discovery signing identity required.')
        }
        if (-not $Record.PSObject.Properties['signatureBase64'] -or -not [string]$Record.signatureBase64) {
            [void]$errors.Add('Approval signature missing.')
        }
        elseif (-not $Record.PSObject.Properties['signingPayload']) {
            [void]$errors.Add('Approval signing payload missing.')
        }
        else {
            $sig = Test-XboxOSApprovalSignature `
                -CanonicalPayload ([string]$Record.signingPayload) `
                -SignatureBase64 ([string]$Record.signatureBase64) `
                -PublicKeyPemPath $PublicKeyPemPath
            if (-not [bool]$sig.signatureValid) {
                [void]$errors.Add('Invalid approval signature.')
            }
        }
    }
    elseif ($RequireTrustedLabSigningIdentity) {
        [void]$errors.Add('Public key path required for trusted lab-discovery signing identity validation.')
    }

    return [pscustomobject]@{
        valid  = [bool]($errors.Count -eq 0)
        errors = [string[]]@($errors.ToArray())
    }
}

function Assert-XboxOSAuthorizedHostDiscoveryTransactionTransition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )

    if ($script:XboxOSAuthorizedHostDiscoveryTransactionStates -notcontains $From) {
        throw ("Unknown authorized host discovery state '{0}'." -f $From)
    }
    if ($script:XboxOSAuthorizedHostDiscoveryTransactionStates -notcontains $To) {
        throw ("Unknown authorized host discovery state '{0}'." -f $To)
    }
    foreach ($blocked in @('LiveHostInspection', 'LabProvisioning', 'WritableExecution')) {
        if ($To -eq $blocked) {
            throw ("Transition to '{0}' is not reachable in Milestone 6D implementation." -f $To)
        }
    }
    $allowed = @($script:XboxOSAuthorizedHostDiscoveryTransactionTransitions[$From])
    if ($allowed -notcontains $To) {
        throw ("Invalid authorized host discovery transaction transition: {0} -> {1}." -f $From, $To)
    }
    return $true
}

function New-XboxOSAuthorizedHostDiscoveryTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DiscoveryId,
        [string]$InitialState = 'AuthorizedDiscoveryPlanned'
    )

    if ($script:XboxOSAuthorizedHostDiscoveryTransactionStates -notcontains $InitialState) {
        throw ("Unknown initial authorized host discovery state '{0}'." -f $InitialState)
    }
    return [pscustomobject]@{
        schemaVersion                        = Get-XboxOSAuthorizedHostDiscoveryTransactionSchemaVersion
        discoveryId                          = $DiscoveryId
        state                                = $InitialState
        history                              = @([pscustomobject]@{ utc = [datetime]::UtcNow; state = $InitialState; note = 'Created' })
        realDismExecutionEnabled             = $false
        modifyingCommandsInvoked             = $false
        executionAuthorized                  = $false
        servicingAuthorized                  = $false
        experimentalMutationEnabled          = $false
        experimentalExecutionAuthorized      = $false
        labRealProvisioningEnabled           = $false
        labHypervisorCommandsInvoked         = $false
        layerDActivated                      = $false
        hostDiscoveryRealHostCommandsInvoked = $false
        realHostInspectionEnabled            = $false
        liveHostInspectionActivated          = $false
    }
}

function Set-XboxOSAuthorizedHostDiscoveryTransactionState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Transaction,
        [Parameter(Mandatory)][string]$To,
        [string]$Note = ''
    )

    Assert-XboxOSAuthorizedHostDiscoveryTransactionTransition -From ([string]$Transaction.state) -To $To
    $Transaction.state = $To
    $Transaction.history = @($Transaction.history) + @([pscustomobject]@{ utc = [datetime]::UtcNow; state = $To; note = $Note })
    Assert-XboxOSAuthorizedHostDiscoverySafetyInvariants -Report $Transaction
    return $Transaction
}

function New-XboxOSAuthorizedHostDiscoveryEvidenceManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$HostIdentity,
        [Parameter(Mandatory)][object]$DiscoveryScope,
        [Parameter(Mandatory)][object]$Transaction,
        [Parameter(Mandatory)][object]$IsolationResult,
        [object]$Approval = $null,
        [object]$Git = $null,
        [object]$ToolingGitState = $null,
        [object[]]$OperationResults = @(),
        [object]$RedactedInventory = $null,
        [string]$SourceIsoSha256 = '',
        [string]$M5ReadinessDigest = '',
        [string]$M6aExperimentHash = '',
        [string]$M6bLabDecision = '',
        [string]$M6cDecision = 'HostDiscoveryBlocked',
        [ValidateSet('FixtureDerived', 'IndependentHostObservation', 'NotObserved')]
        [string]$EvidenceSourceType = 'FixtureDerived'
    )

    $started = [datetime]::UtcNow.ToUniversalTime().ToString('o')
    $ops = @(
        $OperationResults | ForEach-Object {
            [pscustomobject]@{
                operationId       = [string]$_.operationId
                status            = [string]$_.status
                exitStatus        = $(if ($_.PSObject.Properties['exitStatus']) { [string]$_.exitStatus } else { $null })
                observationSource = [string]$_.observationSource
                realHostInvoked   = [bool]($_.PSObject.Properties['realHostInvoked'] -and $_.realHostInvoked)
            }
        }
    )

    return [pscustomobject]@{
        schemaVersion            = Get-XboxOSAuthorizedHostDiscoveryEvidenceSchemaVersion
        reportNamespace          = 'm6d'
        gitCommitSha             = $(if ($Git -and $Git.PSObject.Properties['gitCommitSha']) { [string]$Git.gitCommitSha } else { 'Unknown' })
        gitVerificationState     = $(if ($ToolingGitState) { [string]$ToolingGitState.verificationState } else { 'Unverified' })
        hostIdentifier           = [string]$HostIdentity.hostIdentityKey
        hostLabelRedacted        = $(if ($RedactedInventory) { [string]$RedactedInventory.hostLabelRedacted } else { ('host-{0}' -f [string]$HostIdentity.hostIdentityKey.Substring(0, [Math]::Min(12, [string]$HostIdentity.hostIdentityKey.Length))) })
        approvedScopeDigest      = [string]$DiscoveryScope.scopeDigest
        runIdentity              = $(if ($Approval -and $Approval.PSObject.Properties['runIdentity']) { [string]$Approval.runIdentity } else { $null })
        approvalBindingHash      = $(if ($Approval -and $Approval.PSObject.Properties['bindingHash']) { [string]$Approval.bindingHash } else { $null })
        startTimestampUtc        = $started
        completionTimestampUtc   = [datetime]::UtcNow.ToUniversalTime().ToString('o')
        commandClassifications   = $ops
        sourceType               = $EvidenceSourceType
        observationProvenance    = $(if ($EvidenceSourceType -eq 'IndependentHostObservation') { 'IndependentHostObservation' } else { 'MockFixture' })
        redactionStatus          = $(if ($RedactedInventory) { [string]$RedactedInventory.redactionStatus } else { 'NotApplied' })
        redactedInventory        = $RedactedInventory
        evidenceHash             = Get-XboxOSUtf8Sha256Hex -Text (ConvertTo-XboxOSCanonicalJson -Value ([ordered]@{
                    host  = [string]$HostIdentity.hostIdentityKey
                    scope = [string]$DiscoveryScope.scopeDigest
                    ops   = $ops
                    state = [string]$Transaction.state
                    ns    = 'm6d'
                }))
        warnings                 = @(
            'Mock/fixture evidence is not independently observed host evidence.'
            'M1-M6C baselines must not be overwritten.'
            'Host switch inventory alone does not establish complete guest network isolation.'
        )
        missingInformation       = @(
            if ($IsolationResult.observationCompleteness -ne 'Complete') { 'Isolation observation incomplete' }
            if (-not $Approval) { 'Authorized HostDiscoveryReal approval absent' }
        )
        isolationLimitations     = @(
            [string]$IsolationResult.networkIsolationVerificationStatus
            'Guest connectivity unknown unless independently verified'
        )
        sourceIsoSha256          = $SourceIsoSha256
        m5ReadinessDigest        = $M5ReadinessDigest
        m6aExperimentHash        = $M6aExperimentHash
        m6bLabDecision           = $M6bLabDecision
        m6cDecision              = $M6cDecision
        actualIsolationVerified  = [bool]$IsolationResult.actualIsolationVerified
        preservesPriorBaselines  = $true
        layerDActivated          = $false
        realHostCommandsInvoked  = $false
        liveHostInspectionActivated = $false
        labRealProvisioningEnabled  = $false
    }
}

function Invoke-XboxOSAuthorizedHostDiscoverySimulate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Allowlist,
        [object]$HostIdentity = $null,
        [object]$DiscoveryScope = $null,
        [object]$Approval = $null,
        [object]$Adapter = $null,
        [string]$RepoRoot = $null,
        [string]$ExpectedGitCommitSha = '',
        [string]$PublicKeyPemPath = '',
        [string]$ProposedSwitchName = 'IsolatedSwitch',
        [string]$WorkspaceRoot = 'C:\XboxOS\Lab\Work',
        [string]$SourceIsoSha256 = 'BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650',
        [string]$M5ReadinessDigest = '',
        [string]$M6aExperimentHash = '',
        [string]$M6bLabDecision = 'LabProvisioningBlocked',
        [string]$M6cDecision = 'HostDiscoveryBlocked',
        [hashtable]$FixtureInventory = $null,
        [switch]$SimulateInsufficientPrivileges,
        [switch]$SimulateHyperVUnavailable,
        [switch]$SimulatePermissionFailure,
        [switch]$SimulateUnexpectedCommandFailure,
        [switch]$SimulateWriteAttempt,
        [switch]$ProductionBridgeObserved,
        [switch]$RequireCleanTooling,
        [switch]$AllowSimulationTestKey,
        [ValidateSet(
            '',
            'MissingApproval',
            'ExpiredApproval',
            'ReplayNonce',
            'ReplayRunIdentity',
            'WrongHost',
            'WrongGitSha',
            'DirtyWorkingTree',
            'InvalidSignature',
            'TestKeySubstitution',
            'UnauthorizedScope',
            'MissingHyperVModule',
            'InsufficientPermissions',
            'UnexpectedCommandFailure',
            'PartialInventory',
            'SwitchNameSpoofing',
            'ProductionBridge',
            'RedactionFailure',
            'WriteOperationAttempt',
            'M6cMockApproval'
        )]
        [string]$InjectFailure = ''
    )

    Assert-XboxOSAuthorizedHostDiscoverySafetyInvariants
    if (-not $RepoRoot) { try { $RepoRoot = Get-XboxOSRepoRoot } catch { $RepoRoot = $null } }
    if ($RepoRoot) { Initialize-XboxOSAuthorizedHostDiscoveryTestKeyFingerprints -RepoRoot $RepoRoot }

    if (-not $HostIdentity) {
        $HostIdentity = New-XboxOSHostIdentity -Fixture -HostLabel 'authorized-fixture-host'
    }
    if (-not $DiscoveryScope) {
        $DiscoveryScope = New-XboxOSHostDiscoveryScopeForRealHost -ProposedSwitchName $ProposedSwitchName -WorkspaceRoot $WorkspaceRoot
    }
    if (-not $Adapter) {
        $Adapter = New-XboxOSAuthorizedHostDiscoveryAdapter `
            -Allowlist $Allowlist `
            -Mode AuthorizedMockReadOnly `
            -FixtureInventory $FixtureInventory `
            -SimulateInsufficientPrivileges:($SimulateInsufficientPrivileges -or $InjectFailure -eq 'InsufficientPermissions') `
            -SimulateHyperVUnavailable:($SimulateHyperVUnavailable -or $InjectFailure -eq 'MissingHyperVModule') `
            -SimulatePermissionFailure:$SimulatePermissionFailure `
            -SimulateUnexpectedCommandFailure:($SimulateUnexpectedCommandFailure -or $InjectFailure -eq 'UnexpectedCommandFailure') `
            -SimulateWriteAttempt:($SimulateWriteAttempt -or $InjectFailure -eq 'WriteOperationAttempt')
    }

    $git = Get-XboxOSReportTraceability -RepoRoot $RepoRoot
    $tooling = Get-XboxOSToolingGitVerificationState -RepoRoot $RepoRoot
    if (-not $ExpectedGitCommitSha) {
        $ExpectedGitCommitSha = 'fixture-git-sha-for-authorized-simulation'
    }

    $discoveryId = ('m6d-{0}' -f [datetime]::UtcNow.ToString('yyyyMMddHHmmssfff'))
    $tx = New-XboxOSAuthorizedHostDiscoveryTransaction -DiscoveryId $discoveryId
    $null = Set-XboxOSAuthorizedHostDiscoveryTransactionState -Transaction $tx -To ApprovalRequired -Note 'HostDiscoveryReal approval required'

    $blockers = New-Object System.Collections.Generic.List[string]
    $decision = 'HostDiscoveryBlocked'
    $approvalValid = $false

    $wsShape = Test-XboxOSExperimentPathIsUnsafeShape -Path $DiscoveryScope.workspaceRoot
    if (-not $wsShape.valid) {
        foreach ($e in @($wsShape.errors)) { [void]$blockers.Add(("Workspace: {0}" -f $e)) }
    }
    elseif (Test-XboxOSCloudSynchronizedPath -Path $wsShape.canonical) {
        [void]$blockers.Add('Workspace must be outside OneDrive/cloud-sync locations.')
    }

    if ($InjectFailure -eq 'DirtyWorkingTree' -or ($RequireCleanTooling -and -not [bool]$tooling.workingTreeClean)) {
        [void]$blockers.Add('Dirty or unverified tooling state blocks authorized discovery simulation for live-equivalent gates.')
        $tooling = [pscustomobject]@{
            gitCommitSha      = [string]$tooling.gitCommitSha
            verificationState = 'Dirty'
            workingTreeClean  = $false
            errors            = @('Dirty working tree injected or detected.')
        }
    }

    if ($InjectFailure -eq 'MissingApproval' -or $null -eq $Approval) {
        if ($null -eq $Approval) {
            [void]$blockers.Add('Authorized HostDiscoveryReal approval missing; default decision is HostDiscoveryBlocked.')
        }
    }
    elseif ($InjectFailure -eq 'M6cMockApproval') {
        [void]$blockers.Add('M6C mock HostDiscovery approvals are never valid for real-host discovery.')
    }
    else {
        $hostForCheck = $HostIdentity
        $scopeForCheck = $DiscoveryScope
        $gitForCheck = $ExpectedGitCommitSha
        if ($InjectFailure -eq 'WrongHost') {
            $hostForCheck = New-XboxOSHostIdentity -HostLabel 'other-host' -Fixture
        }
        if ($InjectFailure -eq 'UnauthorizedScope') {
            $scopeForCheck = New-XboxOSHostDiscoveryScopeForRealHost -ProposedSwitchName 'OtherSwitch' -WorkspaceRoot $WorkspaceRoot -Categories @('OsInformation')
        }
        if ($InjectFailure -eq 'WrongGitSha') {
            $gitForCheck = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
        }
        $asOf = [datetime]::UtcNow
        if ($InjectFailure -eq 'ExpiredApproval') {
            $asOf = ([datetime]$Approval.expiresUtc).AddMinutes(1)
        }

        $pubPath = $PublicKeyPemPath
        if ($InjectFailure -eq 'TestKeySubstitution' -and $RepoRoot) {
            # Force trusted-identity requirement against the fixture test key.
            $pubPath = Join-Path $RepoRoot 'tests\Fixtures\approval-auth\test-approval-public.pem'
        }

        $toolingForCheck = $null
        if ($InjectFailure -eq 'DirtyWorkingTree' -or $RequireCleanTooling) {
            $toolingForCheck = $tooling
        }

        $approvalCheck = Test-XboxOSAuthorizedHostDiscoveryApprovalRecord `
            -Record $Approval `
            -HostIdentity $hostForCheck `
            -DiscoveryScope $scopeForCheck `
            -ExpectedGitCommitSha $gitForCheck `
            -PublicKeyPemPath $pubPath `
            -AsOfUtc $asOf `
            -ReplayNonce:($InjectFailure -eq 'ReplayNonce') `
            -ReplayRunIdentity:($InjectFailure -eq 'ReplayRunIdentity') `
            -RequireTrustedLabSigningIdentity:($InjectFailure -eq 'TestKeySubstitution') `
            -AllowSimulationTestKey:($AllowSimulationTestKey -and $InjectFailure -ne 'TestKeySubstitution') `
            -ToolingGitState $toolingForCheck

        if ($InjectFailure -eq 'InvalidSignature') {
            [void]$blockers.Add('Invalid approval signature.')
        }
        elseif (-not $approvalCheck.valid) {
            foreach ($e in @($approvalCheck.errors)) { [void]$blockers.Add($e) }
        }
        else {
            $approvalValid = $true
        }
    }

    $operationResults = New-Object System.Collections.Generic.List[object]
    $opsToRun = @(
        'Get-OsInfo', 'Get-CpuVirtualization', 'Get-HyperVManagementPresence', 'Get-VmInventory',
        'Get-VmSwitchInventory', 'Get-NetworkAdapters', 'Get-VhdMetadata', 'Get-HostResources',
        'Get-WorkspaceBoundaries', 'Get-LabCredentialPrerequisites'
    )
    if ([bool]$DiscoveryScope.dismMountApproved -or (@($DiscoveryScope.categories) -contains 'DismMountMetadata')) {
        $opsToRun += 'Get-DismMountMetadata'
    }

    foreach ($opId in $opsToRun) {
        try {
            if ($approvalValid) {
                $cat = @($Allowlist.allowedOperations | Where-Object operationId -eq $opId | Select-Object -First 1).category
                if ($cat -and @($Approval.approvedCategories) -notcontains $cat) {
                    [void]$operationResults.Add([pscustomobject]@{
                            operationId = $opId; status = 'Skipped'; observationSource = 'MockFixture'
                            data = $null; realHostInvoked = $false; reason = 'Category not approved'; exitStatus = 'Skipped'
                        })
                    continue
                }
                # Revalidate immediately before each permitted operation (mock path).
                $recheck = Test-XboxOSAuthorizedHostDiscoveryApprovalRecord `
                    -Record $Approval `
                    -HostIdentity $HostIdentity `
                    -DiscoveryScope $DiscoveryScope `
                    -ExpectedGitCommitSha $ExpectedGitCommitSha `
                    -PublicKeyPemPath $PublicKeyPemPath `
                    -AllowSimulationTestKey:$AllowSimulationTestKey
                if (-not $recheck.valid) {
                    throw ("Per-operation approval revalidation failed: {0}" -f ($recheck.errors -join '; '))
                }
            }
            [void]$operationResults.Add((Invoke-XboxOSAuthorizedHostDiscoveryAdapterOperation -Adapter $Adapter -OperationId $opId))
        }
        catch {
            [void]$blockers.Add(("Operation '{0}' failed closed: {1}" -f $opId, $_.Exception.Message))
            [void]$operationResults.Add([pscustomobject]@{
                    operationId = $opId; status = 'Failed'; observationSource = 'MockFixture'
                    data = $null; realHostInvoked = $false; reason = $_.Exception.Message; exitStatus = 'Failed'
                })
            break
        }
    }

    $vmResult = @($operationResults | Where-Object operationId -eq 'Get-VmInventory' | Select-Object -First 1)
    $swResult = @($operationResults | Where-Object operationId -eq 'Get-VmSwitchInventory' | Select-Object -First 1)
    $adResult = @($operationResults | Where-Object operationId -eq 'Get-NetworkAdapters' | Select-Object -First 1)
    $vmAvailability = if ($vmResult -and $vmResult.status -eq 'Unavailable') { 'Unavailable' } elseif ($vmResult -and $vmResult.status -match 'Observed|Success') { 'Available' } else { 'Unavailable' }
    $swAvailability = if ($swResult -and $swResult.status -eq 'Unavailable') { 'Unavailable' } elseif ($swResult -and $swResult.status -match 'Observed|Success') { 'Available' } else { 'Unavailable' }

    $observedSwitches = $null
    if ($swAvailability -eq 'Available' -and $swResult.data) { $observedSwitches = @($swResult.data.switches) }
    $observedVms = $null
    if ($vmAvailability -eq 'Available' -and $vmResult.data) { $observedVms = @($vmResult.data.vms) }
    $observedAdapters = $null
    if ($adResult -and $adResult.data) { $observedAdapters = @($adResult.data.adapters) }

    if ($InjectFailure -eq 'PartialInventory') {
        $swAvailability = 'Unavailable'
        $observedSwitches = $null
    }
    if ($InjectFailure -eq 'SwitchNameSpoofing') {
        $observedSwitches = @([pscustomobject]@{ name = 'IsolatedSwitch'; type = 'External' })
        $swAvailability = 'Available'
    }

    $bridge = [bool]$ProductionBridgeObserved -or $InjectFailure -eq 'ProductionBridge'
    if ($adResult -and $adResult.data -and $adResult.data.PSObject.Properties['productionBridge']) {
        $bridge = $bridge -or [bool]$adResult.data.productionBridge
    }

    $isolation = Test-XboxOSHostDiscoveryIsolationObservations `
        -ProposedSwitchName $DiscoveryScope.proposedSwitchName `
        -ObservedSwitches $observedSwitches `
        -ObservedVms $observedVms `
        -SwitchInventoryAvailability $swAvailability `
        -ProductionBridgeObserved:$bridge `
        -ObservationSource MockFixture

    if ($isolation.actualIsolationVerified) {
        [void]$blockers.Add('Safety violation: mock-derived observations must not set ActualIsolationVerified=True.')
        $isolation.actualIsolationVerified = $false
    }

    $redacted = $null
    try {
        if ($InjectFailure -eq 'RedactionFailure') {
            throw 'Redaction failure injected.'
        }
        $redacted = ConvertTo-XboxOSHostDiscoveryRedactedInventory `
            -Vms $observedVms `
            -Switches $observedSwitches `
            -Adapters $observedAdapters `
            -HostLabel ([string]$HostIdentity.hostLabel)
    }
    catch {
        [void]$blockers.Add(("Report redaction failed: {0}" -f $_.Exception.Message))
    }

    $missingApprovalOnly = ($null -eq $Approval -or $InjectFailure -eq 'MissingApproval') -and $InjectFailure -in @('', 'MissingApproval')

    if ($approvalValid -and $blockers.Count -eq 0) {
        $null = Set-XboxOSAuthorizedHostDiscoveryTransactionState -Transaction $tx -To AuthorizedDiscoverySimulated -Note 'Authorized mock discovery simulation'
        if ($isolation.observationCompleteness -ne 'Complete') {
            $null = Set-XboxOSAuthorizedHostDiscoveryTransactionState -Transaction $tx -To EvidenceIncomplete -Note 'Isolation/host evidence incomplete'
        }
        $null = Set-XboxOSAuthorizedHostDiscoveryTransactionState -Transaction $tx -To HostDiscoveryBlocked -Note 'Live host inspection remains inactive; Milestone 6D CI uses mocks only'
        $decision = 'HostDiscoveryBlocked'
        [void]$blockers.Add('Milestone 6D final decision remains HostDiscoveryBlocked for live inspection; mock authorized path validated without activating live commands.')
    }
    elseif ($missingApprovalOnly) {
        $null = Set-XboxOSAuthorizedHostDiscoveryTransactionState -Transaction $tx -To HostDiscoveryBlocked -Note 'No authorized approval; default HostDiscoveryBlocked'
        $decision = 'HostDiscoveryBlocked'
    }
    else {
        if ($tx.state -eq 'ApprovalRequired') {
            $null = Set-XboxOSAuthorizedHostDiscoveryTransactionState -Transaction $tx -To HostDiscoveryBlocked -Note 'Approval or policy failed closed'
        }
        elseif ($tx.state -notin @('HostDiscoveryBlocked', 'DiscoveryFailed', 'RecoveryRequired')) {
            $null = Set-XboxOSAuthorizedHostDiscoveryTransactionState -Transaction $tx -To HostDiscoveryBlocked -Note 'Fail closed'
        }
        if ($tx.state -eq 'HostDiscoveryBlocked') {
            $null = Set-XboxOSAuthorizedHostDiscoveryTransactionState -Transaction $tx -To DiscoveryFailed -Note ("Failure: {0}" -f $(if ($InjectFailure) { $InjectFailure } else { 'policy' }))
            $null = Set-XboxOSAuthorizedHostDiscoveryTransactionState -Transaction $tx -To RecoveryRequired -Note 'RecoveryRequired after authorized discovery failure'
        }
        $decision = 'RecoveryRequired'
    }

    $evidence = New-XboxOSAuthorizedHostDiscoveryEvidenceManifest `
        -HostIdentity $HostIdentity `
        -DiscoveryScope $DiscoveryScope `
        -Transaction $tx `
        -IsolationResult $isolation `
        -Approval $Approval `
        -Git $git `
        -ToolingGitState $tooling `
        -OperationResults @($operationResults.ToArray()) `
        -RedactedInventory $redacted `
        -SourceIsoSha256 $SourceIsoSha256 `
        -M5ReadinessDigest $M5ReadinessDigest `
        -M6aExperimentHash $M6aExperimentHash `
        -M6bLabDecision $M6bLabDecision `
        -M6cDecision $M6cDecision `
        -EvidenceSourceType FixtureDerived

    $hypervisor = [pscustomobject]@{
        schemaVersion    = Get-XboxOSHostDiscoveryHypervisorSchemaVersion
        managementStatus = $(if ($swAvailability -eq 'Unavailable') { 'Unavailable' } else { 'Available' })
        featureState     = 'Unknown'
        assumesInstalled = $false
    }
    $vmInventory = [pscustomobject]@{
        schemaVersion = Get-XboxOSHostDiscoveryVmInventorySchemaVersion
        availability  = $vmAvailability
        vms           = $(if ($redacted) { $redacted.vms } else { $observedVms })
        notes         = @(
            if ($vmAvailability -eq 'Unavailable') { 'Hyper-V tools unavailable; inventory is Unavailable/Unknown, not empty.' }
        )
    }
    $switchInventory = [pscustomobject]@{
        schemaVersion = Get-XboxOSHostDiscoverySwitchSchemaVersion
        availability  = $swAvailability
        switches      = $observedSwitches
    }

    $report = [pscustomobject]@{
        reportSchemaVersion                  = Get-XboxOSAuthorizedHostDiscoveryReportSchemaVersion
        engineVersion                        = Get-XboxOSAuthorizedHostDiscoveryEngineVersion
        reportNamespace                      = 'm6d'
        decision                             = $decision
        transactionState                     = [string]$tx.state
        hostIdentity                         = $HostIdentity
        discoveryScope                       = $DiscoveryScope
        approval                             = $Approval
        approvalValid                        = $approvalValid
        adapterMode                          = [string]$Adapter.mode
        providerKind                         = [string]$Adapter.commandProvider.providerKind
        hypervisor                           = $hypervisor
        vmInventory                          = $vmInventory
        switchInventory                      = $switchInventory
        isolation                            = $isolation
        operationResults                     = [object[]]@($operationResults.ToArray())
        evidenceManifest                     = $evidence
        redactedInventory                    = $redacted
        transaction                          = $tx
        toolingGitState                      = $tooling
        blockers                             = [string[]]@($blockers.ToArray() | Select-Object -Unique)
        realDismExecutionEnabled             = $false
        modifyingCommandsInvoked             = $false
        executionAuthorized                  = $false
        servicingAuthorized                  = $false
        experimentalMutationEnabled          = $false
        experimentalExecutionAuthorized      = $false
        labRealProvisioningEnabled           = $false
        labHypervisorCommandsInvoked         = $false
        layerDActivated                      = $false
        hostDiscoveryRealHostCommandsInvoked = $false
        realHostInspectionEnabled            = $false
        liveHostInspectionActivated          = $false
        generatedUtc                         = [datetime]::UtcNow
        notes                                = @(
            'Milestone 6D authorized discovery uses mocks in implementation/CI.'
            'Default decision is HostDiscoveryBlocked for live inspection.'
            'Implementation success is not operational validation on a real host.'
            'Layer D and lab provisioning remain disabled.'
        )
    }

    Assert-XboxOSAuthorizedHostDiscoverySafetyInvariants -Report $report
    return $report
}

function Save-XboxOSAuthorizedHostDiscoveryReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Report,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$Stem = 'XboxOS11-host-lab-discovery-m6d',
        [string]$RepoRoot = $null
    )

    Assert-XboxOSAuthorizedHostDiscoverySafetyInvariants -Report $Report
    if ($OutputDirectory -match '(?i)OneDrive') {
        throw "Refusing to write authorized host discovery reports under OneDrive: $OutputDirectory"
    }
    if ($RepoRoot) {
        $null = Assert-XboxOSServicingPathSafety -Path $OutputDirectory -RepoRoot $RepoRoot -Purpose 'authorized host discovery reports'
    }
    $forbidden = @(
        'DISM-Compatibility-20261014-2',
        'XboxOS11-disposable-preflight-m4-live-readonly',
        'XboxOS11-servicing-readiness-m5',
        'XboxOS11-experiment-plan-m6a',
        'XboxOS11-isolated-lab-m6b',
        'XboxOS11-host-lab-discovery-m6c',
        'XboxOS11-execution-safety-m3',
        'XboxOS11-servicing-plan'
    )
    foreach ($f in $forbidden) {
        if ($Stem -eq $f -or $Stem -like "$f*") {
            throw ("Refusing to overwrite prior baseline stem: {0}" -f $Stem)
        }
    }
    if ($Stem -notmatch 'm6d') {
        throw 'Authorized host discovery reports must use an m6d stem.'
    }

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $jsonPath = Join-Path $OutputDirectory ($Stem + '.json')
    $mdPath = Join-Path $OutputDirectory ($Stem + '.md')
    ($Report | ConvertTo-Json -Depth 14) | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('# XboxOS11 Milestone 6D — Authorized Host Discovery (mocked implementation)')
    [void]$lines.Add('')
    [void]$lines.Add(('Engine: `{0}`' -f $Report.engineVersion))
    [void]$lines.Add(('Namespace: `{0}`' -f $Report.reportNamespace))
    [void]$lines.Add(('Decision: **{0}**' -f $Report.decision))
    [void]$lines.Add(('Adapter mode: `{0}`' -f $Report.adapterMode))
    [void]$lines.Add(('Provider: `{0}`' -f $Report.providerKind))
    [void]$lines.Add(('Actual isolation verified: `{0}`' -f $Report.isolation.actualIsolationVerified))
    [void]$lines.Add(('Network isolation: `{0}`' -f $Report.isolation.networkIsolationVerificationStatus))
    [void]$lines.Add('')
    [void]$lines.Add('## Safety flags (must remain False)')
    [void]$lines.Add('')
    [void]$lines.Add('| Flag | Value |')
    [void]$lines.Add('|------|-------|')
    foreach ($flag in @(
            'realDismExecutionEnabled', 'modifyingCommandsInvoked', 'executionAuthorized', 'servicingAuthorized',
            'experimentalMutationEnabled', 'experimentalExecutionAuthorized',
            'labRealProvisioningEnabled', 'labHypervisorCommandsInvoked', 'layerDActivated',
            'hostDiscoveryRealHostCommandsInvoked', 'realHostInspectionEnabled', 'liveHostInspectionActivated'
        )) {
        [void]$lines.Add(('| `{0}` | {1} |' -f $flag, $Report.$flag))
    }
    [void]$lines.Add('')
    [void]$lines.Add('## Blockers')
    [void]$lines.Add('')
    foreach ($b in @($Report.blockers)) {
        [void]$lines.Add(('- {0}' -f $b))
    }
    [void]$lines.Add('')
    [void]$lines.Add('No live host-discovery commands, DISM mutation, VM provisioning, or Layer D activation was performed.')
    ($lines -join "`n") + "`n" | Set-Content -LiteralPath $mdPath -Encoding UTF8

    return [pscustomobject]@{ JsonPath = $jsonPath; MarkdownPath = $mdPath }
}
