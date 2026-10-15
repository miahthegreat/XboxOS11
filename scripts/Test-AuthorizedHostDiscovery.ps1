#Requires -Version 5.1
<#
.SYNOPSIS
  Milestone 6D authorized host-discovery CLI (default: HostDiscoveryBlocked).

.DESCRIPTION
  Never activates live host inspection. Optional -Simulation with -AllowMockedAuthorizedApproval
  exercises the mocked authorized path only. Exit code 2 indicates blocked live inspection (expected).
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory = 'C:\XboxOS\Logs',
    [string]$RepoRoot = '',
    [string]$AllowlistPath = '',
    [switch]$Simulation,
    [switch]$AllowMockedAuthorizedApproval,
    [string]$Stem = 'XboxOS11-host-lab-discovery-m6d'
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}
Import-Module (Join-Path $RepoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force

Write-Host "XboxOS11 Authorized Host Discovery (Milestone 6D)"
Write-Host ("Engine: {0}" -f (Get-XboxOSAuthorizedHostDiscoveryEngineVersion))
Write-Host ("Live activation enabled: {0}" -f (Get-XboxOSAuthorizedHostDiscoveryLiveActivationEnabled))
Write-Host ("Real host commands invoked: {0}" -f (Get-XboxOSHostDiscoveryRealHostCommandsInvoked))
Write-Host 'Default decision path: HostDiscoveryBlocked (live inspection unauthorized).'

if ($Simulation -xor $AllowMockedAuthorizedApproval) {
    throw '-Simulation and -AllowMockedAuthorizedApproval must be used together; this never authorizes live host inspection.'
}

if (-not $AllowlistPath) {
    $AllowlistPath = Join-Path $RepoRoot 'config\host-discovery-allowlist.json'
}
$allowlist = Import-XboxOSHostDiscoveryAllowlistCatalog -Path $AllowlistPath
Initialize-XboxOSAuthorizedHostDiscoveryTestKeyFingerprints -RepoRoot $RepoRoot
Reset-XboxOSAuthorizedHostDiscoveryNonceRegistry

$hostId = New-XboxOSHostIdentity -Fixture -HostLabel 'cli-fixture-host'
$scope = New-XboxOSHostDiscoveryScopeForRealHost
$approval = $null
$gitSha = 'fixture-git-sha-for-authorized-simulation'
$pub = Join-Path $RepoRoot 'tests\Fixtures\approval-auth\test-approval-public.pem'
$priv = Join-Path $RepoRoot 'tests\Fixtures\approval-auth\test-approval-private.pem'

if ($Simulation -and $AllowMockedAuthorizedApproval) {
    Write-Host 'Mode: mocked authorized approval simulation (not live host inspection).'
    $approval = New-XboxOSAuthorizedHostDiscoveryApprovalRecord `
        -OperatorId 'cli-simulation-operator' `
        -HostIdentity $hostId `
        -DiscoveryScope $scope `
        -GitCommitSha $gitSha `
        -ApprovedCategories @($scope.categories) `
        -RunIdentity ('cli-run-' + [guid]::NewGuid().ToString('N')) `
        -PrivateKeyPemPath $priv `
        -PublicKeyPemPath $pub `
        -ReadOnlyAcknowledged `
        -AllowTestKeyForSimulationOnly
}

$report = Invoke-XboxOSAuthorizedHostDiscoverySimulate `
    -Allowlist $allowlist `
    -HostIdentity $hostId `
    -DiscoveryScope $scope `
    -Approval $approval `
    -RepoRoot $RepoRoot `
    -ExpectedGitCommitSha $gitSha `
    -PublicKeyPemPath $pub `
    -AllowSimulationTestKey:$([bool]$approval)

Assert-XboxOSAuthorizedHostDiscoverySafetyInvariants -Report $report
if ([bool]$report.isolation.actualIsolationVerified) {
    throw 'Safety violation: CLI mock path must not set ActualIsolationVerified=True.'
}
if ($report.decision -notin @('HostDiscoveryBlocked', 'RecoveryRequired')) {
    throw ("Unexpected decision '{0}'." -f $report.decision)
}

$saved = Save-XboxOSAuthorizedHostDiscoveryReport -Report $report -OutputDirectory $OutputDirectory -Stem $Stem -RepoRoot $RepoRoot
Write-Host ("Decision: {0}" -f $report.decision)
Write-Host ("Report: {0}" -f $saved.JsonPath)
Write-Host 'Live host inspection was not performed.'
exit 2
