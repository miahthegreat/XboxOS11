# Milestone 6E - Controlled live read-only host discovery (Gate A implementation).
# Live observation requires a per-run activation built from: a trusted (non-test) signed HostDiscoveryReal
# approval, a clean verified Git revision matching the approval, a durable replay-store claim, an explicit
# operator acknowledgment for that exact run, and a non-CI session. CI exercises injected invokers only.
# No provisioning, networking mutation, DISM servicing, or Layer D is reachable from this file.

$script:XboxOSControlledLiveDiscoveryEngineVersion = '6.4.0-e'
$script:XboxOSControlledLiveReplayStoreSchemaVersion = 'host-discovery-replay-store-v1'
$script:XboxOSControlledLiveActivationSchemaVersion = 'host-discovery-live-activation-v1'
$script:XboxOSControlledLiveEvidenceSchemaVersion = 'host-discovery-live-evidence-v1'
$script:XboxOSControlledLiveReportSchemaVersion = 'host-discovery-live-report-v1'
$script:XboxOSControlledLiveTransactionSchemaVersion = 'host-discovery-live-transaction-v1'
$script:XboxOSControlledLiveDefaultReplayStorePath = 'C:\XboxOS\Lab\Auth\used-approvals.jsonl'
$script:XboxOSControlledLiveMaxApprovalLifetime = [timespan]::FromHours(4)
$script:XboxOSControlledLiveMaxClockSkew = [timespan]::FromMinutes(5)
$script:XboxOSControlledLiveGenesisHash = ('0' * 64)
$script:XboxOSControlledLiveRealHostCommandsInvoked = $false

$script:XboxOSControlledLiveTransactionStates = @(
    'LiveDiscoveryPlanned',
    'ApprovalRequired',
    'HostDiscoveryBlocked',
    'HostDiscoveryAuthorized',
    'ReadOnlyInspectionRunning',
    'ReadOnlyHostInspectionCompleted',
    'DiscoveryAborted',
    'LabProvisioning',
    'WritableExecution'
)

$script:XboxOSControlledLiveTransactionTransitions = @{
    'LiveDiscoveryPlanned'            = @('ApprovalRequired', 'HostDiscoveryBlocked')
    'ApprovalRequired'                = @('HostDiscoveryAuthorized', 'HostDiscoveryBlocked')
    'HostDiscoveryAuthorized'         = @('ReadOnlyInspectionRunning', 'HostDiscoveryBlocked', 'DiscoveryAborted')
    'ReadOnlyInspectionRunning'       = @('ReadOnlyHostInspectionCompleted', 'DiscoveryAborted')
    'ReadOnlyHostInspectionCompleted' = @()
    'HostDiscoveryBlocked'            = @()
    'DiscoveryAborted'                = @()
    'LabProvisioning'                 = @()
    'WritableExecution'               = @()
}

# Commands a live read-only invoker may reference. Anything else fails the static AST gate.
$script:XboxOSControlledLiveAllowedInvokerCommands = @(
    'Get-CimInstance', 'Get-ItemProperty', 'Get-Module', 'Get-Command', 'Get-VM', 'Get-VMSwitch',
    'Get-VMHardDiskDrive', 'Get-VMNetworkAdapter', 'Get-NetAdapter', 'Get-PSDrive', 'Get-WindowsImage',
    'Test-Path', 'Select-Object', 'Where-Object', 'ForEach-Object', 'Measure-Object', 'Sort-Object',
    'Test-XboxOSCloudSynchronizedPath'
)
$script:XboxOSControlledLiveAllowedInvokerMembers = @(
    'Round', 'ToString', 'Trim', 'ToLowerInvariant', 'ToUpperInvariant', 'Contains', 'Count', 'Sum'
)

function Get-XboxOSControlledLiveDiscoveryEngineVersion { return $script:XboxOSControlledLiveDiscoveryEngineVersion }
function Get-XboxOSControlledLiveReplayStoreSchemaVersion { return $script:XboxOSControlledLiveReplayStoreSchemaVersion }
function Get-XboxOSControlledLiveActivationSchemaVersion { return $script:XboxOSControlledLiveActivationSchemaVersion }
function Get-XboxOSControlledLiveEvidenceSchemaVersion { return $script:XboxOSControlledLiveEvidenceSchemaVersion }
function Get-XboxOSControlledLiveReportSchemaVersion { return $script:XboxOSControlledLiveReportSchemaVersion }
function Get-XboxOSControlledLiveDefaultReplayStorePath { return $script:XboxOSControlledLiveDefaultReplayStorePath }
function Get-XboxOSControlledLiveRealHostCommandsInvoked { return [bool]$script:XboxOSControlledLiveRealHostCommandsInvoked }

function Get-XboxOSControlledLiveOperatorAcknowledgmentText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunIdentity)
    return ('I authorize read-only host discovery run {0}' -f $RunIdentity)
}

function Assert-XboxOSControlledLiveDiscoverySafetyInvariants {
    [CmdletBinding()]
    param([object]$Report = $null)

    Assert-XboxOSHostDiscoverySafetyInvariants -Report $null
    if (Get-XboxOSAuthorizedHostDiscoveryLiveActivationEnabled) {
        throw 'Safety invariant violated: the M6D global live activation flag must remain False; M6E uses per-run activations only.'
    }
    if ($null -eq $Report) { return }
    foreach ($flag in @(
            'realDismExecutionEnabled', 'modifyingCommandsInvoked', 'executionAuthorized', 'servicingAuthorized',
            'experimentalMutationEnabled', 'experimentalExecutionAuthorized',
            'labRealProvisioningEnabled', 'labHypervisorMutationInvoked', 'layerDActivated',
            'labProvisioningAuthorized', 'writableServicingAuthorized', 'networkIsolationVerified'
        )) {
        if ($Report.PSObject.Properties[$flag] -and $Report.$flag) {
            throw ("Safety invariant violated: {0} must be False." -f $flag)
        }
    }
}

#region Durable replay store

function Assert-XboxOSControlledLiveStorePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$RepoRoot = $null
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not $RepoRoot) {
        try { $RepoRoot = Get-XboxOSRepoRoot } catch { $RepoRoot = $null }
    }
    if ($RepoRoot -and (Test-XboxOSPathEqualsOrUnder -Path $full -ParentPath ([System.IO.Path]::GetFullPath($RepoRoot)))) {
        throw "Refusing durable replay store inside the repository: $full"
    }
    if ($full -match '(?i)[\\/]OneDrive' -or (Test-XboxOSCloudSynchronizedPath -Path $full)) {
        throw "Refusing durable replay store inside a cloud-synchronized folder: $full"
    }
    return $full
}

function New-XboxOSDurableReplayStore {
    [CmdletBinding()]
    param(
        [string]$Path = $script:XboxOSControlledLiveDefaultReplayStorePath,
        [string]$RepoRoot = $null
    )

    $full = Assert-XboxOSControlledLiveStorePath -Path $Path -RepoRoot $RepoRoot
    $dir = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return [pscustomobject]@{
        schemaVersion = $script:XboxOSControlledLiveReplayStoreSchemaVersion
        path          = $full
        headPath      = ($full + '.head')
        storesSecrets = $false
    }
}

function Get-XboxOSReplayRecordHash {
    # Hash over the exact canonical line with recordHash blanked; verification never depends on JSON re-parsing.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CanonicalLineWithBlankHash)
    return Get-XboxOSUtf8Sha256Hex -Text $CanonicalLineWithBlankHash
}

function ConvertFrom-XboxOSReplayStoreText {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Text,
        [AllowEmptyString()][string]$HeadText = ''
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $entries = New-Object System.Collections.Generic.List[object]
    $prev = $script:XboxOSControlledLiveGenesisHash
    $expectedSeq = 1
    $lines = @(($Text -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        $hashMatch = [regex]::Match($trimmed, '"recordHash":"([0-9A-Fa-f]{64})"\}$')
        try {
            $obj = $trimmed | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
        catch {
            $obj = $null
        }
        if ($null -eq $obj -or -not $hashMatch.Success) {
            [void]$errors.Add(("Unparseable replay record at sequence {0}." -f $expectedSeq))
            break
        }
        $ordered = [ordered]@{}
        foreach ($k in @('schemaVersion', 'sequence', 'eventType', 'nonce', 'runIdentity', 'bindingHash', 'hostIdentityKey',
                'gitCommitSha', 'publicKeyFingerprint', 'issuedUtc', 'expiresUtc', 'recordedUtc', 'outcome', 'prevHash', 'recordHash')) {
            $ordered[$k] = if ($obj[$k] -is [datetime]) { ([datetime]$obj[$k]).ToUniversalTime().ToString('o') } else { $obj[$k] }
        }
        if ([string]$ordered.schemaVersion -ne $script:XboxOSControlledLiveReplayStoreSchemaVersion) {
            [void]$errors.Add(("Replay record {0} has unexpected schema." -f $expectedSeq))
        }
        if ([int64]$ordered.sequence -ne $expectedSeq) {
            [void]$errors.Add(("Replay record sequence gap or reorder at {0}." -f $expectedSeq))
        }
        if ([string]$ordered.prevHash -ne $prev) {
            [void]$errors.Add(("Replay record chain broken at sequence {0}." -f $expectedSeq))
        }
        $blank = $trimmed.Substring(0, $hashMatch.Index) + '"recordHash":""}'
        $recomputed = Get-XboxOSReplayRecordHash -CanonicalLineWithBlankHash $blank
        if ($hashMatch.Groups[1].Value -ne $recomputed -or [string]$ordered.recordHash -ne $recomputed) {
            [void]$errors.Add(("Replay record hash mismatch at sequence {0}." -f $expectedSeq))
        }
        [void]$entries.Add([pscustomobject]$ordered)
        $prev = [string]$ordered.recordHash
        $expectedSeq++
    }

    if (-not [string]::IsNullOrWhiteSpace($HeadText)) {
        $head = $HeadText.Trim() -split '\|'
        $headSeq = [int64]0
        if ($head.Count -ne 2 -or -not [int64]::TryParse($head[0], [ref]$headSeq)) {
            [void]$errors.Add('Replay store head anchor is malformed.')
        }
        elseif ($headSeq -ne ($expectedSeq - 1) -or $head[1] -ne $prev) {
            [void]$errors.Add('Replay store head anchor does not match the last record (possible truncation or deletion).')
        }
    }
    elseif ($entries.Count -gt 0) {
        [void]$errors.Add('Replay store head anchor missing while records exist.')
    }

    $integrity = if ($errors.Count -gt 0) { 'Tampered' } elseif ($entries.Count -eq 0) { 'Empty' } else { 'Valid' }
    return [pscustomobject]@{
        integrity    = $integrity
        entries      = [object[]]@($entries.ToArray())
        lastHash     = $prev
        nextSequence = $expectedSeq
        errors       = [string[]]@($errors.ToArray())
    }
}

function Read-XboxOSDurableReplayStore {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Store)

    $text = if (Test-Path -LiteralPath $Store.path) { [System.IO.File]::ReadAllText($Store.path) } else { '' }
    $head = if (Test-Path -LiteralPath $Store.headPath) { [System.IO.File]::ReadAllText($Store.headPath) } else { '' }
    if (-not (Test-Path -LiteralPath $Store.path) -and -not [string]::IsNullOrWhiteSpace($head)) {
        return [pscustomobject]@{
            integrity    = 'Tampered'
            entries      = @()
            lastHash     = $script:XboxOSControlledLiveGenesisHash
            nextSequence = 1
            errors       = @('Replay store file missing while head anchor exists (possible deletion).')
        }
    }
    return ConvertFrom-XboxOSReplayStoreText -Text $text -HeadText $head
}

function Open-XboxOSReplayStoreLockedStream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Attempts = 50
    )

    for ($i = 0; $i -lt $Attempts; $i++) {
        try {
            return [System.IO.File]::Open($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        }
        catch [System.IO.IOException] {
            [System.Threading.Thread]::Sleep(100)
        }
    }
    throw "Unable to obtain exclusive lock on durable replay store: $Path"
}

function Add-XboxOSDurableReplayRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Store,
        [Parameter(Mandatory)][object]$Approval,
        [Parameter(Mandatory)][ValidateSet('ApprovalClaimed', 'RunCompleted')][string]$EventType,
        [string]$Outcome = '',
        [string]$ExpectedClaimHash = ''
    )

    $stream = Open-XboxOSReplayStoreLockedStream -Path $Store.path
    try {
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.UTF8Encoding]::new($false), $false, 4096, $true)
        $text = $reader.ReadToEnd()
        $reader.Dispose()
        $head = if (Test-Path -LiteralPath $Store.headPath) { [System.IO.File]::ReadAllText($Store.headPath) } else { '' }
        $state = ConvertFrom-XboxOSReplayStoreText -Text $text -HeadText $head
        if ($state.integrity -eq 'Tampered') {
            throw ("Durable replay store integrity failure; failing closed: {0}" -f ($state.errors -join '; '))
        }

        $nonce = [string]$Approval.nonce
        $run = [string]$Approval.runIdentity
        $binding = [string]$Approval.bindingHash
        $claims = @($state.entries | Where-Object { $_.eventType -eq 'ApprovalClaimed' })
        if ($EventType -eq 'ApprovalClaimed') {
            foreach ($c in $claims) {
                if ([string]$c.nonce -eq $nonce) { throw ("Durable replay detected: nonce already consumed ({0})." -f $nonce) }
                if ([string]$c.runIdentity -eq $run) { throw ("Durable replay detected: run identity already consumed ({0})." -f $run) }
                if ([string]$c.bindingHash -eq $binding) { throw 'Durable replay detected: approval binding already consumed.' }
            }
        }
        else {
            $mine = @($claims | Where-Object { [string]$_.runIdentity -eq $run })
            if ($mine.Count -ne 1 -or ($ExpectedClaimHash -and [string]$mine[0].recordHash -ne $ExpectedClaimHash)) {
                throw 'Cannot record run completion: matching durable claim not found.'
            }
            if (@($state.entries | Where-Object { $_.eventType -eq 'RunCompleted' -and [string]$_.runIdentity -eq $run }).Count -gt 0) {
                throw 'Run completion already recorded for this run identity.'
            }
        }

        $record = [ordered]@{
            schemaVersion        = $script:XboxOSControlledLiveReplayStoreSchemaVersion
            sequence             = [int64]$state.nextSequence
            eventType            = $EventType
            nonce                = $nonce
            runIdentity          = $run
            bindingHash          = $binding
            hostIdentityKey      = [string]$Approval.hostIdentityKey
            gitCommitSha         = [string]$Approval.gitCommitSha
            publicKeyFingerprint = [string]$Approval.publicKeyFingerprint
            issuedUtc            = ([datetime]$Approval.issuedUtc).ToUniversalTime().ToString('o')
            expiresUtc           = ([datetime]$Approval.expiresUtc).ToUniversalTime().ToString('o')
            recordedUtc          = [datetime]::UtcNow.ToString('o')
            outcome              = $Outcome
            prevHash             = [string]$state.lastHash
            recordHash           = ''
        }
        $record.recordHash = Get-XboxOSReplayRecordHash -CanonicalLineWithBlankHash (ConvertTo-XboxOSCanonicalJson -Value $record)
        $line = (ConvertTo-XboxOSCanonicalJson -Value $record) + "`n"
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($line)
        [void]$stream.Seek(0, [System.IO.SeekOrigin]::End)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        [System.IO.File]::WriteAllText($Store.headPath, ('{0}|{1}' -f $record.sequence, $record.recordHash))
        return [pscustomobject]$record
    }
    finally {
        $stream.Dispose()
    }
}

function Register-XboxOSDurableApprovalClaim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Store,
        [Parameter(Mandatory)][object]$Approval
    )
    return Add-XboxOSDurableReplayRecord -Store $Store -Approval $Approval -EventType 'ApprovalClaimed' -Outcome 'Claimed'
}

function Complete-XboxOSDurableApprovalClaim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Store,
        [Parameter(Mandatory)][object]$Approval,
        [Parameter(Mandatory)][string]$ClaimRecordHash,
        [Parameter(Mandatory)][string]$Outcome
    )
    return Add-XboxOSDurableReplayRecord -Store $Store -Approval $Approval -EventType 'RunCompleted' -Outcome $Outcome -ExpectedClaimHash $ClaimRecordHash
}

function Test-XboxOSDurableApprovalClaim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Store,
        [Parameter(Mandatory)][object]$Approval,
        [Parameter(Mandatory)][string]$ClaimRecordHash
    )

    $state = Read-XboxOSDurableReplayStore -Store $Store
    $errors = New-Object System.Collections.Generic.List[string]
    if ($state.integrity -ne 'Valid') {
        [void]$errors.Add(("Durable replay store integrity is {0}." -f $state.integrity))
        foreach ($e in @($state.errors)) { [void]$errors.Add($e) }
    }
    $mine = @($state.entries | Where-Object { $_.eventType -eq 'ApprovalClaimed' -and [string]$_.runIdentity -eq [string]$Approval.runIdentity })
    if ($mine.Count -ne 1) {
        [void]$errors.Add('Exactly one durable claim must exist for this run identity.')
    }
    elseif ([string]$mine[0].recordHash -ne $ClaimRecordHash -or [string]$mine[0].nonce -ne [string]$Approval.nonce) {
        [void]$errors.Add('Durable claim does not belong to this activation.')
    }
    if (@($state.entries | Where-Object { $_.eventType -eq 'RunCompleted' -and [string]$_.runIdentity -eq [string]$Approval.runIdentity }).Count -gt 0) {
        [void]$errors.Add('Run identity already completed; activation cannot be reused.')
    }
    return [pscustomobject]@{
        valid  = [bool]($errors.Count -eq 0)
        errors = [string[]]@($errors.ToArray())
    }
}

#endregion

#region Approval import/export and independent verification

function Export-XboxOSControlledLiveApproval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Approval,
        [Parameter(Mandatory)][string]$Path
    )

    if ([bool]$Approval.testKeyOnly -or [bool]$Approval.simulationOnly) {
        Write-Warning 'Exporting a test-key / simulation-only approval: it can never authorize live discovery.'
    }
    $doc = [ordered]@{}
    foreach ($p in $Approval.PSObject.Properties) {
        if ($p.Value -is [datetime]) { $doc[$p.Name] = ([datetime]$p.Value).ToUniversalTime().ToString('o') }
        else { $doc[$p.Name] = $p.Value }
    }
    $dir = Split-Path -Parent ([System.IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($doc | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $Path -Encoding UTF8
    return (Get-Item -LiteralPath $Path).FullName
}

function ConvertTo-XboxOSUtcDateTime {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    if ($Value -is [datetime]) { return ([datetime]$Value).ToUniversalTime() }
    return [datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

function Import-XboxOSControlledLiveApproval {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Approval file not found: $Path" }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($field in @('issuedUtc', 'expiresUtc')) {
        if (-not $raw.PSObject.Properties[$field]) { throw ("Approval file missing {0}." -f $field) }
        $raw.$field = ConvertTo-XboxOSUtcDateTime -Value $raw.$field
    }
    return $raw
}

function Get-XboxOSControlledLiveApprovalBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Record)

    return [ordered]@{
        layer                = 'HostDiscoveryReal'
        operatorId           = [string]$Record.operatorId
        hostIdentityKey      = [string]$Record.hostIdentityKey
        scopeDigest          = [string]$Record.scopeDigest
        gitCommitSha         = [string]$Record.gitCommitSha
        approvedCategories   = @($Record.approvedCategories | Sort-Object -Unique)
        readOnlyAcknowledged = $true
        runIdentity          = [string]$Record.runIdentity
        nonce                = [string]$Record.nonce
        issuedUtc            = (ConvertTo-XboxOSUtcDateTime -Value $Record.issuedUtc).ToString('o')
        expiresUtc           = (ConvertTo-XboxOSUtcDateTime -Value $Record.expiresUtc).ToString('o')
        publicKeyFingerprint = [string]$Record.publicKeyFingerprint
    }
}

function Test-XboxOSControlledLiveApproval {
    <#
    .SYNOPSIS
      Independent M6E approval verifier. Does not consult process-local registries; replay is enforced by the
      durable store. The signed payload is recomputed from record fields so no field can drift from the signature.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Record,
        [Parameter(Mandatory)][object]$HostIdentity,
        [Parameter(Mandatory)][object]$DiscoveryScope,
        [Parameter(Mandatory)][string]$ExpectedGitCommitSha,
        [Parameter(Mandatory)][string]$PublicKeyPemPath,
        [datetime]$AsOfUtc = [datetime]::UtcNow,
        [switch]$AllowSimulationTestKey
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $field = { param($n) if ($Record.PSObject.Properties[$n]) { $Record.$n } else { $null } }

    if ([string](& $field 'layer') -ne 'HostDiscoveryReal') {
        [void]$errors.Add('Approval layer must be HostDiscoveryReal.')
    }
    if ([string](& $field 'schemaVersion') -ne (Get-XboxOSAuthorizedHostDiscoveryApprovalSchemaVersion)) {
        [void]$errors.Add('Approval schema must be host-discovery-real-approval-v1.')
    }
    foreach ($req in @('operatorId', 'hostIdentityKey', 'scopeDigest', 'gitCommitSha', 'runIdentity', 'nonce', 'bindingHash', 'signatureBase64', 'signingPayload', 'publicKeyFingerprint', 'issuedUtc', 'expiresUtc')) {
        if ([string]::IsNullOrWhiteSpace([string](& $field $req))) {
            [void]$errors.Add(("Approval field '{0}' missing." -f $req))
        }
    }
    if ($errors.Count -gt 0) {
        return [pscustomobject]@{ valid = $false; errors = [string[]]@($errors.ToArray()); trustedKey = $false }
    }

    if ([string]$Record.hostIdentityKey -ne [string]$HostIdentity.hostIdentityKey) {
        [void]$errors.Add('Host identity mismatch.')
    }
    if ([string]$Record.scopeDigest -ne [string]$DiscoveryScope.scopeDigest) {
        [void]$errors.Add('Discovery scope mismatch.')
    }
    if (-not [bool]$DiscoveryScope.realHostAllowed) {
        [void]$errors.Add('Discovery scope does not allow real-host inspection.')
    }
    foreach ($c in @($Record.approvedCategories)) {
        if (@($DiscoveryScope.categories) -notcontains [string]$c) {
            [void]$errors.Add(("Approved category '{0}' is outside discovery scope." -f $c))
        }
    }
    if ([string]$Record.gitCommitSha -ne $ExpectedGitCommitSha) {
        [void]$errors.Add('Git commit SHA mismatch.')
    }
    if (-not [bool](& $field 'readOnlyAcknowledged')) {
        [void]$errors.Add('Read-only acknowledgment missing.')
    }
    if ([bool](& $field 'activatesLayerD') -or [bool](& $field 'grantsProvisioning')) {
        [void]$errors.Add('Approval must not grant Layer D or provisioning.')
    }
    if ([bool](& $field 'reusesM6cMockApproval')) {
        [void]$errors.Add('M6C mock approvals are invalid.')
    }

    $issued = ConvertTo-XboxOSUtcDateTime -Value $Record.issuedUtc
    $expires = ConvertTo-XboxOSUtcDateTime -Value $Record.expiresUtc
    $now = $AsOfUtc.ToUniversalTime()
    if ($expires -le $now) { [void]$errors.Add('Approval is expired.') }
    if ($issued -gt $now.Add($script:XboxOSControlledLiveMaxClockSkew)) { [void]$errors.Add('Approval issued in the future.') }
    if (($expires - $issued) -gt $script:XboxOSControlledLiveMaxApprovalLifetime) {
        [void]$errors.Add(("Approval lifetime exceeds the {0}-hour maximum." -f $script:XboxOSControlledLiveMaxApprovalLifetime.TotalHours))
    }

    $binding = Get-XboxOSControlledLiveApprovalBinding -Record $Record
    if ((Get-XboxOSUtf8Sha256Hex -Text (ConvertTo-XboxOSCanonicalJson -Value $binding)) -ne [string]$Record.bindingHash) {
        [void]$errors.Add('Approval binding hash mismatch.')
    }
    $expectedPayload = New-XboxOSApprovalSigningPayload -ApprovalBindingDocument $binding -Nonce ([string]$Record.nonce)
    if ($expectedPayload -ne [string]$Record.signingPayload) {
        [void]$errors.Add('Signed payload does not match approval fields.')
    }

    $trusted = $false
    $fp = Get-XboxOSPublicKeyFingerprint -PublicKeyPemPath $PublicKeyPemPath
    if ([string]$Record.publicKeyFingerprint -ne $fp) {
        [void]$errors.Add('Public key fingerprint mismatch.')
    }
    Initialize-XboxOSAuthorizedHostDiscoveryTestKeyFingerprints
    $isTestKey = @(Get-XboxOSControlledLiveForbiddenKeyFingerprints) -contains $fp
    if ($isTestKey -and -not $AllowSimulationTestKey) {
        [void]$errors.Add('Repository test signing keys cannot authorize live host discovery.')
    }
    $trusted = -not $isTestKey
    try {
        $sig = Test-XboxOSApprovalSignature -CanonicalPayload ([string]$Record.signingPayload) -SignatureBase64 ([string]$Record.signatureBase64) -PublicKeyPemPath $PublicKeyPemPath
        if (-not [bool]$sig.signatureValid) { [void]$errors.Add('Invalid approval signature.') }
    }
    catch {
        [void]$errors.Add(("Approval signature could not be verified: {0}" -f $_.Exception.Message))
    }

    return [pscustomobject]@{
        valid      = [bool]($errors.Count -eq 0)
        errors     = [string[]]@($errors.ToArray())
        trustedKey = [bool]$trusted
    }
}

function Get-XboxOSControlledLiveForbiddenKeyFingerprints {
    [CmdletBinding()]
    param()
    $fps = New-Object System.Collections.Generic.List[string]
    try {
        $root = Get-XboxOSRepoRoot
        foreach ($pem in @(Get-ChildItem -LiteralPath (Join-Path $root 'tests\Fixtures') -Recurse -Filter '*public*.pem' -File -ErrorAction SilentlyContinue)) {
            [void]$fps.Add((Get-XboxOSPublicKeyFingerprint -PublicKeyPemPath $pem.FullName))
        }
    }
    catch {
        Write-Verbose ("Fixture key enumeration unavailable: {0}" -f $_.Exception.Message)
    }
    return [string[]]@($fps.ToArray() | Select-Object -Unique)
}

#endregion

#region Read-only invokers and static AST gate

function Test-XboxOSReadOnlyInvokerScript {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock)

    $errors = New-Object System.Collections.Generic.List[string]
    $ast = $ScriptBlock.Ast
    foreach ($cmd in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
        $name = $cmd.GetCommandName()
        if (-not $name) {
            [void]$errors.Add('Dynamic command invocation is forbidden in read-only invokers.')
            continue
        }
        if ($cmd.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot) {
            [void]$errors.Add(("Dot-sourcing is forbidden: {0}" -f $name))
        }
        if ($script:XboxOSControlledLiveAllowedInvokerCommands -notcontains $name) {
            [void]$errors.Add(("Command not on the read-only invoker allowlist: {0}" -f $name))
        }
    }
    foreach ($m in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))) {
        $member = [string]$m.Member.Extent.Text
        if ($script:XboxOSControlledLiveAllowedInvokerMembers -notcontains $member) {
            [void]$errors.Add(("Method invocation not allowed in read-only invokers: {0}" -f $member))
        }
    }
    foreach ($a in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))) {
        $left = $a.Left.Extent.Text
        if ($left -match '^(?i)\$(env|global|script):' -or $left -match '^(?i)\$\{?[a-z]+:') {
            [void]$errors.Add(("Scoped/provider assignment forbidden in read-only invokers: {0}" -f $left))
        }
    }
    foreach ($r in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FileRedirectionAst] }, $true))) {
        [void]$errors.Add(("File redirection forbidden in read-only invokers: {0}" -f $r.Extent.Text))
    }
    return [pscustomobject]@{
        readOnly = [bool]($errors.Count -eq 0)
        errors   = [string[]]@($errors.ToArray())
    }
}

function Get-XboxOSLiveReadOnlyInvokerMap {
    <#
    .SYNOPSIS
      Fixed read-only observation scripts per typed operation. Each receives a context hashtable.
      Never extended at runtime; every entry must pass Test-XboxOSReadOnlyInvokerScript.
    #>
    [CmdletBinding()]
    param()

    return [ordered]@{
        'Get-OsInfo'                     = {
            param($Context)
            $os = Get-CimInstance -ClassName Win32_OperatingSystem
            $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
            $fw = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name PEFirmwareType
            @{
                edition      = [string]$os.Caption
                build        = ('{0}.{1}' -f $os.BuildNumber, $cv.UBR)
                architecture = [string]$os.OSArchitecture
                firmware     = $(if ($fw.PEFirmwareType -eq 2) { 'UEFI' } elseif ($fw.PEFirmwareType -eq 1) { 'BIOS' } else { 'Unknown' })
                hostLabel    = [string]$os.CSName
            }
        }
        'Get-CpuVirtualization'          = {
            param($Context)
            $cpu = @(Get-CimInstance -ClassName Win32_Processor)
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem
            @{
                virtualizationFirmwareEnabled = [bool]($cpu | Where-Object { $_.VirtualizationFirmwareEnabled } | Measure-Object).Count
                logicalProcessors             = [int]($cpu | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
                hypervisorPresent             = [bool]$cs.HypervisorPresent
            }
        }
        'Get-HyperVManagementPresence'   = {
            param($Context)
            $module = @(Get-Module -ListAvailable -Name Hyper-V)
            $getVm = Get-Command -Name Get-VM -ErrorAction SilentlyContinue
            @{
                moduleAvailable = [bool]($module.Count -gt 0)
                getVmAvailable  = [bool]$getVm
                featureState    = 'NotQueried'
            }
        }
        'Get-VmInventory'                = {
            param($Context)
            @{
                availability = 'Available'
                vms          = @(Get-VM | Select-Object -Property Name, State, Generation | ForEach-Object {
                        @{ name = [string]$_.Name; state = [string]$_.State; generation = [int]$_.Generation }
                    })
            }
        }
        'Get-VmSwitchInventory'          = {
            param($Context)
            @{
                availability = 'Available'
                switches     = @(Get-VMSwitch | ForEach-Object {
                        @{ name = [string]$_.Name; type = [string]$_.SwitchType }
                    })
            }
        }
        'Get-NetworkAdapters'            = {
            param($Context)
            @{
                adapters = @(Get-NetAdapter | ForEach-Object {
                        @{ name = [string]$_.Name; ifIndex = [int]$_.ifIndex; status = [string]$_.Status; description = [string]$_.InterfaceDescription }
                    })
            }
        }
        'Get-VhdMetadata'                = {
            param($Context)
            @{
                vhds = @(Get-VM | Get-VMHardDiskDrive | ForEach-Object {
                        @{ vmName = [string]$_.VMName; path = [string]$_.Path }
                    })
            }
        }
        'Get-HostResources'              = {
            param($Context)
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem
            $drive = Get-PSDrive -Name C -PSProvider FileSystem
            @{
                cpuCount    = [int]$cs.NumberOfLogicalProcessors
                memoryGiB   = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
                freeDiskGiB = [math]::Round($drive.Free / 1GB, 1)
            }
        }
        'Get-WorkspaceBoundaries'        = {
            param($Context)
            @{
                evaluated            = $true
                workspaceRootExists  = [bool](Test-Path -LiteralPath $Context.WorkspaceRoot)
                workspaceCloudSynced = [bool](Test-XboxOSCloudSynchronizedPath -Path $Context.WorkspaceRoot)
            }
        }
        'Get-DismMountMetadata'          = {
            param($Context)
            @{
                mounts = @(Get-WindowsImage -Mounted | ForEach-Object {
                        @{ path = [string]$_.Path; imagePath = [string]$_.ImagePath; mountStatus = [string]$_.MountStatus }
                    })
            }
        }
        'Get-LabCredentialPrerequisites' = {
            param($Context)
            @{
                labKeyCustodyDocumented = [bool](Test-Path -LiteralPath $Context.KeyCustodyPath)
                productionTrustPresent  = $false
            }
        }
    }
}

function Get-XboxOSControlledLiveErrorClassification {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $ex = $ErrorRecord.Exception
    $category = [string]$ErrorRecord.CategoryInfo.Category
    if ($ex -is [System.Management.Automation.CommandNotFoundException] -or ($category -eq 'ObjectNotFound' -and $ex.Message -match '(?i)not recognized|module')) {
        return @{ status = 'Unavailable'; exitStatus = 'ModuleMissing' }
    }
    if ($ex -is [System.UnauthorizedAccessException] -or $category -in @('PermissionDenied', 'SecurityError') -or
        $ex.Message -match '(?i)access is denied|required permission|requires elevation|administrator') {
        return @{ status = 'Unverified'; exitStatus = 'AccessDenied' }
    }
    return @{ status = 'Failed'; exitStatus = 'Error' }
}

#endregion

#region Activation, execution environment, and per-operation execution

function Test-XboxOSControlledLiveExecutionEnvironment {
    [CmdletBinding()]
    param(
        [switch]$OperatorAcceptsElevatedSession,
        [Nullable[bool]]$IsElevated = $null,
        [hashtable]$Environment = $null
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $envVars = if ($Environment) { $Environment } else {
        @{ CI = $env:CI; GITHUB_ACTIONS = $env:GITHUB_ACTIONS; TF_BUILD = $env:TF_BUILD }
    }
    foreach ($k in @('CI', 'GITHUB_ACTIONS', 'TF_BUILD')) {
        if (-not [string]::IsNullOrWhiteSpace([string]$envVars[$k]) -and [string]$envVars[$k] -notin @('0', 'false', 'False')) {
            [void]$errors.Add(("Live discovery is forbidden in CI/automation environments ({0} set)." -f $k))
        }
    }
    $elevated = if ($null -ne $IsElevated) { [bool]$IsElevated } else { [bool](Test-XboxOSAdministrator) }
    if ($elevated -and -not $OperatorAcceptsElevatedSession) {
        [void]$errors.Add('Session is elevated; live discovery runs non-elevated by default. The operator must explicitly accept an elevated session.')
    }
    return [pscustomobject]@{
        allowed  = [bool]($errors.Count -eq 0)
        elevated = $elevated
        errors   = [string[]]@($errors.ToArray())
    }
}

function New-XboxOSControlledLiveDiscoveryActivation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Approval,
        [Parameter(Mandatory)][object]$HostIdentity,
        [Parameter(Mandatory)][object]$DiscoveryScope,
        [Parameter(Mandatory)][string]$PublicKeyPemPath,
        [Parameter(Mandatory)][object]$ReplayStore,
        [Parameter(Mandatory)][AllowEmptyString()][string]$OperatorAcknowledgment,
        [object]$ToolingGitState = $null,
        [string]$RepoRoot = $null,
        [System.Collections.IDictionary]$Invokers = $null,
        [object]$ExecutionEnvironment = $null,
        [switch]$AllowSimulationTestKey,
        [switch]$OperatorAcceptsElevatedSession
    )

    Assert-XboxOSControlledLiveDiscoverySafetyInvariants
    $injected = $null -ne $Invokers
    if ($AllowSimulationTestKey -and -not $injected) {
        throw 'Simulation test keys may only be used with injected (non-live) invokers.'
    }

    $blockers = New-Object System.Collections.Generic.List[string]
    $expectedAck = Get-XboxOSControlledLiveOperatorAcknowledgmentText -RunIdentity ([string]$Approval.runIdentity)
    if ($OperatorAcknowledgment -cne $expectedAck) {
        [void]$blockers.Add(("Operator acknowledgment must exactly equal: '{0}'" -f $expectedAck))
    }

    if (-not $injected) {
        $envCheck = if ($ExecutionEnvironment) { $ExecutionEnvironment } else {
            Test-XboxOSControlledLiveExecutionEnvironment -OperatorAcceptsElevatedSession:$OperatorAcceptsElevatedSession
        }
        foreach ($e in @($envCheck.errors)) { [void]$blockers.Add($e) }
    }

    if (-not $ToolingGitState) { $ToolingGitState = Get-XboxOSToolingGitVerificationState -RepoRoot $RepoRoot }
    if ([string]$ToolingGitState.verificationState -ne 'VerifiedClean' -or -not [bool]$ToolingGitState.workingTreeClean) {
        [void]$blockers.Add(("Tooling Git state must be VerifiedClean (was {0})." -f $ToolingGitState.verificationState))
    }
    if ([string]$ToolingGitState.gitCommitSha -ne [string]$Approval.gitCommitSha) {
        [void]$blockers.Add('Tooling Git commit does not match the approved commit.')
    }

    $check = Test-XboxOSControlledLiveApproval -Record $Approval -HostIdentity $HostIdentity -DiscoveryScope $DiscoveryScope `
        -ExpectedGitCommitSha ([string]$ToolingGitState.gitCommitSha) -PublicKeyPemPath $PublicKeyPemPath -AllowSimulationTestKey:$AllowSimulationTestKey
    foreach ($e in @($check.errors)) { [void]$blockers.Add($e) }

    if ($blockers.Count -gt 0) {
        return [pscustomobject]@{
            schemaVersion = $script:XboxOSControlledLiveActivationSchemaVersion
            activated        = $false
            blockers         = [string[]]@($blockers.ToArray())
            claim            = $null
            invokersInjected = $injected
            trustedKey       = $false
            gitCommitSha     = [string]$ToolingGitState.gitCommitSha
        }
    }

    # All prechecks passed: consume the approval durably before any observation command.
    $claim = Register-XboxOSDurableApprovalClaim -Store $ReplayStore -Approval $Approval
    $map = if ($injected) { $Invokers } else { Get-XboxOSLiveReadOnlyInvokerMap }

    return [pscustomobject]@{
        schemaVersion        = $script:XboxOSControlledLiveActivationSchemaVersion
        activated            = $true
        activationId         = [guid]::NewGuid().ToString('N')
        runIdentity          = [string]$Approval.runIdentity
        approval             = $Approval
        hostIdentity         = $HostIdentity
        discoveryScope       = $DiscoveryScope
        publicKeyPemPath     = $PublicKeyPemPath
        replayStore          = $ReplayStore
        claim                = $claim
        gitCommitSha         = [string]$ToolingGitState.gitCommitSha
        invokers             = $map
        invokersInjected     = $injected
        allowSimulationKey   = [bool]$AllowSimulationTestKey
        trustedKey           = [bool]$check.trustedKey
        expiresUtc           = ConvertTo-XboxOSUtcDateTime -Value $Approval.expiresUtc
        blockers             = @()
        grantsProvisioning   = $false
        grantsWritableServicing = $false
    }
}

function Invoke-XboxOSControlledLiveDiscoveryOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Activation,
        [Parameter(Mandatory)][object]$Allowlist,
        [Parameter(Mandatory)][string]$OperationId,
        [hashtable]$Context = @{},
        [datetime]$AsOfUtc = [datetime]::UtcNow
    )

    Assert-XboxOSControlledLiveDiscoverySafetyInvariants
    if (-not [bool]$Activation.activated) { throw 'Live discovery activation is not active.' }

    # Per-operation revalidation: approval, durable claim, and activation expiry.
    $re = Test-XboxOSControlledLiveApproval -Record $Activation.approval -HostIdentity $Activation.hostIdentity `
        -DiscoveryScope $Activation.discoveryScope -ExpectedGitCommitSha $Activation.gitCommitSha `
        -PublicKeyPemPath $Activation.publicKeyPemPath -AsOfUtc $AsOfUtc -AllowSimulationTestKey:$([bool]$Activation.allowSimulationKey)
    if (-not $re.valid) {
        throw ("Approval revalidation failed before '{0}': {1}" -f $OperationId, ($re.errors -join '; '))
    }
    $claimCheck = Test-XboxOSDurableApprovalClaim -Store $Activation.replayStore -Approval $Activation.approval -ClaimRecordHash ([string]$Activation.claim.recordHash)
    if (-not $claimCheck.valid) {
        throw ("Durable claim revalidation failed before '{0}': {1}" -f $OperationId, ($claimCheck.errors -join '; '))
    }

    $spec = Test-XboxOSHostDiscoveryOperationSpec -Allowlist $Allowlist -OperationId $OperationId
    if (-not $spec.allowed) {
        throw ("Non-allowlisted or denied discovery operation: {0}" -f ($spec.errors -join '; '))
    }
    $category = [string](@($Allowlist.allowedOperations | Where-Object { [string]$_.operationId -eq $OperationId })[0].category)
    if (@($Activation.approval.approvedCategories) -notcontains $category) {
        throw ("Operation '{0}' category '{1}' is outside the approved scope." -f $OperationId, $category)
    }
    if (-not $Activation.invokers.Contains($OperationId)) {
        throw ("No read-only invoker registered for '{0}'." -f $OperationId)
    }
    $invoker = [scriptblock]$Activation.invokers[$OperationId]
    $gate = Test-XboxOSReadOnlyInvokerScript -ScriptBlock $invoker
    if (-not $gate.readOnly) {
        throw ("Read-only invoker gate rejected '{0}': {1}" -f $OperationId, ($gate.errors -join '; '))
    }

    $live = -not [bool]$Activation.invokersInjected
    $started = [datetime]::UtcNow
    $status = 'Observed'
    $exitStatus = 'Success'
    $reason = $null
    $data = $null
    try {
        if ($live) { $script:XboxOSControlledLiveRealHostCommandsInvoked = $true }
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Stop'
        try { $data = & $invoker $Context }
        finally { $ErrorActionPreference = $previous }
    }
    catch {
        $cls = Get-XboxOSControlledLiveErrorClassification -ErrorRecord $_
        $status = $cls.status
        $exitStatus = $cls.exitStatus
        $reason = $_.Exception.Message
        if ($status -eq 'Unavailable' -and $OperationId -in @('Get-VmInventory', 'Get-VmSwitchInventory')) {
            $data = @{ availability = 'Unavailable'; inventsEmptyInventory = $false }
        }
    }

    return [pscustomobject]@{
        operationId       = $OperationId
        category          = $category
        status            = $status
        exitStatus        = $exitStatus
        reason            = $reason
        observationSource = $(if ($live) { 'LiveHost' } else { 'InjectedInvoker' })
        realHostInvoked   = $live
        commandText       = $invoker.ToString().Trim()
        commandSha256     = Get-XboxOSUtf8Sha256Hex -Text ($invoker.ToString().Trim())
        startedUtc        = $started.ToString('o')
        completedUtc      = [datetime]::UtcNow.ToString('o')
        data              = $data
        elevationAttempted = $false
    }
}

#endregion

#region Host identity, transaction, orchestration

function New-XboxOSObservedHostIdentity {
    [CmdletBinding()]
    param([hashtable]$OsObservation = $null)

    if (-not $OsObservation) {
        $map = Get-XboxOSLiveReadOnlyInvokerMap
        $OsObservation = & $map['Get-OsInfo'] @{}
        $script:XboxOSControlledLiveRealHostCommandsInvoked = $true
    }
    $id = New-XboxOSHostIdentity -HostLabel ([string]$OsObservation.hostLabel) -WindowsEdition ([string]$OsObservation.edition) `
        -BuildNumber ([string]$OsObservation.build) -Architecture ([string]$OsObservation.architecture)
    $id.sourceType = 'IndependentHostObservation'
    $id.observedOnHost = $true
    return $id
}

function Assert-XboxOSControlledLiveTransactionTransition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)

    foreach ($s in @($From, $To)) {
        if ($script:XboxOSControlledLiveTransactionStates -notcontains $s) { throw ("Unknown controlled live discovery state '{0}'." -f $s) }
    }
    if ($To -in @('LabProvisioning', 'WritableExecution')) {
        throw ("Transition to '{0}' is not reachable from controlled live discovery." -f $To)
    }
    if (@($script:XboxOSControlledLiveTransactionTransitions[$From]) -notcontains $To) {
        throw ("Invalid controlled live discovery transition: {0} -> {1}." -f $From, $To)
    }
    return $true
}

function Set-XboxOSControlledLiveTransactionState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Transaction, [Parameter(Mandatory)][string]$To, [string]$Note = '')

    Assert-XboxOSControlledLiveTransactionTransition -From ([string]$Transaction.state) -To $To | Out-Null
    $Transaction.state = $To
    $Transaction.history = @($Transaction.history) + @([pscustomobject]@{ utc = [datetime]::UtcNow.ToString('o'); state = $To; note = $Note })
    return $Transaction
}

function ConvertTo-XboxOSControlledLiveRedactedResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Result, [string]$Salt)

    $redact = { param($v, $k) (Protect-XboxOSHostDiscoverySensitiveValue -Value ([string]$v) -Kind $k -StableSalt $Salt).redacted }
    $d = $Result.data
    if ($null -eq $d) { return $null }
    switch ($Result.operationId) {
        'Get-OsInfo' {
            return @{ edition = $d.edition; build = $d.build; architecture = $d.architecture; firmware = $d.firmware; hostLabel = (& $redact $d.hostLabel 'Hostname') }
        }
        'Get-VmInventory' {
            if ($d.availability -ne 'Available') { return $d }
            return @{ availability = 'Available'; vms = @($d.vms | ForEach-Object { @{ name = (& $redact $_.name 'VmName'); state = $_.state; generation = $_.generation } }) }
        }
        'Get-VmSwitchInventory' {
            if ($d.availability -ne 'Available') { return $d }
            return @{ availability = 'Available'; switches = @($d.switches | ForEach-Object { @{ name = (& $redact $_.name 'Generic'); type = $_.type } }) }
        }
        'Get-NetworkAdapters' {
            return @{ adapters = @($d.adapters | ForEach-Object { @{ name = (& $redact $_.name 'AdapterId'); status = $_.status; ifIndex = $_.ifIndex } }) }
        }
        'Get-VhdMetadata' {
            return @{ vhds = @($d.vhds | ForEach-Object { @{ vmName = (& $redact $_.vmName 'VmName'); path = (& $redact $_.path 'UserPath') } }) }
        }
        'Get-DismMountMetadata' {
            return @{ mounts = @($d.mounts | ForEach-Object { @{ path = (& $redact $_.path 'UserPath'); imagePath = (& $redact $_.imagePath 'UserPath'); mountStatus = $_.mountStatus } }) }
        }
        default { return $d }
    }
}

function Invoke-XboxOSControlledLiveHostDiscovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Allowlist,
        [Parameter(Mandatory)][object]$HostIdentity,
        [Parameter(Mandatory)][object]$DiscoveryScope,
        [object]$Approval = $null,
        [string]$PublicKeyPemPath = '',
        [object]$ReplayStore = $null,
        [AllowEmptyString()][string]$OperatorAcknowledgment = '',
        [object]$ToolingGitState = $null,
        [string]$RepoRoot = $null,
        [System.Collections.IDictionary]$Invokers = $null,
        [object]$ExecutionEnvironment = $null,
        [string]$KeyCustodyPath = 'C:\XboxOS\Lab\Keys\CUSTODY.md',
        [switch]$AllowSimulationTestKey,
        [switch]$OperatorAcceptsElevatedSession,
        [scriptblock]$AsOfUtcProvider = $null
    )

    Assert-XboxOSControlledLiveDiscoverySafetyInvariants
    $discoveryId = 'm6e-' + [datetime]::UtcNow.ToString('yyyyMMddHHmmssfff')
    $tx = [pscustomobject]@{
        schemaVersion = $script:XboxOSControlledLiveTransactionSchemaVersion
        discoveryId   = $discoveryId
        state         = 'LiveDiscoveryPlanned'
        history       = @([pscustomobject]@{ utc = [datetime]::UtcNow.ToString('o'); state = 'LiveDiscoveryPlanned'; note = 'Created' })
    }
    $blockers = New-Object System.Collections.Generic.List[string]
    $results = New-Object System.Collections.Generic.List[object]
    $activation = $null
    $completionRecord = $null
    $started = [datetime]::UtcNow.ToString('o')

    if ($null -eq $Approval) {
        [void]$blockers.Add('No HostDiscoveryReal approval supplied; live discovery is blocked by default.')
        Set-XboxOSControlledLiveTransactionState -Transaction $tx -To 'HostDiscoveryBlocked' -Note 'Approval absent' | Out-Null
    }
    else {
        Set-XboxOSControlledLiveTransactionState -Transaction $tx -To 'ApprovalRequired' | Out-Null
        if ([string]::IsNullOrWhiteSpace($PublicKeyPemPath)) { [void]$blockers.Add('Trusted public key path required.') }
        if ($null -eq $ReplayStore) { [void]$blockers.Add('Durable replay store required; process-local replay protection is insufficient.') }
        if ($blockers.Count -eq 0) {
            try {
                $activation = New-XboxOSControlledLiveDiscoveryActivation -Approval $Approval -HostIdentity $HostIdentity `
                    -DiscoveryScope $DiscoveryScope -PublicKeyPemPath $PublicKeyPemPath -ReplayStore $ReplayStore `
                    -OperatorAcknowledgment $OperatorAcknowledgment -ToolingGitState $ToolingGitState -RepoRoot $RepoRoot `
                    -Invokers $Invokers -ExecutionEnvironment $ExecutionEnvironment `
                    -AllowSimulationTestKey:$AllowSimulationTestKey -OperatorAcceptsElevatedSession:$OperatorAcceptsElevatedSession
                foreach ($b in @($activation.blockers)) { [void]$blockers.Add($b) }
            }
            catch {
                [void]$blockers.Add($_.Exception.Message)
                $activation = $null
            }
        }
        if ($blockers.Count -gt 0 -or $null -eq $activation -or -not $activation.activated) {
            Set-XboxOSControlledLiveTransactionState -Transaction $tx -To 'HostDiscoveryBlocked' -Note 'Gate A prechecks failed' | Out-Null
        }
        else {
            Set-XboxOSControlledLiveTransactionState -Transaction $tx -To 'HostDiscoveryAuthorized' -Note ('Claim ' + $activation.claim.recordHash) | Out-Null
            Set-XboxOSControlledLiveTransactionState -Transaction $tx -To 'ReadOnlyInspectionRunning' | Out-Null
            $ctx = @{ WorkspaceRoot = [string]$DiscoveryScope.workspaceRoot; KeyCustodyPath = $KeyCustodyPath }
            $ops = @($Allowlist.allowedOperations | Where-Object { @($Approval.approvedCategories) -contains [string]$_.category } | ForEach-Object { [string]$_.operationId })
            $aborted = $false
            foreach ($op in $ops) {
                $asOf = if ($AsOfUtcProvider) { [datetime](& $AsOfUtcProvider $op) } else { [datetime]::UtcNow }
                try {
                    [void]$results.Add((Invoke-XboxOSControlledLiveDiscoveryOperation -Activation $activation -Allowlist $Allowlist -OperationId $op -Context $ctx -AsOfUtc $asOf))
                }
                catch {
                    [void]$blockers.Add(("Run aborted at '{0}': {1}" -f $op, $_.Exception.Message))
                    $aborted = $true
                    break
                }
            }
            $final = if ($aborted) { 'DiscoveryAborted' } else { 'ReadOnlyHostInspectionCompleted' }
            Set-XboxOSControlledLiveTransactionState -Transaction $tx -To $final | Out-Null
            try {
                $completionRecord = Complete-XboxOSDurableApprovalClaim -Store $ReplayStore -Approval $Approval -ClaimRecordHash ([string]$activation.claim.recordHash) -Outcome $final
            }
            catch {
                [void]$blockers.Add(("Durable completion record failed: {0}" -f $_.Exception.Message))
            }
        }
    }

    $salt = if ($Approval) { 'm6e-' + [string]$Approval.runIdentity } else { 'm6e-blocked' }
    $byOp = @{}
    foreach ($r in $results) { $byOp[$r.operationId] = $r }
    $hv = $byOp['Get-HyperVManagementPresence']
    $hypervisorObserved = [bool]($hv -and $hv.status -eq 'Observed' -and $hv.data -and [bool]$hv.data.moduleAvailable)
    $unavailable = @($results | Where-Object { $_.status -eq 'Unavailable' } | ForEach-Object { $_.operationId })
    $unverified = @($results | Where-Object { $_.status -in @('Unverified', 'Failed') } | ForEach-Object { $_.operationId })
    $live = [bool]($activation -and -not $activation.invokersInjected)
    $commands = @($results | ForEach-Object {
            [pscustomobject]@{
                operationId        = $_.operationId
                category           = $_.category
                status             = $_.status
                exitStatus         = $_.exitStatus
                reason             = $_.reason
                observationSource  = $_.observationSource
                commandText        = $_.commandText
                commandSha256      = $_.commandSha256
                startedUtc         = $_.startedUtc
                completedUtc       = $_.completedUtc
                elevationAttempted = $false
                redactedData       = (ConvertTo-XboxOSControlledLiveRedactedResult -Result $_ -Salt $salt)
            }
        })

    $evidence = [pscustomobject]@{
        schemaVersion            = $script:XboxOSControlledLiveEvidenceSchemaVersion
        reportNamespace          = 'm6e'
        approvalBindingHash      = $(if ($Approval) { [string]$Approval.bindingHash } else { $null })
        approvalLayer            = $(if ($Approval) { [string]$Approval.layer } else { $null })
        runIdentity              = $(if ($Approval) { [string]$Approval.runIdentity } else { $null })
        publicKeyFingerprint     = $(if ($Approval) { [string]$Approval.publicKeyFingerprint } else { $null })
        trustedKey               = [bool]($activation -and $activation.trustedKey)
        hostIdentityKey          = [string]$HostIdentity.hostIdentityKey
        hostIdentitySource       = [string]$HostIdentity.sourceType
        gitCommitSha             = $(if ($activation) { $activation.gitCommitSha } elseif ($ToolingGitState) { [string]$ToolingGitState.gitCommitSha } else { 'Unknown' })
        gitVerificationState     = $(if ($ToolingGitState) { [string]$ToolingGitState.verificationState } else { 'NotEvaluated' })
        discoveryStartedUtc      = $started
        discoveryCompletedUtc    = [datetime]::UtcNow.ToString('o')
        commands                 = $commands
        observationProvenance    = $(if ($live) { 'IndependentHostObservation' } elseif ($activation) { 'InjectedInvoker' } else { 'NotObserved' })
        unavailableOperations    = $unavailable
        unverifiedOperations     = $unverified
        networkIsolationLimitations = @(
            'Host switch inventory (including a switch named IsolatedSwitch) does not establish guest network isolation.'
            'Guest connectivity, firewall policy, and host-to-guest reachability were not tested.'
        )
        redactionStatus          = 'Applied'
        replayClaimRecordHash    = $(if ($activation -and $activation.claim) { [string]$activation.claim.recordHash } else { $null })
        replayCompletionRecordHash = $(if ($completionRecord) { [string]$completionRecord.recordHash } else { $null })
        preservesPriorBaselines  = $true
    }
    $evidence | Add-Member -NotePropertyName evidenceHash -NotePropertyValue (Get-XboxOSUtf8Sha256Hex -Text (ConvertTo-XboxOSCanonicalJson -Value ([ordered]@{
                    binding  = $evidence.approvalBindingHash
                    host     = $evidence.hostIdentityKey
                    commands = @($commands | ForEach-Object { '{0}|{1}|{2}' -f $_.operationId, $_.status, $_.commandSha256 })
                    ns       = 'm6e'
                })))

    $report = [pscustomobject]@{
        schemaVersion                   = $script:XboxOSControlledLiveReportSchemaVersion
        engineVersion                   = $script:XboxOSControlledLiveDiscoveryEngineVersion
        reportNamespace                 = 'm6e'
        discoveryId                     = $discoveryId
        decision                        = [string]$tx.state
        transaction                     = $tx
        blockers                        = [string[]]@($blockers.ToArray())
        hostDiscoveryAuthorized         = [bool]($activation -and $activation.activated)
        readOnlyHostInspectionCompleted = [bool]($tx.state -eq 'ReadOnlyHostInspectionCompleted')
        hypervisorObserved              = $hypervisorObserved
        independentHostObservation      = $live
        networkIsolationVerified        = $false
        networkIsolationVerificationStatus = 'NetworkIsolationNotVerified'
        labProvisioningAuthorized       = $false
        writableServicingAuthorized     = $false
        provisioningDecision            = 'LabProvisioningBlocked'
        evidence                        = $evidence
        realDismExecutionEnabled        = $false
        modifyingCommandsInvoked        = $false
        executionAuthorized             = $false
        servicingAuthorized             = $false
        experimentalMutationEnabled     = $false
        experimentalExecutionAuthorized = $false
        labRealProvisioningEnabled      = $false
        labHypervisorMutationInvoked    = $false
        layerDActivated                 = $false
    }
    Assert-XboxOSControlledLiveDiscoverySafetyInvariants -Report $report
    return $report
}

function Save-XboxOSControlledLiveDiscoveryReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Report,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$Stem = 'XboxOS11-host-discovery-m6e',
        [string]$RepoRoot = $null
    )

    Assert-XboxOSControlledLiveDiscoverySafetyInvariants -Report $Report
    if ($OutputDirectory -match '(?i)OneDrive' -or (Test-XboxOSCloudSynchronizedPath -Path $OutputDirectory)) {
        throw "Refusing to write m6e reports under a cloud-synchronized folder: $OutputDirectory"
    }
    if ($RepoRoot) {
        $null = Assert-XboxOSServicingPathSafety -Path $OutputDirectory -RepoRoot $RepoRoot -Purpose 'controlled live discovery reports'
    }
    if ($Stem -notmatch 'm6e') { throw 'Controlled live discovery reports must use an m6e stem.' }
    foreach ($f in @('m6d', 'm6c', 'm6b', 'm6a', '-m5', '-m4', '-m3', 'servicing-plan', 'DISM-Compatibility')) {
        if ($Stem -match [regex]::Escape($f)) { throw ("Refusing to overwrite prior baseline stem: {0}" -f $Stem) }
    }

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $suffix = if ($Report.evidence.runIdentity) { '-' + (ConvertTo-XboxOSSafeFileName -Name ([string]$Report.evidence.runIdentity)) } else { '' }
    $jsonPath = Join-Path $OutputDirectory ($Stem + $suffix + '.json')
    $mdPath = Join-Path $OutputDirectory ($Stem + $suffix + '.md')
    ($Report | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('# XboxOS11 Milestone 6E - Controlled Live Read-Only Host Discovery')
    [void]$lines.Add('')
    [void]$lines.Add(('Engine: `{0}` | Namespace: `m6e` | Decision: **{1}**' -f $Report.engineVersion, $Report.decision))
    [void]$lines.Add(('Observation provenance: `{0}`' -f $Report.evidence.observationProvenance))
    [void]$lines.Add('')
    [void]$lines.Add('| Condition | Value |')
    [void]$lines.Add('|-----------|-------|')
    foreach ($k in @('hostDiscoveryAuthorized', 'readOnlyHostInspectionCompleted', 'hypervisorObserved', 'networkIsolationVerified', 'labProvisioningAuthorized', 'writableServicingAuthorized')) {
        [void]$lines.Add(('| `{0}` | {1} |' -f $k, $Report.$k))
    }
    [void]$lines.Add('')
    [void]$lines.Add('## Commands')
    [void]$lines.Add('')
    [void]$lines.Add('| Operation | Status | Exit | Source |')
    [void]$lines.Add('|-----------|--------|------|--------|')
    foreach ($c in @($Report.evidence.commands)) {
        [void]$lines.Add(('| {0} | {1} | {2} | {3} |' -f $c.operationId, $c.status, $c.exitStatus, $c.observationSource))
    }
    [void]$lines.Add('')
    [void]$lines.Add('## Blockers')
    [void]$lines.Add('')
    foreach ($b in @($Report.blockers)) { [void]$lines.Add(('- {0}' -f $b)) }
    [void]$lines.Add('')
    [void]$lines.Add('Read-only inspection never authorizes lab provisioning or writable servicing.')
    ($lines -join "`n") + "`n" | Set-Content -LiteralPath $mdPath -Encoding UTF8
    return [pscustomobject]@{ JsonPath = $jsonPath; MarkdownPath = $mdPath }
}

#endregion
