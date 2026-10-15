#Requires -Version 7.0
<#
.SYNOPSIS
  Milestone 6E controlled live read-only host discovery CLI (default: HostDiscoveryBlocked).

.DESCRIPTION
  Without -ApprovalPath this script performs no host observation and emits a blocked m6e report (exit 2).

  With an approval it runs the Gate B pre-run checklist, then - only if every Gate A control passes - executes
  the typed, allowlisted, read-only observation operations exactly once for that run identity. Read-only
  inspection never authorizes lab provisioning or writable servicing.

  Exit codes: 0 = ReadOnlyHostInspectionCompleted, 2 = HostDiscoveryBlocked, 3 = DiscoveryAborted.
#>
[CmdletBinding()]
param(
    [string]$ApprovalPath = '',
    [string]$PublicKeyPemPath = '',
    [AllowEmptyString()][string]$OperatorAcknowledgment = '',
    [string]$ReplayStorePath = 'C:\XboxOS\Lab\Auth\used-approvals.jsonl',
    [string]$OutputDirectory = 'C:\XboxOS\Logs',
    [string]$WorkspaceRoot = 'C:\XboxOS\Lab\Work',
    [switch]$IncludeDismMountMetadata,
    [switch]$OperatorAcceptsElevatedSession,
    [switch]$ShowChecklistOnly
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Import-Module (Join-Path $repoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force

Write-Host 'XboxOS11 Controlled Live Read-Only Host Discovery (Milestone 6E)'
Write-Host ("Engine: {0}" -f (Get-XboxOSControlledLiveDiscoveryEngineVersion))

$allowlist = Import-XboxOSHostDiscoveryAllowlistCatalog -Path (Join-Path $repoRoot 'config\host-discovery-allowlist.json')
$scope = New-XboxOSHostDiscoveryScopeForRealHost -WorkspaceRoot $WorkspaceRoot -IncludeDismMountMetadata:$IncludeDismMountMetadata

function Exit-WithReport {
    param([object]$Report)
    $saved = Save-XboxOSControlledLiveDiscoveryReport -Report $Report -OutputDirectory $OutputDirectory -RepoRoot $repoRoot
    Write-Host ("Decision: {0}" -f $Report.decision)
    foreach ($b in @($Report.blockers)) { Write-Host ("  blocker: {0}" -f $b) -ForegroundColor Yellow }
    Write-Host ("Report: {0}" -f $saved.JsonPath)
    Write-Host 'Lab provisioning and writable servicing remain unauthorized.'
    switch ($Report.decision) {
        'ReadOnlyHostInspectionCompleted' { exit 0 }
        'DiscoveryAborted' { exit 3 }
        default { exit 2 }
    }
}

if (-not $ApprovalPath) {
    Write-Host 'No approval supplied: live discovery is blocked. No host commands were run.'
    $placeholder = New-XboxOSHostIdentity -HostLabel 'not-observed' -WindowsEdition 'Unknown' -BuildNumber 'Unknown' -Architecture 'Unknown'
    Exit-WithReport -Report (Invoke-XboxOSControlledLiveHostDiscovery -Allowlist $allowlist -HostIdentity $placeholder -DiscoveryScope $scope)
}

if (-not $PublicKeyPemPath) { throw '-PublicKeyPemPath (trusted operator public key) is required with -ApprovalPath.' }

# Gate B pre-run checklist. The environment check runs before any host observation.
$envCheck = Test-XboxOSControlledLiveExecutionEnvironment -OperatorAcceptsElevatedSession:$OperatorAcceptsElevatedSession
$approval = Import-XboxOSControlledLiveApproval -Path $ApprovalPath
$git = Get-XboxOSToolingGitVerificationState -RepoRoot $repoRoot
$store = New-XboxOSDurableReplayStore -Path $ReplayStorePath -RepoRoot $repoRoot
$storeState = Read-XboxOSDurableReplayStore -Store $store

Write-Host ''
Write-Host '== Pre-run checklist ==' -ForegroundColor Cyan
Write-Host ("1. Allowlisted read-only operations (categories approved: {0}):" -f (@($approval.approvedCategories) -join ', '))
$invokers = Get-XboxOSLiveReadOnlyInvokerMap
foreach ($op in @($allowlist.allowedOperations | Where-Object { @($approval.approvedCategories) -contains [string]$_.category })) {
    $gate = Test-XboxOSReadOnlyInvokerScript -ScriptBlock $invokers[[string]$op.operationId]
    Write-Host ("   - {0} [{1}] read-only gate: {2}" -f $op.operationId, $op.category, $(if ($gate.readOnly) { 'PASS' } else { 'FAIL' }))
}
Write-Host ("2. Approval host identity key: {0}" -f $approval.hostIdentityKey)
Write-Host ("3. Tooling Git: {0} ({1}); approval commit {2}" -f $git.gitCommitSha, $git.verificationState, $approval.gitCommitSha)
Write-Host ("4. Approval run {0}, expires {1:o}, key fingerprint {2}" -f $approval.runIdentity, $approval.expiresUtc, $approval.publicKeyFingerprint)
Write-Host ("5. Report destination: {0} (redaction applied); replay store: {1} [{2}]" -f $OutputDirectory, $store.path, $storeState.integrity)
Write-Host '6. Rollback is unnecessary: no modifying operations are reachable.'
Write-Host ("7. Execution environment: {0}{1}" -f $(if ($envCheck.allowed) { 'OK' } else { 'BLOCKED' }), $(if ($envCheck.elevated) { ' (elevated)' } else { ' (non-elevated)' }))
Write-Host ("   Required acknowledgment: '{0}'" -f (Get-XboxOSControlledLiveOperatorAcknowledgmentText -RunIdentity ([string]$approval.runIdentity)))
Write-Host ''

if ($ShowChecklistOnly) {
    Write-Host 'Checklist only: no host observation performed.'
    exit 2
}

$placeholder = New-XboxOSHostIdentity -HostLabel 'not-observed' -WindowsEdition 'Unknown' -BuildNumber 'Unknown' -Architecture 'Unknown'
if (-not $envCheck.allowed) {
    $r = Invoke-XboxOSControlledLiveHostDiscovery -Allowlist $allowlist -HostIdentity $placeholder -DiscoveryScope $scope
    $r.blockers = [string[]]@(@($envCheck.errors) + @($r.blockers))
    Exit-WithReport -Report $r
}

$hostId = New-XboxOSObservedHostIdentity
$report = Invoke-XboxOSControlledLiveHostDiscovery -Allowlist $allowlist -HostIdentity $hostId -DiscoveryScope $scope `
    -Approval $approval -PublicKeyPemPath $PublicKeyPemPath -ReplayStore $store -OperatorAcknowledgment $OperatorAcknowledgment `
    -ToolingGitState $git -RepoRoot $repoRoot -ExecutionEnvironment $envCheck -OperatorAcceptsElevatedSession:$OperatorAcceptsElevatedSession
Exit-WithReport -Report $report
