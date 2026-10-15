#Requires -Version 5.1
<#
.SYNOPSIS
    Milestone 4 disposable-image preflight (simulation by default).
.DESCRIPTION
    Default Mode=Simulation uses mocks/fixtures only — no admin, no live mounts.
    LiveReadOnly mode is gated and disabled until explicit post-review operator authorization.
#>
[CmdletBinding()]
param(
    [ValidateSet('Simulation', 'LiveReadOnly')]
    [string]$Mode = 'Simulation',

    [string]$CompatJsonPath = 'C:\XboxOS\Logs\DISM-Compatibility-20261014-2.json',
    [string]$IsoPath = 'C:\XboxOS\Sources\Windows11_Client_x64_en-us_26300_9457.iso',
    [string]$WorkRoot = 'C:\XboxOS\Work',
    [string]$OutputDirectory = 'C:\XboxOS\Logs',
    [string]$OutputStem = 'XboxOS11-disposable-preflight-m4',
    [string]$RepoRoot,
    [ValidateSet('Success', 'ExportInterrupted', 'MountFailed', 'UnmountFailed', 'CorruptWim', 'VersionProbeFailed')]
    [string]$FailureMode = 'Success',

    [switch]$ConfirmLiveReadOnlyPreflight,
    [switch]$AllowLiveReadOnlyPreflight
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
Import-Module $modulePath -Force

if (-not $RepoRoot) { $RepoRoot = Get-XboxOSRepoRoot }
$null = Assert-XboxOSServicingPathSafety -Path $OutputDirectory -RepoRoot $RepoRoot -Purpose 'preflight reports'

Write-Host '=== XboxOS11 Milestone 4 disposable-image preflight ===' -ForegroundColor Cyan
Write-Host ("Engine: {0}" -f (Get-XboxOSPreflightEngineVersion))
Write-Host ("Mode:   {0}" -f $Mode)
Write-Host ("Real DISM enabled: {0}" -f (Get-XboxOSRealDismExecutionEnabled))

if ($Mode -eq 'LiveReadOnly') {
    Assert-XboxOSLiveReadOnlyPreflightAuthorization `
        -ConfirmLiveReadOnlyPreflight:$ConfirmLiveReadOnlyPreflight `
        -AllowLiveReadOnlyPreflight:$AllowLiveReadOnlyPreflight
    throw 'Live read-only preflight authorization checks passed structural gates, but live execution is not enabled in this delivery. Awaiting explicit operator approval after review.'
}

# Simulation path — fixtures/mocks only.
$removeApps = Import-XboxOSManifest -Path (Join-Path $RepoRoot 'config\remove-apps.json')
$disableFeatures = Import-XboxOSManifest -Path (Join-Path $RepoRoot 'config\disable-features.json')
$compatibility = Import-XboxOSManifest -Path (Join-Path $RepoRoot 'config\compatibility.json')

$fixtures = Join-Path $RepoRoot 'tests\Fixtures'
$appx = @(ConvertFrom-XboxOSDismProvisionedAppxListOutput -Output (Get-Content (Join-Path $fixtures 'dism-get-appx-26300.9457.txt')) | ForEach-Object { $_.PackageName })
$features = @(ConvertFrom-XboxOSDismFeatureListOutput -Output (Get-Content (Join-Path $fixtures 'dism-get-features-26300.9457.txt')))
$baseline = New-XboxOSInventorySnapshot `
    -AppxAvailability Available `
    -FeatureAvailability Available `
    -AppxPackages $appx `
    -Features $features `
    -Source 'tests/Fixtures' `
    -VerificationStatus Authoritative `
    -SourceImage ([pscustomobject]@{
        editionName    = 'Windows 11 Pro'
        sourceIndex    = 6
        buildNumber    = '26300.9457'
        displayVersion = '26H2'
        isoSha256      = (Get-XboxOSExpectedSourceIsoSha256)
    })

if ((Test-Path -LiteralPath $CompatJsonPath)) {
    try {
        $imported = Import-XboxOSInventoryFromCompatReport -Path $CompatJsonPath
        if ($imported.verificationStatus -eq 'Authoritative') {
            $baseline = $imported
            Write-Host ("Using Authoritative M1 inventory: {0}" -f $CompatJsonPath)
        }
    }
    catch {
        Write-Host ("Compat import skipped: {0}" -f $_.Exception.Message)
    }
}

$plan = New-XboxOSServicingPlan `
    -Inventory $baseline `
    -RemoveAppsManifest $removeApps `
    -DisableFeaturesManifest $disableFeatures `
    -CompatibilityManifest $compatibility

$adapter = New-XboxOSMockReadOnlyDismAdapter -FailureMode $FailureMode -FixtureRoot $fixtures
$preflight = New-XboxOSDisposableImagePreflight `
    -Plan $plan `
    -BaselineInventory $baseline `
    -CompatibilityManifest $compatibility `
    -Adapter $adapter `
    -Mode Simulation `
    -IsoPath $IsoPath `
    -WorkRoot $WorkRoot `
    -LogsRoot $OutputDirectory

$preflight = Invoke-XboxOSDisposableImagePreflightSimulate -Preflight $preflight
$paths = Save-XboxOSDisposableImagePreflightReport -Preflight $preflight -OutputDirectory $OutputDirectory -Stem $OutputStem

Write-Host ''
Write-Host ("State:      {0}" -f $preflight.transactionState)
Write-Host ("Decision:   {0}" -f $preflight.preflightDecision)
Write-Host ("Cleanup:    {0}" -f $preflight.cleanupStatus)
Write-Host ("ExecAuth:   {0}" -f $preflight.executionAuthorized)
Write-Host ("Modifying:  {0}" -f $preflight.modifyingCommandsInvoked)
Write-Host ("RealDISM:   {0}" -f $preflight.realDismExecutionEnabled)
Write-Host ("JSON:       {0}" -f $paths.Json)
Write-Host ("Markdown:   {0}" -f $paths.Markdown)

if ($preflight.modifyingCommandsInvoked -or $preflight.realDismExecutionEnabled -or $preflight.executionAuthorized) {
    throw 'Safety violation in preflight simulation.'
}

$exit = if ($preflight.cleanupStatus -eq 'Succeeded' -and $preflight.transactionState -eq 'Completed') { 0 } else { 2 }
exit $exit
