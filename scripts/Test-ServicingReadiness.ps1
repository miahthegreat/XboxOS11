#Requires -Version 5.1
<#
.SYNOPSIS
    Milestone 5 servicing-readiness matrix (analysis only; non-mutating).
.DESCRIPTION
    Evaluates Eligible plan operations against curated dependency evidence and
    capability requirements. Never enables real DISM mutation or live mounts.

    Default mode requires an authoritative M1/M4 compat inventory JSON.
    Use -Simulation for explicit fixture-derived evaluation (cannot produce
    production ReadyForReview).
#>
[CmdletBinding()]
param(
    [string]$CompatJsonPath = 'C:\XboxOS\Logs\DISM-Compatibility-20261014-2.json',
    [string]$RepoRoot,
    [string]$OutputDirectory = 'C:\XboxOS\Logs',
    [string]$OutputStem = 'XboxOS11-servicing-readiness-m5',
    [string]$DependencyEvidencePath,
    [string]$CapabilityRequirementsPath,
    [switch]$Simulation
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
Import-Module $modulePath -Force

if (-not $RepoRoot) {
    $RepoRoot = Get-XboxOSRepoRoot
}

$null = Assert-XboxOSServicingPathSafety -Path $OutputDirectory -RepoRoot $RepoRoot -Purpose 'servicing readiness reports'

if (-not $DependencyEvidencePath) {
    $DependencyEvidencePath = Join-Path $RepoRoot 'config\dependency-evidence.json'
}
if (-not $CapabilityRequirementsPath) {
    $CapabilityRequirementsPath = Join-Path $RepoRoot 'config\capability-requirements.json'
}

Write-Host '=== XboxOS11 Milestone 5.1 servicing readiness (analysis only) ===' -ForegroundColor Cyan
Write-Host ("Engine: {0}" -f (Get-XboxOSServicingReadinessEngineVersion))
Write-Host ("Real DISM enabled: {0}" -f (Get-XboxOSRealDismExecutionEnabled))
Write-Host 'No modifying DISM commands will be invoked. No live mount/export.'
if ($Simulation) {
    Write-Host 'Mode: Simulation (fixture-derived inventory; not production evidence).' -ForegroundColor Yellow
}
else {
    Write-Host 'Mode: Authoritative inventory required.'
}

$removeApps = Import-XboxOSManifest -Path (Join-Path $RepoRoot 'config\remove-apps.json')
$disableFeatures = Import-XboxOSManifest -Path (Join-Path $RepoRoot 'config\disable-features.json')
$compatibility = Import-XboxOSManifest -Path (Join-Path $RepoRoot 'config\compatibility.json')
$depCatalog = Import-XboxOSDependencyEvidenceCatalog -Path $DependencyEvidencePath
$capCatalog = Import-XboxOSCapabilityRequirementsCatalog -Path $CapabilityRequirementsPath

$compatReport = $null
$inventoryProvenance = $null

if ($Simulation) {
    $fixtures = Join-Path $RepoRoot 'tests\Fixtures'
    $appx = @(
        ConvertFrom-XboxOSDismProvisionedAppxListOutput -Output (Get-Content (Join-Path $fixtures 'dism-get-appx-26300.9457.txt')) |
            ForEach-Object { $_.PackageName }
    )
    $features = @(ConvertFrom-XboxOSDismFeatureListOutput -Output (Get-Content (Join-Path $fixtures 'dism-get-features-26300.9457.txt')))
    $packages = @(ConvertFrom-XboxOSDismPackageListOutput -Output (Get-Content (Join-Path $fixtures 'dism-get-packages-26300.9457.txt')))
    $inventory = New-XboxOSInventorySnapshot `
        -AppxAvailability Available `
        -FeatureAvailability Available `
        -AppxPackages $appx `
        -Features $features `
        -Packages $packages `
        -Source 'tests/Fixtures/dism-get-*-26300.9457.txt' `
        -VerificationStatus Authoritative `
        -Notes @('FixtureDerived simulation inventory for planning only; readiness provenance remains FixtureDerived/Unverified.') `
        -SourceImage ([pscustomobject]@{
                editionName    = 'Windows 11 Pro'
                sourceIndex    = 6
                buildNumber    = '26300.9457'
                displayVersion = '26H2'
                isoSha256      = 'BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650'
                architecture   = $null
            })
    $compatReport = [pscustomobject]@{
        exportMeta      = @([pscustomobject]@{ Index = 1; Name = 'Windows 11 Pro'; Architecture = $null })
        sourceSelection = [pscustomobject]@{ Index = 6; Name = 'Windows 11 Pro'; Architecture = $null }
    }
    $inventoryProvenance = New-XboxOSInventoryProvenance `
        -SourceType FixtureDerived `
        -VerificationLevel Unverified `
        -SourcePath (Join-Path $fixtures 'dism-get-*-26300.9457.txt') `
        -FallbackMode Simulation `
        -Notes @('Explicit -Simulation mode. Fixture inputs cannot produce production ReadyForReview.')
}
elseif (Test-Path -LiteralPath $CompatJsonPath) {
    $inventory = Import-XboxOSInventoryFromCompatReport -Path $CompatJsonPath
    $compatReport = Get-Content -LiteralPath $CompatJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $verification = [string]$inventory.verificationStatus
    if ($verification -ne 'Authoritative') {
        throw ("Authoritative inventory required; compat report verificationStatus is '{0}'. Use -Simulation for fixture-driven tests." -f $verification)
    }
    $inventoryProvenance = New-XboxOSInventoryProvenance `
        -SourceType Authoritative `
        -VerificationLevel Authoritative `
        -SourcePath $CompatJsonPath `
        -FallbackMode None `
        -Notes @('Read-only M1/M4 compatibility inventory. Prior reports are never rewritten.')
}
else {
    throw ("Authoritative inventory not found: {0}. Provide a valid M1/M4 compat JSON or re-run with -Simulation for fixture-derived evaluation only." -f $CompatJsonPath)
}

$plan = New-XboxOSServicingPlan `
    -Inventory $inventory `
    -RemoveAppsManifest $removeApps `
    -DisableFeaturesManifest $disableFeatures `
    -CompatibilityManifest $compatibility

$assessment = New-XboxOSServicingReadinessAssessment `
    -Plan $plan `
    -Inventory $inventory `
    -CompatibilityManifest $compatibility `
    -EvidenceCatalog $depCatalog `
    -CapabilityCatalog $capCatalog `
    -CompatReport $compatReport `
    -InventoryProvenance $inventoryProvenance `
    -RepoRoot $RepoRoot

$paths = Save-XboxOSServicingReadinessReport `
    -Assessment $assessment `
    -OutputDirectory $OutputDirectory `
    -Stem $OutputStem `
    -RepoRoot $RepoRoot

Write-Host ''
Write-Host ("Decision:              {0}" -f $assessment.decision)
Write-Host ("Inventory source:      {0} ({1})" -f $assessment.inventoryProvenance.sourceType, $assessment.inventoryProvenance.verificationLevel)
Write-Host ("Catalog validation:    valid={0} errors={1}" -f $assessment.catalogValidation.valid, @($assessment.catalogValidation.errors).Count)
Write-Host ("Plan hash:             {0}" -f $assessment.planContentHash)
Write-Host ("Eligible ops:          {0}" -f $assessment.eligibleOperationCount)
Write-Host ("Architecture:          {0}" -f $assessment.sourceImage.architecture)
Write-Host ("Git commit:            {0}" -f $assessment.git.gitCommitSha)
Write-Host ("Execution authorized:  {0}" -f $assessment.executionAuthorized)
Write-Host ("Servicing authorized:  {0}" -f $assessment.servicingAuthorized)
Write-Host ("JSON:                  {0}" -f $paths.JsonPath)
Write-Host ("Markdown:              {0}" -f $paths.MarkdownPath)

if ($assessment.realDismExecutionEnabled -or $assessment.modifyingCommandsInvoked -or $assessment.executionAuthorized -or $assessment.servicingAuthorized) {
    throw 'Safety invariant violated: modifying/authorization flags must remain False.'
}

$eligible = @($assessment.operationAssessments | Where-Object planStatus -eq 'Eligible')
if ($eligible.Count -ne 8 -and $eligible.Count -gt 0) {
    Write-Warning ("Expected 8 Eligible operations for the M2 baseline inventory; observed {0}." -f $eligible.Count)
}

foreach ($a in $eligible) {
    $closure = if ($a.PSObject.Properties['dependencyClosure'] -and $a.dependencyClosure) { $a.dependencyClosure.completeness } else { 'n/a' }
    Write-Host ("  - {0} => {1} (closure={2})" -f $a.operationId, $a.readiness, $closure)
}

if ($assessment.decision -eq 'Blocked' -or $assessment.decision -eq 'Failed') {
    exit 2
}
exit 0
