#Requires -Version 5.1
<#
.SYNOPSIS
    Generate a Milestone 2 dry-run servicing plan from captured inventory.
.DESCRIPTION
    Plan-only. Never mounts images, never runs modifying DISM, never commits.
    Default inventory source is the preserved Milestone 1 compatibility JSON.
#>
[CmdletBinding()]
param(
    [string]$CompatJsonPath = 'C:\XboxOS\Logs\DISM-Compatibility-20261014-2.json',
    [string]$RepoRoot,
    [string]$OutputDirectory = 'C:\XboxOS\Logs',
    [string]$OutputStem = 'XboxOS11-servicing-plan-m2',
    [switch]$IncludeDisabledManifestCandidates
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
Import-Module $modulePath -Force

if (-not $RepoRoot) {
    $RepoRoot = Get-XboxOSRepoRoot
}

$null = Assert-XboxOSServicingPathSafety -Path $OutputDirectory -RepoRoot $RepoRoot -Purpose 'servicing plan reports'

Write-Host '=== XboxOS11 Milestone 2 servicing plan (dry-run) ===' -ForegroundColor Cyan
Write-Host ("Engine version: {0}" -f (Get-XboxOSServicingPlanEngineVersion))
Write-Host ("Inventory: {0}" -f $CompatJsonPath)
Write-Host 'Modifying DISM commands will not be invoked.'

$inventory = Import-XboxOSInventoryFromCompatReport -Path $CompatJsonPath
$removeApps = Import-XboxOSManifest -Path (Join-Path $RepoRoot 'config\remove-apps.json')
$disableFeatures = Import-XboxOSManifest -Path (Join-Path $RepoRoot 'config\disable-features.json')
$compatibility = Import-XboxOSManifest -Path (Join-Path $RepoRoot 'config\compatibility.json')

$schemaRemove = Test-XboxOSManifestSchema -Configuration $removeApps -ManifestType 'remove-apps'
$schemaDisable = Test-XboxOSManifestSchema -Configuration $disableFeatures -ManifestType 'disable-features'
$schemaCompat = Test-XboxOSManifestSchema -Configuration $compatibility -ManifestType 'compatibility'
foreach ($schema in @($schemaRemove, $schemaDisable, $schemaCompat)) {
    if (-not $schema.Valid) {
        throw ("Manifest schema validation failed:`n - " + ($schema.Errors -join "`n - "))
    }
}

$plan = New-XboxOSServicingPlan `
    -Inventory $inventory `
    -RemoveAppsManifest $removeApps `
    -DisableFeaturesManifest $disableFeatures `
    -CompatibilityManifest $compatibility `
    -IncludeDisabledManifestCandidates:$IncludeDisabledManifestCandidates

$paths = Save-XboxOSServicingPlanReport -Plan $plan -OutputDirectory $OutputDirectory -Stem $OutputStem

Write-Host ''
Write-Host ("Plan ID:        {0}" -f $plan.planId)
Write-Host ("Approval gate:  {0}" -f $plan.approvalGate)
Write-Host ("Content hash:   {0}" -f $plan.contentHash)
Write-Host ("Eligible:       {0}" -f $plan.summary.Eligible)
Write-Host ("AlreadySatisfied:{0}" -f $plan.summary.AlreadySatisfied)
Write-Host ("Protected:      {0}" -f $plan.summary.Protected)
Write-Host ("Ambiguous:      {0}" -f $plan.summary.Ambiguous)
Write-Host ("Conflicting:    {0}" -f $plan.summary.Conflicting)
Write-Host ("NotEvaluated:   {0}" -f $plan.summary.NotEvaluated)
Write-Host ("JSON:           {0}" -f $paths.Json)
Write-Host ("Markdown:       {0}" -f $paths.Markdown)
Write-Host ("ModifyingCmds:  {0}" -f $plan.modifyingCommandsInvoked)

if ($plan.modifyingCommandsInvoked) {
    throw 'Safety violation: plan generation reported modifying commands.'
}

$exitCode = if ($plan.approvalGate -eq 'Blocked') { 2 } else { 0 }
exit $exitCode
