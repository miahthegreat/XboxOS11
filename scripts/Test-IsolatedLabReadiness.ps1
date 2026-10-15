#Requires -Version 5.1
<#
.SYNOPSIS
    Milestone 6B isolated disposable-image lab infrastructure readiness (simulation only).
.DESCRIPTION
    Validates lab topology, isolation policy, ownership/snapshots, authorization key policy,
    and evidence custody against M5/M6A bindings. Always blocks real provisioning and Layer D.
    Does not invoke DISM or hypervisor provisioning commands.
#>
[CmdletBinding()]
param(
    [string]$CompatJsonPath = 'C:\XboxOS\Logs\DISM-Compatibility-20261014-2.json',
    [string]$ReadinessJsonPath = 'C:\XboxOS\Logs\XboxOS11-servicing-readiness-m5.json',
    [string]$ExperimentPlanJsonPath = 'C:\XboxOS\Logs\XboxOS11-experiment-plan-m6a-auth.json',
    [string]$LabTopologyPath,
    [string]$RepoRoot,
    [string]$OutputDirectory = 'C:\XboxOS\Logs',
    [string]$OutputStem = 'XboxOS11-isolated-lab-m6b',
    [string]$OperatorId = 'lab-sim-operator',
    [switch]$Simulation,
    [switch]$AllowInlineSimulationReadiness,
    [switch]$SkipOperatorReview
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
Import-Module $modulePath -Force

if (-not $RepoRoot) { $RepoRoot = Get-XboxOSRepoRoot }
$null = Assert-XboxOSServicingPathSafety -Path $OutputDirectory -RepoRoot $RepoRoot -Purpose 'isolated lab reports'

if (-not $LabTopologyPath) {
    $LabTopologyPath = Join-Path $RepoRoot 'config\lab-topology.json'
}

Write-Host '=== XboxOS11 Milestone 6B isolated lab readiness (simulation only) ===' -ForegroundColor Cyan
Write-Host ("Engine: {0}" -f (Get-XboxOSIsolatedLabEngineVersion))
Write-Host ("Real DISM enabled: {0}" -f (Get-XboxOSRealDismExecutionEnabled))
Write-Host ("Lab real provisioning: {0}" -f (Get-XboxOSLabRealProvisioningEnabled))
Write-Host ("Layer D / experimental execution: {0} / {1}" -f $false, (Get-XboxOSExperimentalExecutionAuthorized))
Write-Host 'No DISM or hypervisor provisioning commands will be invoked.'

$topology = Import-XboxOSLabTopologyCatalog -Path $LabTopologyPath
$fvCatalog = Import-XboxOSFunctionalValidationCatalog -Path (Join-Path $RepoRoot 'config\functional-validation-matrix.json')
$compatibility = Import-XboxOSManifest -Path (Join-Path $RepoRoot 'config\compatibility.json')
$removeApps = Import-XboxOSManifest -Path (Join-Path $RepoRoot 'config\remove-apps.json')
$disableFeatures = Import-XboxOSManifest -Path (Join-Path $RepoRoot 'config\disable-features.json')

# Resolve plan hash + readiness binding digest from M6A/M5 evidence
$planHash = $null
$readinessDigest = $null
$isoSha = $null
$experimentPlanHash = ''

if ((-not $Simulation) -and (Test-Path -LiteralPath $ExperimentPlanJsonPath)) {
    $exp = Get-Content -LiteralPath $ExperimentPlanJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($exp.PSObject.Properties['experimentPlan'] -and $exp.experimentPlan) {
        $planHash = [string]$exp.experimentPlan.servicingPlanContentHash
        $isoSha = [string]$exp.experimentPlan.sourceIsoSha256
        $experimentPlanHash = [string]$exp.experimentPlan.contentHash
    }
    if ($exp.PSObject.Properties['readinessBindingDigest']) {
        $readinessDigest = [string]$exp.readinessBindingDigest
    }
    Write-Host ("Bound M6A experiment report: {0}" -f $ExperimentPlanJsonPath)
}

if (-not $planHash -or -not $readinessDigest -or -not $isoSha) {
    if (-not $Simulation -or -not $AllowInlineSimulationReadiness) {
        throw 'Validated M6A/M5 evidence bindings required. Provide experiment plan JSON or use -Simulation -AllowInlineSimulationReadiness.'
    }
    Write-Host 'Mode: Explicit inline simulation bindings (fixtures).' -ForegroundColor Yellow
    $fixtures = Join-Path $RepoRoot 'tests\Fixtures'
    $appx = @(ConvertFrom-XboxOSDismProvisionedAppxListOutput -Output (Get-Content (Join-Path $fixtures 'dism-get-appx-26300.9457.txt')) | ForEach-Object { $_.PackageName })
    $features = @(ConvertFrom-XboxOSDismFeatureListOutput -Output (Get-Content (Join-Path $fixtures 'dism-get-features-26300.9457.txt')))
    $packages = @(ConvertFrom-XboxOSDismPackageListOutput -Output (Get-Content (Join-Path $fixtures 'dism-get-packages-26300.9457.txt')))
    $inventory = New-XboxOSInventorySnapshot `
        -AppxAvailability Available -FeatureAvailability Available `
        -AppxPackages $appx -Features $features -Packages $packages `
        -Source 'tests/Fixtures' -VerificationStatus Authoritative `
        -SourceImage ([pscustomobject]@{
                editionName = 'Windows 11 Pro'; sourceIndex = 6; buildNumber = '26300.9457'
                displayVersion = '26H2'; isoSha256 = 'BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650'
            })
    $plan = New-XboxOSServicingPlan -Inventory $inventory -RemoveAppsManifest $removeApps -DisableFeaturesManifest $disableFeatures -CompatibilityManifest $compatibility
    $ready = New-XboxOSServicingReadinessAssessment `
        -Plan $plan -Inventory $inventory -CompatibilityManifest $compatibility `
        -EvidenceCatalog (Import-XboxOSDependencyEvidenceCatalog -Path (Join-Path $RepoRoot 'config\dependency-evidence.json')) `
        -CapabilityCatalog (Import-XboxOSCapabilityRequirementsCatalog -Path (Join-Path $RepoRoot 'config\capability-requirements.json')) `
        -CompatReport ([pscustomobject]@{ exportMeta = @([pscustomobject]@{ Index = 1; Name = 'Windows 11 Pro'; Architecture = $null }); sourceSelection = [pscustomobject]@{ Index = 6; Name = 'Windows 11 Pro'; Architecture = $null } }) `
        -InventoryProvenance (New-XboxOSInventoryProvenance -SourceType FixtureDerived -VerificationLevel Unverified -SourcePath 'fixtures' -FallbackMode Simulation) `
        -RepoRoot $RepoRoot
    $bind = Test-XboxOSReadinessReportBinding -Report $ready -Plan $plan -EvidenceMode InlineSimulation
    if (-not $bind.valid) { throw ("Inline readiness binding failed: {0}" -f ($bind.errors -join '; ')) }
    $planHash = [string]$plan.contentHash
    $readinessDigest = [string]$bind.readinessBindingDigest
    $isoSha = [string]$plan.sourceImage.isoSha256
    $experimentPlanHash = 'inline-simulation-no-m6a-plan'
}
elseif ((-not $Simulation) -and (Test-Path -LiteralPath $ReadinessJsonPath) -and (Test-Path -LiteralPath $CompatJsonPath)) {
    $inventory = Import-XboxOSInventoryFromCompatReport -Path $CompatJsonPath
    $plan = New-XboxOSServicingPlan -Inventory $inventory -RemoveAppsManifest $removeApps -DisableFeaturesManifest $disableFeatures -CompatibilityManifest $compatibility
    $readyFile = Get-Content -LiteralPath $ReadinessJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $bind = Test-XboxOSReadinessReportBinding -Report $readyFile -Plan $plan -EvidenceMode ExternalValidated -RequireAuthoritativeProvenance
    if (-not $bind.valid) {
        throw ("M5 readiness rejected (fail closed): {0}" -f ($bind.errors -join '; '))
    }
    if ($planHash -ne [string]$plan.contentHash) {
        throw 'M6A plan hash does not match recomputed M2 plan from authoritative inventory.'
    }
    if ($readinessDigest -ne [string]$bind.readinessBindingDigest) {
        throw 'M6A readiness binding digest does not match recomputed M5 digest.'
    }
    Write-Host ("Validated M5 readiness: {0}" -f $ReadinessJsonPath)
}

Reset-XboxOSLabNonceRegistry

$report = Invoke-XboxOSIsolatedLabSimulate `
    -Topology $topology `
    -FunctionalValidationCatalog $fvCatalog `
    -PlanHash $planHash `
    -ReadinessBindingDigest $readinessDigest `
    -SourceIsoSha256 $isoSha `
    -OwnerId $OperatorId `
    -RepoRoot $RepoRoot `
    -ExperimentPlanHash $experimentPlanHash `
    -SimulateOperatorReview:(-not $SkipOperatorReview)

$paths = Save-XboxOSIsolatedLabReport -Report $report -OutputDirectory $OutputDirectory -Stem $OutputStem -RepoRoot $RepoRoot

Write-Host ''
Write-Host ("Decision:              {0}" -f $report.decision)
Write-Host ("Transaction state:     {0}" -f $report.transactionState)
Write-Host ("Isolation valid:       {0}" -f $report.isolation.valid)
Write-Host ("Boundary valid:        {0}" -f $report.boundary.valid)
Write-Host ("Hypervisor available:  {0}" -f $report.hypervisorAvailable)
Write-Host ("Layer D activated:     {0}" -f $report.layerDActivated)
Write-Host ("JSON:                  {0}" -f $paths.JsonPath)
Write-Host ("Markdown:              {0}" -f $paths.MarkdownPath)

Assert-XboxOSIsolatedLabSafetyInvariants -Report $report
if ($report.decision -notin @('LabProvisioningBlocked', 'RecoveryRequired')) {
    throw 'Safety invariant violated: Milestone 6B must block real provisioning.'
}
exit 2
