# Milestone 6C — Read-only hypervisor and host lab discovery (simulation / mocks only).
# No real host enumeration, no Hyper-V mutation, Layer D remains disabled.

$script:XboxOSHostDiscoveryEngineVersion = '6.2.0-c'
$script:XboxOSHostIdentitySchemaVersion = 'host-identity-v1'
$script:XboxOSHostDiscoveryApprovalSchemaVersion = 'host-discovery-approval-v1'
$script:XboxOSHostDiscoveryScopeSchemaVersion = 'host-discovery-scope-v1'
$script:XboxOSHostDiscoveryAllowlistSchemaVersion = 'host-discovery-allowlist-v1'
$script:XboxOSHostDiscoveryHypervisorSchemaVersion = 'host-discovery-hypervisor-v1'
$script:XboxOSHostDiscoveryVmInventorySchemaVersion = 'host-discovery-vm-inventory-v1'
$script:XboxOSHostDiscoverySwitchSchemaVersion = 'host-discovery-switch-v1'
$script:XboxOSHostDiscoveryResourceSchemaVersion = 'host-discovery-resource-v1'
$script:XboxOSHostDiscoveryIsolationSchemaVersion = 'host-discovery-isolation-v1'
$script:XboxOSHostDiscoveryEvidenceSchemaVersion = 'host-discovery-evidence-v1'
$script:XboxOSHostDiscoveryReportSchemaVersion = 'host-discovery-report-v1'
$script:XboxOSHostDiscoveryTransactionSchemaVersion = 'host-discovery-transaction-v1'

$script:XboxOSHostDiscoveryTransactionStates = @(
    'DiscoveryPlanned',
    'ApprovalRequired',
    'HostDiscoveryBlocked',
    'DiscoverySimulated',
    'EvidenceIncomplete',
    'DiscoveryFailed',
    'RecoveryRequired',
    # Named only so fail-closed tests can assert they are unreachable:
    'RealHostInspection',
    'LabProvisioning',
    'WritableExecution'
)

$script:XboxOSHostDiscoveryTransactionTransitions = @{
    'DiscoveryPlanned'       = @('ApprovalRequired', 'HostDiscoveryBlocked', 'DiscoveryFailed')
    'ApprovalRequired'       = @('DiscoverySimulated', 'HostDiscoveryBlocked', 'DiscoveryFailed')
    'DiscoverySimulated'     = @('EvidenceIncomplete', 'HostDiscoveryBlocked', 'DiscoveryFailed', 'RecoveryRequired')
    'EvidenceIncomplete'     = @('HostDiscoveryBlocked', 'DiscoveryFailed', 'RecoveryRequired')
    'HostDiscoveryBlocked'   = @('RecoveryRequired', 'DiscoveryFailed')
    'DiscoveryFailed'        = @('RecoveryRequired')
    'RecoveryRequired'       = @()
    'RealHostInspection'     = @()
    'LabProvisioning'        = @()
    'WritableExecution'      = @()
}

$script:XboxOSHostDiscoveryUsedNonces = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:XboxOSHostDiscoveryRealHostCommandsInvoked = $false

function Get-XboxOSHostDiscoveryEngineVersion { return $script:XboxOSHostDiscoveryEngineVersion }
function Get-XboxOSHostIdentitySchemaVersion { return $script:XboxOSHostIdentitySchemaVersion }
function Get-XboxOSHostDiscoveryApprovalSchemaVersion { return $script:XboxOSHostDiscoveryApprovalSchemaVersion }
function Get-XboxOSHostDiscoveryScopeSchemaVersion { return $script:XboxOSHostDiscoveryScopeSchemaVersion }
function Get-XboxOSHostDiscoveryAllowlistSchemaVersion { return $script:XboxOSHostDiscoveryAllowlistSchemaVersion }
function Get-XboxOSHostDiscoveryHypervisorSchemaVersion { return $script:XboxOSHostDiscoveryHypervisorSchemaVersion }
function Get-XboxOSHostDiscoveryVmInventorySchemaVersion { return $script:XboxOSHostDiscoveryVmInventorySchemaVersion }
function Get-XboxOSHostDiscoverySwitchSchemaVersion { return $script:XboxOSHostDiscoverySwitchSchemaVersion }
function Get-XboxOSHostDiscoveryResourceSchemaVersion { return $script:XboxOSHostDiscoveryResourceSchemaVersion }
function Get-XboxOSHostDiscoveryIsolationSchemaVersion { return $script:XboxOSHostDiscoveryIsolationSchemaVersion }
function Get-XboxOSHostDiscoveryEvidenceSchemaVersion { return $script:XboxOSHostDiscoveryEvidenceSchemaVersion }
function Get-XboxOSHostDiscoveryReportSchemaVersion { return $script:XboxOSHostDiscoveryReportSchemaVersion }
function Get-XboxOSHostDiscoveryTransactionSchemaVersion { return $script:XboxOSHostDiscoveryTransactionSchemaVersion }

function Get-XboxOSHostDiscoveryRealHostCommandsInvoked { return [bool]$script:XboxOSHostDiscoveryRealHostCommandsInvoked }
function Reset-XboxOSHostDiscoveryNonceRegistry {
    [CmdletBinding()]
    param()
    $script:XboxOSHostDiscoveryUsedNonces.Clear()
}

function Assert-XboxOSHostDiscoverySafetyInvariants {
    [CmdletBinding()]
    param([object]$Report = $null)

    Assert-XboxOSExperimentSafetyInvariants -Report $Report
    Assert-XboxOSIsolatedLabSafetyInvariants -Report $Report
    if (Get-XboxOSHostDiscoveryRealHostCommandsInvoked) {
        throw 'Safety invariant violated: hostDiscoveryRealHostCommandsInvoked must be False in Milestone 6C implementation/tests.'
    }
    if ($null -eq $Report) { return }
    foreach ($flag in @(
            'labRealProvisioningEnabled', 'labHypervisorCommandsInvoked', 'layerDActivated',
            'hostDiscoveryRealHostCommandsInvoked', 'realHostInspectionEnabled'
        )) {
        if ($Report.PSObject.Properties[$flag] -and $Report.$flag) {
            throw ("Safety invariant violated: {0} must be False." -f $flag)
        }
    }
}

function Import-XboxOSHostDiscoveryAllowlistCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Host discovery allowlist not found: $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$raw.schemaVersion -ne (Get-XboxOSHostDiscoveryAllowlistSchemaVersion)) {
        throw ("Host discovery allowlist schema mismatch: expected {0}, got {1}" -f (Get-XboxOSHostDiscoveryAllowlistSchemaVersion), $raw.schemaVersion)
    }
    return $raw
}

function New-XboxOSHostIdentity {
    [CmdletBinding()]
    param(
        [string]$HostLabel = 'fixture-host',
        [string]$WindowsEdition = 'Windows 11 Pro',
        [string]$BuildNumber = '26300.9457',
        [string]$Architecture = 'amd64',
        [switch]$Fixture
    )

    $sourceType = if ($Fixture) { 'FixtureDerived' } else { 'NotObserved' }
    return [pscustomobject]@{
        schemaVersion   = Get-XboxOSHostIdentitySchemaVersion
        hostLabel       = $HostLabel
        windowsEdition  = $WindowsEdition
        buildNumber     = $BuildNumber
        architecture    = $Architecture
        hostIdentityKey = Get-XboxOSUtf8Sha256Hex -Text ('{0}|{1}|{2}|{3}' -f $HostLabel, $WindowsEdition, $BuildNumber, $Architecture)
        sourceType      = $sourceType
        observedOnHost  = $false
    }
}

function New-XboxOSHostDiscoveryScope {
    [CmdletBinding()]
    param(
        [string[]]$Categories = @(
            'OsInformation', 'CpuVirtualization', 'HyperVManagementComponents', 'VmInventory',
            'VmSwitchInventory', 'NetworkAdapters', 'VhdMetadata', 'HostResources',
            'WorkspaceBoundaries', 'DismMountMetadata', 'LabCredentialPrerequisites'
        ),
        [string]$ProposedSwitchName = 'IsolatedSwitch',
        [string]$WorkspaceRoot = 'C:\XboxOS\Lab\Work'
    )

    return [pscustomobject]@{
        schemaVersion      = Get-XboxOSHostDiscoveryScopeSchemaVersion
        categories         = @($Categories | Sort-Object -Unique)
        proposedSwitchName = $ProposedSwitchName
        workspaceRoot      = $WorkspaceRoot
        readOnlyRequired   = $true
        realHostAllowed    = $false
        scopeDigest        = Get-XboxOSUtf8Sha256Hex -Text (ConvertTo-XboxOSCanonicalJson -Value ([ordered]@{
                    categories         = @($Categories | Sort-Object -Unique)
                    proposedSwitchName = $ProposedSwitchName
                    workspaceRoot      = $WorkspaceRoot
                    readOnlyRequired   = $true
                    realHostAllowed    = $false
                }))
    }
}

function New-XboxOSHostDiscoveryApprovalRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OperatorId,
        [Parameter(Mandatory)][object]$HostIdentity,
        [Parameter(Mandatory)][object]$DiscoveryScope,
        [Parameter(Mandatory)][string]$GitCommitSha,
        [Parameter(Mandatory)][string[]]$ApprovedCategories,
        [datetime]$IssuedUtc = [datetime]::UtcNow,
        [datetime]$ExpiresUtc = [datetime]::UtcNow.AddHours(8),
        [string]$Nonce = $null,
        [switch]$ReadOnlyAcknowledged,
        [switch]$ClaimReuseM6aConsent,
        [switch]$ClaimReuseM6bTrustPolicy,
        [switch]$ClaimLayerD
    )

    if ($ClaimReuseM6aConsent -or $ClaimReuseM6bTrustPolicy -or $ClaimLayerD) {
        throw 'HostDiscovery approval must not reuse M6A consent, M6B trust-policy validation, or Layer D approval.'
    }
    if (-not $ReadOnlyAcknowledged) {
        throw 'HostDiscovery approval requires explicit read-only acknowledgment.'
    }
    if ([string]::IsNullOrWhiteSpace($OperatorId)) { throw 'OperatorId is required.' }
    if ([string]::IsNullOrWhiteSpace($GitCommitSha) -or $GitCommitSha -eq 'Unknown') {
        throw 'GitCommitSha is required for HostDiscovery approval binding.'
    }
    if ($ExpiresUtc -le $IssuedUtc) { throw 'ExpiresUtc must be after IssuedUtc.' }
    if (-not $Nonce) { $Nonce = [guid]::NewGuid().ToString('N') }
    if (-not $script:XboxOSHostDiscoveryUsedNonces.Add($Nonce)) {
        throw ("HostDiscovery approval nonce replay detected: {0}" -f $Nonce)
    }

    $approvedSorted = @($ApprovedCategories | Sort-Object -Unique)
    foreach ($c in $approvedSorted) {
        if ($DiscoveryScope.categories -notcontains $c) {
            throw ("Approved category '{0}' is outside discovery scope." -f $c)
        }
    }

    $binding = [ordered]@{
        layer                = 'HostDiscovery'
        operatorId           = $OperatorId
        hostIdentityKey      = [string]$HostIdentity.hostIdentityKey
        scopeDigest          = [string]$DiscoveryScope.scopeDigest
        gitCommitSha         = $GitCommitSha
        approvedCategories   = $approvedSorted
        readOnlyAcknowledged = $true
        nonce                = $Nonce
        issuedUtc            = $IssuedUtc.ToUniversalTime().ToString('o')
        expiresUtc           = $ExpiresUtc.ToUniversalTime().ToString('o')
    }
    $bindingHash = Get-XboxOSUtf8Sha256Hex -Text (ConvertTo-XboxOSCanonicalJson -Value $binding)

    return [pscustomobject]@{
        schemaVersion          = Get-XboxOSHostDiscoveryApprovalSchemaVersion
        layer                  = 'HostDiscovery'
        operatorId             = $OperatorId
        hostIdentityKey        = [string]$HostIdentity.hostIdentityKey
        scopeDigest            = [string]$DiscoveryScope.scopeDigest
        gitCommitSha           = $GitCommitSha
        approvedCategories     = $approvedSorted
        readOnlyAcknowledged   = $true
        nonce                  = $Nonce
        issuedUtc              = $IssuedUtc
        expiresUtc             = $ExpiresUtc
        bindingHash            = $bindingHash
        reusesM6aConsent       = $false
        reusesM6bTrustPolicy   = $false
        activatesLayerD        = $false
        grantsRealHostCommands = $false
        grantsProvisioning     = $false
    }
}

function Test-XboxOSHostDiscoveryApprovalRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Record,
        [Parameter(Mandatory)][object]$HostIdentity,
        [Parameter(Mandatory)][object]$DiscoveryScope,
        [Parameter(Mandatory)][string]$ExpectedGitCommitSha,
        [datetime]$AsOfUtc = [datetime]::UtcNow,
        [switch]$ReplayNonce
    )

    $errors = New-Object System.Collections.Generic.List[string]
    if ([string]$Record.layer -ne 'HostDiscovery') {
        [void]$errors.Add('Approval layer must be HostDiscovery.')
    }
    if ([string]$Record.hostIdentityKey -ne [string]$HostIdentity.hostIdentityKey) {
        [void]$errors.Add('Host identity mismatch on HostDiscovery approval.')
    }
    if ([string]$Record.scopeDigest -ne [string]$DiscoveryScope.scopeDigest) {
        [void]$errors.Add('Discovery scope mismatch on HostDiscovery approval.')
    }
    if ([string]$Record.gitCommitSha -ne $ExpectedGitCommitSha) {
        [void]$errors.Add('Git commit SHA mismatch on HostDiscovery approval.')
    }
    if ($Record.ExpiresUtc.ToUniversalTime() -le $AsOfUtc.ToUniversalTime()) {
        [void]$errors.Add('HostDiscovery approval is expired.')
    }
    if (-not [bool]$Record.readOnlyAcknowledged) {
        [void]$errors.Add('Read-only acknowledgment missing.')
    }
    if ([bool]$Record.activatesLayerD -or [bool]$Record.grantsRealHostCommands -or [bool]$Record.grantsProvisioning) {
        [void]$errors.Add('HostDiscovery approval must not grant Layer D, real-host commands, or provisioning.')
    }
    if ($ReplayNonce) {
        [void]$errors.Add('HostDiscovery approval nonce replay detected.')
    }
    elseif (-not $script:XboxOSHostDiscoveryUsedNonces.Contains([string]$Record.nonce)) {
        # Record should already have registered nonce at creation; absence indicates substitution.
        [void]$errors.Add('HostDiscovery approval nonce is not registered (possible evidence substitution).')
    }

    $recomputed = Get-XboxOSUtf8Sha256Hex -Text (ConvertTo-XboxOSCanonicalJson -Value ([ordered]@{
                layer                = 'HostDiscovery'
                operatorId           = [string]$Record.operatorId
                hostIdentityKey      = [string]$Record.hostIdentityKey
                scopeDigest          = [string]$Record.scopeDigest
                gitCommitSha         = [string]$Record.gitCommitSha
                approvedCategories   = @($Record.approvedCategories | Sort-Object)
                readOnlyAcknowledged = $true
                nonce                = [string]$Record.nonce
                issuedUtc            = ([datetime]$Record.issuedUtc).ToUniversalTime().ToString('o')
                expiresUtc           = ([datetime]$Record.expiresUtc).ToUniversalTime().ToString('o')
            }))
    if ([string]$Record.bindingHash -ne $recomputed) {
        [void]$errors.Add('HostDiscovery approval binding hash mismatch (altered or incomplete evidence).')
    }

    return [pscustomobject]@{
        valid  = [bool]($errors.Count -eq 0)
        errors = [string[]]@($errors.ToArray())
    }
}

function Test-XboxOSHostDiscoveryCommandAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Allowlist,
        [Parameter(Mandatory)][string]$OperationId,
        [string]$RawCommand = ''
    )

    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($pat in @($Allowlist.deniedPatterns)) {
        if ($OperationId -match [regex]::Escape([string]$pat) -or ($RawCommand -and $RawCommand -match [regex]::Escape([string]$pat))) {
            [void]$errors.Add(("Denied pattern matched: {0}" -f $pat))
        }
    }
    $op = @($Allowlist.allowedOperations | Where-Object { [string]$_.operationId -eq $OperationId } | Select-Object -First 1)
    if (-not $op) {
        [void]$errors.Add(("Operation '{0}' is not on the host-discovery allowlist." -f $OperationId))
    }
    elseif ([bool]$op.sideEffects) {
        [void]$errors.Add(("Operation '{0}' declares side effects and is forbidden." -f $OperationId))
    }

    return [pscustomobject]@{
        allowed     = [bool]($errors.Count -eq 0)
        operationId = $OperationId
        errors      = [string[]]@($errors.ToArray())
        sideEffects = $false
    }
}

function New-XboxOSMockHostDiscoveryAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Allowlist,
        [ValidateSet('MockedSimulation')]
        [string]$Mode = 'MockedSimulation',
        [hashtable]$FixtureInventory = $null,
        [switch]$SimulateInsufficientPrivileges,
        [switch]$SimulateHyperVUnavailable,
        [switch]$SimulatePermissionFailure
    )

    if ($null -eq $FixtureInventory) {
        $FixtureInventory = @{
            os                  = @{ edition = 'Windows 11 Pro'; build = '26300.9457'; architecture = 'amd64' }
            cpu                 = @{ virtualizationFirmwareEnabled = $true; logicalProcessors = 16 }
            hyperVManagement    = @{ moduleAvailable = $false; getVmAvailable = $false }
            vms                 = @()
            switches            = @()
            adapters            = @(@{ name = 'Ethernet'; ifIndex = 12; redactedId = 'adapter-****-12' })
            vhds                = @()
            resources           = @{ cpuCount = 16; memoryGiB = 64; freeDiskGiB = 400 }
            dismMounts          = @()
            credentialPrereqs   = @{ labKeyCustodyDocumented = $true; productionTrustPresent = $false }
            switchNamedIsolated = $null
        }
    }

    return [pscustomobject]@{
        mode                              = $Mode
        allowlist                         = $Allowlist
        fixtureInventory                  = $FixtureInventory
        simulateInsufficientPrivileges    = [bool]$SimulateInsufficientPrivileges
        simulateHyperVUnavailable         = [bool]$SimulateHyperVUnavailable
        simulatePermissionFailure         = [bool]$SimulatePermissionFailure
        realHostCommandsInvoked           = $false
        automaticRealHostSwitchEnabled    = $false
        notes                             = @(
            'MockedSimulation adapter only.'
            'No automatic switch to real-host execution.'
            'No arbitrary PowerShell/shell executor is exposed.'
        )
    }
}

function Invoke-XboxOSHostDiscoveryAdapterOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Adapter,
        [Parameter(Mandatory)][string]$OperationId
    )

    if ([string]$Adapter.mode -ne 'MockedSimulation') {
        throw 'Only MockedSimulation adapter mode is enabled in Milestone 6C.'
    }
    if ([bool]$Adapter.automaticRealHostSwitchEnabled) {
        throw 'Automatic real-host switch is forbidden.'
    }

    $gate = Test-XboxOSHostDiscoveryCommandAllowed -Allowlist $Adapter.allowlist -OperationId $OperationId
    if (-not $gate.allowed) {
        throw ("Non-allowlisted or denied discovery operation: {0}" -f ($gate.errors -join '; '))
    }

    if ($Adapter.simulatePermissionFailure -or $Adapter.simulateInsufficientPrivileges) {
        return [pscustomobject]@{
            operationId   = $OperationId
            status        = 'Unavailable'
            reason        = 'Insufficient privileges (simulated).'
            observationSource = 'MockFixture'
            data          = $null
            realHostInvoked = $false
        }
    }

    $inv = $Adapter.fixtureInventory
    $hyperVUnavailable = [bool]$Adapter.simulateHyperVUnavailable -or (-not [bool]$inv.hyperVManagement.moduleAvailable)

    $data = $null
    $status = 'ObservedFixture'
    switch ($OperationId) {
        'Get-OsInfo' { $data = $inv.os }
        'Get-CpuVirtualization' { $data = $inv.cpu }
        'Get-HyperVManagementPresence' {
            if ($hyperVUnavailable) {
                $status = 'Unavailable'
                $data = @{ moduleAvailable = $false; getVmAvailable = $false }
            }
            else { $data = $inv.hyperVManagement }
        }
        'Get-VmInventory' {
            if ($hyperVUnavailable) {
                $status = 'Unavailable'
                # Never assume empty inventory when tools are unavailable.
                $data = @{ availability = 'Unavailable'; vms = $null; inventsEmptyInventory = $false }
            }
            else {
                $data = @{ availability = 'Available'; vms = @($inv.vms) }
            }
        }
        'Get-VmSwitchInventory' {
            if ($hyperVUnavailable) {
                $status = 'Unavailable'
                $data = @{ availability = 'Unavailable'; switches = $null; inventsEmptyInventory = $false }
            }
            else {
                $data = @{ availability = 'Available'; switches = @($inv.switches) }
            }
        }
        'Get-NetworkAdapters' { $data = @{ adapters = @($inv.adapters) } }
        'Get-VhdMetadata' { $data = @{ vhds = @($inv.vhds) } }
        'Get-HostResources' { $data = $inv.resources }
        'Get-WorkspaceBoundaries' { $data = @{ evaluated = $true } }
        'Get-DismMountMetadata' { $data = @{ mounts = @($inv.dismMounts) } }
        'Get-LabCredentialPrerequisites' { $data = $inv.credentialPrereqs }
        default { throw ("Unhandled allowlisted operation '{0}'." -f $OperationId) }
    }

    return [pscustomobject]@{
        operationId       = $OperationId
        status            = $status
        reason            = $null
        observationSource = 'MockFixture'
        data              = $data
        realHostInvoked   = $false
    }
}

function Test-XboxOSHostDiscoveryIsolationObservations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProposedSwitchName,
        [object]$ObservedSwitches = $null,
        [object]$ObservedVms = $null,
        [string]$SwitchInventoryAvailability = 'Unavailable',
        [switch]$ProductionBridgeObserved,
        [switch]$HostAdminSharesObserved,
        [switch]$FirewallEvidenceAvailable,
        [switch]$ClaimProductionVerificationFromFixture,
        [ValidateSet('MockFixture', 'IndependentHostObservation')]
        [string]$ObservationSource = 'MockFixture'
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]
    $criteria = New-Object System.Collections.ArrayList

    if ($ClaimProductionVerificationFromFixture -or $ObservationSource -eq 'MockFixture') {
        [void]$notes.Add('Mock/fixture observations cannot produce production isolation verification.')
    }

    $switchExistsState = 'Unavailable'
    $observedType = $null
    $switchMatch = $null
    if ($SwitchInventoryAvailability -eq 'Unavailable' -or $null -eq $ObservedSwitches) {
        $switchExistsState = 'Unavailable'
        [void]$notes.Add('Switch inventory unavailable; existence of proposed switch is Unverified/Unavailable, not assumed false.')
    }
    else {
        $switchMatch = $ObservedSwitches | Where-Object { [string]$_.name -eq $ProposedSwitchName } | Select-Object -First 1
        if ($null -ne $switchMatch) {
            $switchExistsState = 'Verified'
            $observedType = [string]$switchMatch.type
        }
        else {
            $switchExistsState = 'Unverified'
        }
    }
    [void]$criteria.Add([pscustomobject]@{ id = 'switch-exists'; state = $switchExistsState; detail = $ProposedSwitchName })

    $typeState = 'Unverified'
    if ($observedType) {
        if ($observedType -match '(?i)external|bridged') {
            $typeState = 'Unsafe'
        }
        elseif ($observedType -match '(?i)private|internal') {
            # Declared Private/Internal is not automatic full isolation.
            $typeState = 'Unverified'
            [void]$notes.Add('Observed Private/Internal switch type is necessary but not sufficient for full isolation verification.')
        }
        else {
            $typeState = 'Unverified'
        }
    }
    elseif ($ProposedSwitchName -eq 'IsolatedSwitch') {
        $typeState = 'Unverified'
        [void]$notes.Add('A switch named IsolatedSwitch is not proof of isolation.')
    }
    [void]$criteria.Add([pscustomobject]@{ id = 'switch-type'; state = $typeState; detail = $observedType })

    $bridgeState = if ($ProductionBridgeObserved) { 'Unsafe' } else { 'Unverified' }
    [void]$criteria.Add([pscustomobject]@{ id = 'production-bridge'; state = $bridgeState; detail = $null })

    $shareState = if ($HostAdminSharesObserved) { 'Unsafe' } else { 'Unverified' }
    [void]$criteria.Add([pscustomobject]@{ id = 'host-admin-shares'; state = $shareState; detail = $null })

    $firewallState = if ($FirewallEvidenceAvailable) { 'Unverified' } else { 'Unavailable' }
    [void]$criteria.Add([pscustomobject]@{ id = 'firewall-evidence'; state = $firewallState; detail = $null })

    $sharedVmState = 'Unverified'
    if ($null -eq $ObservedVms -or $SwitchInventoryAvailability -eq 'Unavailable') {
        $sharedVmState = 'Unavailable'
    }
    elseif (@($ObservedVms | Where-Object { [bool]$_.productionTagged -or [bool]$_.sharesLabSwitchWithProduction }).Count -gt 0) {
        $sharedVmState = 'Unsafe'
    }
    [void]$criteria.Add([pscustomobject]@{ id = 'production-vm-sharing'; state = $sharedVmState; detail = $null })

    $mandatoryIds = @('switch-exists', 'switch-type', 'production-bridge', 'host-admin-shares', 'firewall-evidence', 'production-vm-sharing')
    $allVerified = $true
    foreach ($c in @($criteria)) {
        if ($mandatoryIds -contains $c.id -and $c.state -ne 'Verified') { $allVerified = $false }
        if ($c.state -eq 'Unsafe') { [void]$errors.Add(("Isolation criterion unsafe: {0}" -f $c.id)) }
    }

    # Fixture/mock source can never set ActualIsolationVerified=True
    $actualVerified = $false
    if ($allVerified -and $ObservationSource -eq 'IndependentHostObservation' -and -not $ClaimProductionVerificationFromFixture) {
        $actualVerified = $true
    }
    if ($ObservationSource -eq 'MockFixture') {
        $actualVerified = $false
    }

    $completeness = if ($SwitchInventoryAvailability -eq 'Unavailable') { 'Incomplete' } else { 'Partial' }
    if ($actualVerified) { $completeness = 'Complete' }

    return [pscustomobject]@{
        schemaVersion              = Get-XboxOSHostDiscoveryIsolationSchemaVersion
        proposedSwitchName         = $ProposedSwitchName
        criteria                   = [object[]]@($criteria.ToArray())
        observationSource          = $ObservationSource
        observationCompleteness    = $completeness
        actualIsolationVerified    = $actualVerified
        networkIsolationVerificationStatus = $(if ($actualVerified) { 'NetworkIsolationVerified' } else { 'NetworkIsolationNotVerified' })
        errors                     = [string[]]@($errors.ToArray())
        notes                      = [string[]]@($notes.ToArray())
        inventsVerificationFromName = $false
    }
}

function Assert-XboxOSHostDiscoveryTransactionTransition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )

    if ($script:XboxOSHostDiscoveryTransactionStates -notcontains $From) {
        throw ("Unknown host discovery state '{0}'." -f $From)
    }
    if ($script:XboxOSHostDiscoveryTransactionStates -notcontains $To) {
        throw ("Unknown host discovery state '{0}'." -f $To)
    }
    foreach ($blocked in @('RealHostInspection', 'LabProvisioning', 'WritableExecution')) {
        if ($To -eq $blocked) {
            throw ("Transition to '{0}' is not reachable in Milestone 6C." -f $To)
        }
    }
    $allowed = @($script:XboxOSHostDiscoveryTransactionTransitions[$From])
    if ($allowed -notcontains $To) {
        throw ("Invalid host discovery transaction transition: {0} -> {1}." -f $From, $To)
    }
    return $true
}

function New-XboxOSHostDiscoveryTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DiscoveryId,
        [string]$InitialState = 'DiscoveryPlanned'
    )

    if ($script:XboxOSHostDiscoveryTransactionStates -notcontains $InitialState) {
        throw ("Unknown initial host discovery state '{0}'." -f $InitialState)
    }
    return [pscustomobject]@{
        schemaVersion                        = Get-XboxOSHostDiscoveryTransactionSchemaVersion
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
    }
}

function Set-XboxOSHostDiscoveryTransactionState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Transaction,
        [Parameter(Mandatory)][string]$To,
        [string]$Note = ''
    )

    Assert-XboxOSHostDiscoveryTransactionTransition -From ([string]$Transaction.state) -To $To
    $Transaction.state = $To
    $Transaction.history = @($Transaction.history) + @([pscustomobject]@{ utc = [datetime]::UtcNow; state = $To; note = $Note })
    Assert-XboxOSHostDiscoverySafetyInvariants -Report $Transaction
    return $Transaction
}

function New-XboxOSHostDiscoveryEvidenceManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$HostIdentity,
        [Parameter(Mandatory)][object]$DiscoveryScope,
        [Parameter(Mandatory)][object]$Transaction,
        [Parameter(Mandatory)][object]$IsolationResult,
        [object]$Approval = $null,
        [object]$Git = $null,
        [object[]]$OperationResults = @(),
        [string]$SourceIsoSha256 = '',
        [string]$M5ReadinessDigest = '',
        [string]$M6aExperimentHash = '',
        [string]$M6bLabDecision = '',
        [ValidateSet('FixtureDerived', 'IndependentHostObservation', 'NotObserved')]
        [string]$EvidenceSourceType = 'FixtureDerived'
    )

    $redactedOps = @(
        $OperationResults | ForEach-Object {
            [pscustomobject]@{
                operationId       = [string]$_.operationId
                status            = [string]$_.status
                observationSource = [string]$_.observationSource
            }
        }
    )

    return [pscustomobject]@{
        schemaVersion            = Get-XboxOSHostDiscoveryEvidenceSchemaVersion
        reportNamespace          = 'm6c'
        gitCommitSha             = $(if ($Git -and $Git.PSObject.Properties['gitCommitSha']) { [string]$Git.gitCommitSha } else { 'Unknown' })
        hostIdentifier           = [string]$HostIdentity.hostIdentityKey
        hostLabelRedacted        = ('host-{0}' -f [string]$HostIdentity.hostIdentityKey.Substring(0, 12))
        approvedScopeDigest      = [string]$DiscoveryScope.scopeDigest
        timestampUtc             = [datetime]::UtcNow.ToUniversalTime().ToString('o')
        commandClassifications   = $redactedOps
        sourceType               = $EvidenceSourceType
        observationSource        = $(if ($EvidenceSourceType -eq 'IndependentHostObservation') { 'IndependentHostObservation' } else { 'MockFixture' })
        evidenceHash             = Get-XboxOSUtf8Sha256Hex -Text (ConvertTo-XboxOSCanonicalJson -Value ([ordered]@{
                    host   = [string]$HostIdentity.hostIdentityKey
                    scope  = [string]$DiscoveryScope.scopeDigest
                    ops    = $redactedOps
                    state  = [string]$Transaction.state
                }))
        warnings                 = @(
            'Fixture/mock evidence is not independently observed host evidence.'
            'M1-M6B baselines must not be overwritten.'
        )
        missingInformation       = @(
            if ($IsolationResult.observationCompleteness -ne 'Complete') { 'Isolation observation incomplete' }
            if (-not $Approval) { 'HostDiscovery approval absent' }
        )
        approvalBindingHash      = $(if ($Approval) { [string]$Approval.bindingHash } else { $null })
        sourceIsoSha256          = $SourceIsoSha256
        m5ReadinessDigest        = $M5ReadinessDigest
        m6aExperimentHash        = $M6aExperimentHash
        m6bLabDecision           = $M6bLabDecision
        actualIsolationVerified  = [bool]$IsolationResult.actualIsolationVerified
        preservesPriorBaselines  = $true
        layerDActivated          = $false
        realHostCommandsInvoked  = $false
    }
}

function Invoke-XboxOSHostLabDiscoverySimulate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Allowlist,
        [object]$HostIdentity = $null,
        [object]$DiscoveryScope = $null,
        [object]$Approval = $null,
        [object]$Adapter = $null,
        [string]$RepoRoot = $null,
        [string]$ExpectedGitCommitSha = '',
        [string]$ProposedSwitchName = 'IsolatedSwitch',
        [string]$WorkspaceRoot = 'C:\XboxOS\Lab\Work',
        [string]$SourceIsoSha256 = 'BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650',
        [string]$M5ReadinessDigest = '',
        [string]$M6aExperimentHash = '',
        [string]$M6bLabDecision = 'LabProvisioningBlocked',
        [hashtable]$FixtureInventory = $null,
        [switch]$SimulateInsufficientPrivileges,
        [switch]$SimulateHyperVUnavailable,
        [switch]$ClaimFixtureProductionVerification,
        [ValidateSet(
            '',
            'ExpiredApproval',
            'ReplayApproval',
            'WrongHostIdentity',
            'WrongGitSha',
            'WrongScope',
            'NonAllowlistedCommand',
            'EvidenceSubstitution',
            'WorkspaceEscape'
        )]
        [string]$InjectFailure = ''
    )

    Assert-XboxOSHostDiscoverySafetyInvariants

    if (-not $HostIdentity) {
        $HostIdentity = New-XboxOSHostIdentity -Fixture
    }
    if (-not $DiscoveryScope) {
        $DiscoveryScope = New-XboxOSHostDiscoveryScope -ProposedSwitchName $ProposedSwitchName -WorkspaceRoot $WorkspaceRoot
    }
    if (-not $Adapter) {
        $Adapter = New-XboxOSMockHostDiscoveryAdapter `
            -Allowlist $Allowlist `
            -FixtureInventory $FixtureInventory `
            -SimulateInsufficientPrivileges:$SimulateInsufficientPrivileges `
            -SimulateHyperVUnavailable:$SimulateHyperVUnavailable
    }

    $git = Get-XboxOSReportTraceability -RepoRoot $RepoRoot
    if (-not $ExpectedGitCommitSha) {
        $ExpectedGitCommitSha = if ($git.PSObject.Properties['gitCommitSha']) { [string]$git.gitCommitSha } else { 'fixture-git-sha' }
        if ([string]::IsNullOrWhiteSpace($ExpectedGitCommitSha) -or $ExpectedGitCommitSha -eq 'Unknown') {
            $ExpectedGitCommitSha = 'fixture-git-sha-for-simulation'
        }
    }

    $discoveryId = ('disc-{0}' -f [datetime]::UtcNow.ToString('yyyyMMddHHmmssfff'))
    $tx = New-XboxOSHostDiscoveryTransaction -DiscoveryId $discoveryId
    $null = Set-XboxOSHostDiscoveryTransactionState -Transaction $tx -To ApprovalRequired -Note 'HostDiscovery approval required'

    $blockers = New-Object System.Collections.Generic.List[string]
    $decision = 'HostDiscoveryBlocked'

    # Workspace boundary reuse
    $wsShape = Test-XboxOSExperimentPathIsUnsafeShape -Path $DiscoveryScope.workspaceRoot
    if (-not $wsShape.valid) {
        foreach ($e in @($wsShape.errors)) { [void]$blockers.Add(("Workspace: {0}" -f $e)) }
    }
    elseif (Test-XboxOSCloudSynchronizedPath -Path $wsShape.canonical) {
        [void]$blockers.Add('Workspace must be outside OneDrive/cloud-sync locations.')
    }
    if ($InjectFailure -eq 'WorkspaceEscape') {
        [void]$blockers.Add('Workspace path escape simulated.')
    }

    $approvalValid = $false
    if ($null -eq $Approval) {
        [void]$blockers.Add('HostDiscovery approval missing; default decision is HostDiscoveryBlocked.')
    }
    else {
        $hostForCheck = $HostIdentity
        $scopeForCheck = $DiscoveryScope
        $gitForCheck = $ExpectedGitCommitSha
        if ($InjectFailure -eq 'WrongHostIdentity') {
            $hostForCheck = New-XboxOSHostIdentity -HostLabel 'other-host' -Fixture
        }
        if ($InjectFailure -eq 'WrongScope') {
            $scopeForCheck = New-XboxOSHostDiscoveryScope -ProposedSwitchName 'OtherSwitch' -WorkspaceRoot $WorkspaceRoot
        }
        if ($InjectFailure -eq 'WrongGitSha') {
            $gitForCheck = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
        }
        $asOf = [datetime]::UtcNow
        if ($InjectFailure -eq 'ExpiredApproval') {
            $asOf = ([datetime]$Approval.expiresUtc).AddMinutes(1)
        }
        $approvalCheck = Test-XboxOSHostDiscoveryApprovalRecord `
            -Record $Approval `
            -HostIdentity $hostForCheck `
            -DiscoveryScope $scopeForCheck `
            -ExpectedGitCommitSha $gitForCheck `
            -AsOfUtc $asOf `
            -ReplayNonce:($InjectFailure -eq 'ReplayApproval')
        if (-not $approvalCheck.valid) {
            foreach ($e in @($approvalCheck.errors)) { [void]$blockers.Add($e) }
        }
        else {
            $approvalValid = $true
        }
    }

    $operationResults = New-Object System.Collections.Generic.List[object]
    if ($InjectFailure -eq 'NonAllowlistedCommand') {
        try {
            $null = Invoke-XboxOSHostDiscoveryAdapterOperation -Adapter $Adapter -OperationId 'New-VM'
            [void]$blockers.Add('Non-allowlisted command unexpectedly succeeded.')
        }
        catch {
            [void]$blockers.Add(("Non-allowlisted command rejected: {0}" -f $_.Exception.Message))
        }
    }

    $opsToRun = @(
        'Get-OsInfo', 'Get-CpuVirtualization', 'Get-HyperVManagementPresence', 'Get-VmInventory',
        'Get-VmSwitchInventory', 'Get-NetworkAdapters', 'Get-VhdMetadata', 'Get-HostResources',
        'Get-WorkspaceBoundaries', 'Get-DismMountMetadata', 'Get-LabCredentialPrerequisites'
    )
    foreach ($opId in $opsToRun) {
        if ($Approval -and $approvalValid -and @($Approval.approvedCategories).Count -gt 0) {
            $cat = @($Allowlist.allowedOperations | Where-Object operationId -eq $opId | Select-Object -First 1).category
            if ($cat -and @($Approval.approvedCategories) -notcontains $cat) {
                [void]$operationResults.Add([pscustomobject]@{
                        operationId = $opId; status = 'Skipped'; observationSource = 'MockFixture'; data = $null; realHostInvoked = $false; reason = 'Category not approved'
                    })
                continue
            }
        }
        [void]$operationResults.Add((Invoke-XboxOSHostDiscoveryAdapterOperation -Adapter $Adapter -OperationId $opId))
    }

    $vmResult = @($operationResults | Where-Object operationId -eq 'Get-VmInventory' | Select-Object -First 1)
    $swResult = @($operationResults | Where-Object operationId -eq 'Get-VmSwitchInventory' | Select-Object -First 1)
    $vmAvailability = if ($vmResult) { if ($vmResult.status -eq 'Unavailable') { 'Unavailable' } else { 'Available' } } else { 'Unavailable' }
    $swAvailability = if ($swResult) { if ($swResult.status -eq 'Unavailable') { 'Unavailable' } else { 'Available' } } else { 'Unavailable' }

    $observedSwitches = $null
    if ($swAvailability -eq 'Available' -and $swResult.data) { $observedSwitches = @($swResult.data.switches) }
    $observedVms = $null
    if ($vmAvailability -eq 'Available' -and $vmResult.data) { $observedVms = @($vmResult.data.vms) }

    # Name spoofing: topology name alone never verifies
    $isolation = Test-XboxOSHostDiscoveryIsolationObservations `
        -ProposedSwitchName $DiscoveryScope.proposedSwitchName `
        -ObservedSwitches $observedSwitches `
        -ObservedVms $observedVms `
        -SwitchInventoryAvailability $swAvailability `
        -ClaimProductionVerificationFromFixture:$ClaimFixtureProductionVerification `
        -ObservationSource MockFixture

    if ($isolation.actualIsolationVerified) {
        [void]$blockers.Add('Safety violation: mock-derived observations must not set ActualIsolationVerified=True.')
        $isolation.actualIsolationVerified = $false
    }

    if ($InjectFailure -eq 'EvidenceSubstitution') {
        [void]$blockers.Add('Evidence substitution detected.')
    }

    # Inventory records
    $hypervisor = [pscustomobject]@{
        schemaVersion     = Get-XboxOSHostDiscoveryHypervisorSchemaVersion
        managementStatus  = $(if ($swAvailability -eq 'Unavailable') { 'Unavailable' } else { 'Available' })
        featureState      = 'Unknown'
        assumesInstalled  = $false
    }
    $vmInventory = [pscustomobject]@{
        schemaVersion = Get-XboxOSHostDiscoveryVmInventorySchemaVersion
        availability  = $vmAvailability
        vms           = $observedVms
        notes         = @(
            if ($vmAvailability -eq 'Unavailable') { 'Get-VM unavailable; inventory is Unavailable/Unknown, not an empty host.' }
        )
    }
    $switchInventory = [pscustomobject]@{
        schemaVersion = Get-XboxOSHostDiscoverySwitchSchemaVersion
        availability  = $swAvailability
        switches      = $observedSwitches
    }
    $resources = [pscustomobject]@{
        schemaVersion = Get-XboxOSHostDiscoveryResourceSchemaVersion
        data          = $(@($operationResults | Where-Object operationId -eq 'Get-HostResources' | Select-Object -First 1).data)
    }

    if ($approvalValid -and $blockers.Count -eq 0) {
        $null = Set-XboxOSHostDiscoveryTransactionState -Transaction $tx -To DiscoverySimulated -Note 'Mocked discovery simulation'
        if ($isolation.observationCompleteness -ne 'Complete') {
            $null = Set-XboxOSHostDiscoveryTransactionState -Transaction $tx -To EvidenceIncomplete -Note 'Isolation/host evidence incomplete'
        }
        # Always block real inspection / provisioning
        $null = Set-XboxOSHostDiscoveryTransactionState -Transaction $tx -To HostDiscoveryBlocked -Note 'Milestone 6C structurally blocks real-host inspection and provisioning'
        $decision = 'HostDiscoveryBlocked'
        [void]$blockers.Add('Milestone 6C final decision is HostDiscoveryBlocked; real-host inspection remains unauthorized without a future separately approved mechanism.')
    }
    else {
        $null = Set-XboxOSHostDiscoveryTransactionState -Transaction $tx -To HostDiscoveryBlocked -Note 'Approval or policy failed closed'
        if ($InjectFailure -in @('EvidenceSubstitution', 'ExpiredApproval', 'ReplayApproval', 'WrongHostIdentity', 'WrongGitSha', 'WrongScope', 'NonAllowlistedCommand', 'WorkspaceEscape')) {
            $null = Set-XboxOSHostDiscoveryTransactionState -Transaction $tx -To DiscoveryFailed -Note ("Injected failure: {0}" -f $InjectFailure)
            $null = Set-XboxOSHostDiscoveryTransactionState -Transaction $tx -To RecoveryRequired -Note 'RecoveryRequired after discovery failure'
            $decision = 'RecoveryRequired'
        }
    }

    $evidence = New-XboxOSHostDiscoveryEvidenceManifest `
        -HostIdentity $HostIdentity `
        -DiscoveryScope $DiscoveryScope `
        -Transaction $tx `
        -IsolationResult $isolation `
        -Approval $Approval `
        -Git $git `
        -OperationResults @($operationResults.ToArray()) `
        -SourceIsoSha256 $SourceIsoSha256 `
        -M5ReadinessDigest $M5ReadinessDigest `
        -M6aExperimentHash $M6aExperimentHash `
        -M6bLabDecision $M6bLabDecision `
        -EvidenceSourceType FixtureDerived

    $report = [pscustomobject]@{
        reportSchemaVersion                  = Get-XboxOSHostDiscoveryReportSchemaVersion
        engineVersion                        = Get-XboxOSHostDiscoveryEngineVersion
        decision                             = $decision
        transactionState                     = [string]$tx.state
        hostIdentity                         = $HostIdentity
        discoveryScope                       = $DiscoveryScope
        approval                             = $Approval
        approvalValid                        = $approvalValid
        adapterMode                          = [string]$Adapter.mode
        hypervisor                           = $hypervisor
        vmInventory                          = $vmInventory
        switchInventory                      = $switchInventory
        resources                            = $resources
        isolation                            = $isolation
        operationResults                     = [object[]]@($operationResults.ToArray())
        evidenceManifest                     = $evidence
        transaction                          = $tx
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
        generatedUtc                         = [datetime]::UtcNow
        notes                                = @(
            'Milestone 6C host discovery is MockedSimulation only in this implementation task.'
            'Default decision is HostDiscoveryBlocked.'
            'IsolatedSwitch name is not proof of isolation.'
            'Layer D and lab provisioning remain disabled.'
        )
    }

    Assert-XboxOSHostDiscoverySafetyInvariants -Report $report
    return $report
}

function Save-XboxOSHostLabDiscoveryReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Report,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$Stem = 'XboxOS11-host-lab-discovery-m6c',
        [string]$RepoRoot = $null
    )

    Assert-XboxOSHostDiscoverySafetyInvariants -Report $Report
    if ($OutputDirectory -match '(?i)OneDrive') {
        throw "Refusing to write host discovery reports under OneDrive: $OutputDirectory"
    }
    if ($RepoRoot) {
        $null = Assert-XboxOSServicingPathSafety -Path $OutputDirectory -RepoRoot $RepoRoot -Purpose 'host discovery reports'
    }
    $forbidden = @(
        'DISM-Compatibility-20261014-2',
        'XboxOS11-disposable-preflight-m4-live-readonly',
        'XboxOS11-servicing-readiness-m5',
        'XboxOS11-experiment-plan-m6a',
        'XboxOS11-isolated-lab-m6b',
        'XboxOS11-execution-safety-m3',
        'XboxOS11-servicing-plan'
    )
    foreach ($f in $forbidden) {
        if ($Stem -eq $f -or $Stem -like "$f*") {
            throw ("Refusing to overwrite Milestone 1-6B baseline stem: {0}" -f $Stem)
        }
    }

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $jsonPath = Join-Path $OutputDirectory ($Stem + '.json')
    $mdPath = Join-Path $OutputDirectory ($Stem + '.md')
    ($Report | ConvertTo-Json -Depth 14) | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('# XboxOS11 Milestone 6C — Host Lab Discovery (simulation)')
    [void]$lines.Add('')
    [void]$lines.Add(('Engine: `{0}`' -f $Report.engineVersion))
    [void]$lines.Add(('Decision: **{0}**' -f $Report.decision))
    [void]$lines.Add(('Transaction state: `{0}`' -f $Report.transactionState))
    [void]$lines.Add(('Adapter mode: `{0}`' -f $Report.adapterMode))
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
            'hostDiscoveryRealHostCommandsInvoked', 'realHostInspectionEnabled'
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
    [void]$lines.Add('No real host-discovery commands, hypervisor provisioning, or DISM mutation was performed.')
    ($lines -join "`n") + "`n" | Set-Content -LiteralPath $mdPath -Encoding UTF8

    return [pscustomobject]@{ JsonPath = $jsonPath; MarkdownPath = $mdPath }
}
