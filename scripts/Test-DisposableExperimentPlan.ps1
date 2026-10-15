#Requires -Version 5.1
<#
.SYNOPSIS
    Milestone 6A disposable-image experiment planning and authorization simulation.
.DESCRIPTION
    Builds a bound experiment plan from authoritative inventory + M5 readiness,
    evaluates allowlists, simulates operator/risk records, and always ends
    BlockedForExecution. Never enables writable DISM or creates/mounts a WIM.
#>
[CmdletBinding()]
param(
    [string]$CompatJsonPath = 'C:\XboxOS\Logs\DISM-Compatibility-20261014-2.json',
    [string]$ReadinessJsonPath = 'C:\XboxOS\Logs\XboxOS11-servicing-readiness-m5.json',
    [string]$RepoRoot,
    [string]$OutputDirectory = 'C:\XboxOS\Logs',
    [string]$OutputStem = 'XboxOS11-experiment-plan-m6a',
    [string]$OperatorId = 'sim-operator',
    [string]$ProposedWorkspaceRoot = 'C:\XboxOS\Work\experiment-m6a-sim',
    [string]$FunctionalValidationPath,
    [switch]$Simulation,
    [switch]$SkipOperatorConsent,
    [switch]$SkipRiskAcceptance
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
Import-Module $modulePath -Force

if (-not $RepoRoot) {
    $RepoRoot = Get-XboxOSRepoRoot
}

$null = Assert-XboxOSServicingPathSafety -Path $OutputDirectory -RepoRoot $RepoRoot -Purpose 'experiment plan reports'

if (-not $FunctionalValidationPath) {
    $FunctionalValidationPath = Join-Path $RepoRoot 'config\functional-validation-matrix.json'
}

Write-Host '=== XboxOS11 Milestone 6A experiment planning (simulation only) ===' -ForegroundColor Cyan
Write-Host ("Engine: {0}" -f (Get-XboxOSExperimentPlanEngineVersion))
Write-Host ("Real DISM enabled: {0}" -f (Get-XboxOSRealDismExecutionEnabled))
Write-Host ("Experimental mutation enabled: {0}" -f (Get-XboxOSExperimentalMutationEnabled))
Write-Host 'No modifying DISM commands will be invoked. No WIM create/mount.'

$removeApps = Import-XboxOSManifest -Path (Join-Path $RepoRoot 'config\remove-apps.json')
$disableFeatures = Import-XboxOSManifest -Path (Join-Path $RepoRoot 'config\disable-features.json')
$compatibility = Import-XboxOSManifest -Path (Join-Path $RepoRoot 'config\compatibility.json')
$depCatalog = Import-XboxOSDependencyEvidenceCatalog -Path (Join-Path $RepoRoot 'config\dependency-evidence.json')
$capCatalog = Import-XboxOSCapabilityRequirementsCatalog -Path (Join-Path $RepoRoot 'config\capability-requirements.json')
$fvCatalog = Import-XboxOSFunctionalValidationCatalog -Path $FunctionalValidationPath

$compatReport = $null
$inventoryProvenance = $null
$readinessPathUsed = $ReadinessJsonPath

if ($Simulation) {
    Write-Host 'Mode: Simulation (fixture-derived inventory).' -ForegroundColor Yellow
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
        -Notes @('FixtureDerived simulation inventory for M6A planning only.') `
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
        -Notes @('Explicit -Simulation mode for M6A.')
    $readinessPathUsed = '(inline-simulation-readiness)'
}
elseif (Test-Path -LiteralPath $CompatJsonPath) {
    $inventory = Import-XboxOSInventoryFromCompatReport -Path $CompatJsonPath
    $compatReport = Get-Content -LiteralPath $CompatJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$inventory.verificationStatus -ne 'Authoritative') {
        throw ("Authoritative inventory required; got '{0}'. Use -Simulation for fixtures." -f $inventory.verificationStatus)
    }
    $inventoryProvenance = New-XboxOSInventoryProvenance `
        -SourceType Authoritative `
        -VerificationLevel Authoritative `
        -SourcePath $CompatJsonPath `
        -FallbackMode None `
        -Notes @('Authoritative M1/M4 compatibility inventory.')
}
else {
    throw ("Authoritative inventory not found: {0}. Use -Simulation for fixture-derived evaluation." -f $CompatJsonPath)
}

$plan = New-XboxOSServicingPlan `
    -Inventory $inventory `
    -RemoveAppsManifest $removeApps `
    -DisableFeaturesManifest $disableFeatures `
    -CompatibilityManifest $compatibility

# Prefer live M5 report when present and hashes match; otherwise build inline assessment.
$readiness = $null
if (-not $Simulation -and (Test-Path -LiteralPath $ReadinessJsonPath)) {
    $readyFile = Get-Content -LiteralPath $ReadinessJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$readyFile.planContentHash -eq [string]$plan.contentHash -and
        [string]$readyFile.inventoryFingerprint -eq [string]$plan.inventoryFingerprint) {
        $readiness = $readyFile
        Write-Host ("Bound M5 readiness report: {0}" -f $ReadinessJsonPath)
    }
    else {
        Write-Warning 'Existing M5 readiness report hash mismatch; rebuilding inline assessment.'
        $readinessPathUsed = '(inline-rebuilt-readiness)'
    }
}

if ($null -eq $readiness) {
    $readiness = New-XboxOSServicingReadinessAssessment `
        -Plan $plan `
        -Inventory $inventory `
        -CompatibilityManifest $compatibility `
        -EvidenceCatalog $depCatalog `
        -CapabilityCatalog $capCatalog `
        -CompatReport $compatReport `
        -InventoryProvenance $inventoryProvenance `
        -RepoRoot $RepoRoot
}

$eligibleIds = @(
    $readiness.operationAssessments |
        Where-Object { $_.planStatus -eq 'Eligible' } |
        ForEach-Object { [string]$_.operationId }
)

if ($eligibleIds.Count -eq 0) {
    throw 'No Eligible operations found to plan.'
}

$keys = Join-Path $RepoRoot 'tests\Fixtures\approval-auth'
$priv = Join-Path $keys 'test-approval-private.pem'
$pub = Join-Path $keys 'test-approval-public.pem'
if (-not (Test-Path -LiteralPath $priv)) { $priv = $null }
if (-not (Test-Path -LiteralPath $pub)) { $pub = $null }

Reset-XboxOSExperimentNonceRegistry

$report = Invoke-XboxOSExperimentPlanSimulate `
    -Plan $plan `
    -ReadinessAssessment $readiness `
    -RequestedOperationIds $eligibleIds `
    -FunctionalValidationCatalog $fvCatalog `
    -RepoRoot $RepoRoot `
    -OperatorId $OperatorId `
    -ProposedWorkspaceRoot $ProposedWorkspaceRoot `
    -ReadinessReportPath $readinessPathUsed `
    -PrivateKeyPemPath $priv `
    -PublicKeyPemPath $pub `
    -SimulateOperatorConsent:(-not $SkipOperatorConsent) `
    -SimulateRiskAcceptance:(-not $SkipRiskAcceptance)

$paths = Save-XboxOSExperimentPlanReport `
    -Report $report `
    -OutputDirectory $OutputDirectory `
    -Stem $OutputStem `
    -RepoRoot $RepoRoot

Write-Host ''
Write-Host ("Decision:                 {0}" -f $report.decision)
Write-Host ("Transaction state:        {0}" -f $report.transactionState)
if ($report.experimentPlan) {
    Write-Host ("Experiment id:            {0}" -f $report.experimentPlan.experimentId)
    Write-Host ("Experiment content hash:  {0}" -f $report.experimentPlan.contentHash)
    Write-Host ("Planned operations:       {0}" -f @($report.experimentPlan.operations).Count)
}
Write-Host ("Execution authorized:     {0}" -f $report.executionAuthorized)
Write-Host ("Experimental mutation:    {0}" -f $report.experimentalMutationEnabled)
Write-Host ("JSON:                     {0}" -f $paths.JsonPath)
Write-Host ("Markdown:                 {0}" -f $paths.MarkdownPath)

Assert-XboxOSExperimentSafetyInvariants -Report $report

if ($report.decision -ne 'BlockedForExecution') {
    throw 'Safety invariant violated: Milestone 6A decision must be BlockedForExecution.'
}

exit 2
