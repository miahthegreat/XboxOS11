#Requires -Version 5.1
<#
.SYNOPSIS
    Milestone 6C read-only host/hypervisor lab discovery (simulation / mocks only).
.DESCRIPTION
    Default: non-elevated, simulation-only, no automatic approval, decision HostDiscoveryBlocked.
    Does not enumerate the real host, invoke Hyper-V management against the live system,
    provision infrastructure, or mutate Windows images.
    Fixture simulation with a mocked HostDiscovery approval uses -Simulation -AllowMockedApproval.
#>
[CmdletBinding()]
param(
    [string]$AllowlistPath,
    [string]$RepoRoot,
    [string]$OutputDirectory = 'C:\XboxOS\Logs',
    [string]$OutputStem = 'XboxOS11-host-lab-discovery-m6c',
    [string]$OperatorId = 'host-discovery-sim-operator',
    [string]$ProposedSwitchName = 'IsolatedSwitch',
    [string]$WorkspaceRoot = 'C:\XboxOS\Lab\Work',
    [switch]$Simulation,
    [switch]$AllowMockedApproval,
    [switch]$SimulateHyperVUnavailable
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
Import-Module $modulePath -Force

if (-not $RepoRoot) { $RepoRoot = Get-XboxOSRepoRoot }
$null = Assert-XboxOSServicingPathSafety -Path $OutputDirectory -RepoRoot $RepoRoot -Purpose 'host discovery reports'

if (-not $AllowlistPath) {
    $AllowlistPath = Join-Path $RepoRoot 'config\host-discovery-allowlist.json'
}

if ($AllowMockedApproval -and -not $Simulation) {
    throw '-AllowMockedApproval requires -Simulation and never authorizes real-host inspection.'
}

Write-Host '=== XboxOS11 Milestone 6C host lab discovery (simulation only) ===' -ForegroundColor Cyan
Write-Host ("Engine: {0}" -f (Get-XboxOSHostDiscoveryEngineVersion))
Write-Host ("Real DISM enabled: {0}" -f (Get-XboxOSRealDismExecutionEnabled))
Write-Host ("Lab real provisioning: {0}" -f (Get-XboxOSLabRealProvisioningEnabled))
Write-Host ("Real host commands invoked: {0}" -f (Get-XboxOSHostDiscoveryRealHostCommandsInvoked))
Write-Host ("Layer D / experimental execution: {0} / {1}" -f $false, (Get-XboxOSExperimentalExecutionAuthorized))
Write-Host 'No real host enumeration, Hyper-V provisioning, or DISM mutation will be performed.'

$allowlist = Import-XboxOSHostDiscoveryAllowlistCatalog -Path $AllowlistPath
$hostIdentity = New-XboxOSHostIdentity -Fixture
$scope = New-XboxOSHostDiscoveryScope -ProposedSwitchName $ProposedSwitchName -WorkspaceRoot $WorkspaceRoot
$git = Get-XboxOSReportTraceability -RepoRoot $RepoRoot
$gitSha = if ($git.PSObject.Properties['gitCommitSha'] -and $git.gitCommitSha -and $git.gitCommitSha -ne 'Unknown') {
    [string]$git.gitCommitSha
}
else {
    'fixture-git-sha-for-simulation'
}

Reset-XboxOSHostDiscoveryNonceRegistry
$approval = $null

if ($Simulation -and $AllowMockedApproval) {
    Write-Host 'Mode: Explicit mocked HostDiscovery approval (fixture simulation).' -ForegroundColor Yellow
    $approval = New-XboxOSHostDiscoveryApprovalRecord `
        -OperatorId $OperatorId `
        -HostIdentity $hostIdentity `
        -DiscoveryScope $scope `
        -GitCommitSha $gitSha `
        -ApprovedCategories @($scope.categories) `
        -ReadOnlyAcknowledged
}
else {
    Write-Host 'Mode: Default blocked — no HostDiscovery approval supplied.'
}

$report = Invoke-XboxOSHostLabDiscoverySimulate `
    -Allowlist $allowlist `
    -HostIdentity $hostIdentity `
    -DiscoveryScope $scope `
    -Approval $approval `
    -RepoRoot $RepoRoot `
    -ExpectedGitCommitSha $gitSha `
    -ProposedSwitchName $ProposedSwitchName `
    -WorkspaceRoot $WorkspaceRoot `
    -SimulateHyperVUnavailable:$SimulateHyperVUnavailable

$paths = Save-XboxOSHostLabDiscoveryReport -Report $report -OutputDirectory $OutputDirectory -Stem $OutputStem -RepoRoot $RepoRoot

Write-Host ''
Write-Host ("Decision:                    {0}" -f $report.decision)
Write-Host ("Transaction state:           {0}" -f $report.transactionState)
Write-Host ("Approval valid:              {0}" -f $report.approvalValid)
Write-Host ("Adapter mode:                {0}" -f $report.adapterMode)
Write-Host ("Actual isolation verified:   {0}" -f $report.isolation.actualIsolationVerified)
Write-Host ("Network isolation status:    {0}" -f $report.isolation.networkIsolationVerificationStatus)
Write-Host ("VM inventory availability:   {0}" -f $report.vmInventory.availability)
Write-Host ("Real host commands invoked:  {0}" -f $report.hostDiscoveryRealHostCommandsInvoked)
Write-Host ("Layer D activated:           {0}" -f $report.layerDActivated)
Write-Host ("JSON:                        {0}" -f $paths.JsonPath)
Write-Host ("Markdown:                    {0}" -f $paths.MarkdownPath)

Assert-XboxOSHostDiscoverySafetyInvariants -Report $report
if ($report.decision -notin @('HostDiscoveryBlocked', 'RecoveryRequired')) {
    throw 'Safety invariant violated: Milestone 6C must not authorize real-host inspection.'
}
if ($report.isolation.actualIsolationVerified) {
    throw 'Safety invariant violated: mock discovery must not claim ActualIsolationVerified=True.'
}
exit 2
