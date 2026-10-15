#Requires -Version 5.1
<#
.SYNOPSIS
    Milestone 6B.1 isolated disposable-image lab infrastructure readiness (simulation only).
.DESCRIPTION
    Default authoritative mode requires M1/M4 compatibility inventory, validated M5 readiness,
    and validated M6A experiment plan. Reconstructs the M2 plan, revalidates the M5 binding
    digest, and recomputes the M6A experiment content hash. Never falls back to synthetic
    evidence without -Simulation -AllowInlineSimulationReadiness.
    Always blocks real provisioning and Layer D. Does not invoke DISM or hypervisor commands.
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

if ($AllowInlineSimulationReadiness -and -not $Simulation) {
    throw '-AllowInlineSimulationReadiness requires -Simulation and never substitutes evidence in default authoritative mode.'
}

Write-Host '=== XboxOS11 Milestone 6B.1 isolated lab readiness (simulation only) ===' -ForegroundColor Cyan
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

$evidenceMode = 'ExternalValidated'
$evidenceChain = $null

if ($Simulation -and $AllowInlineSimulationReadiness) {
    Write-Host 'Mode: Explicit inline simulation evidence (fixtures). Label: InlineSimulationEvidence.' -ForegroundColor Yellow
    $evidenceMode = 'InlineSimulation'
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

    $eligibleIds = @($ready.operationAssessments | Where-Object planStatus -eq 'Eligible' | ForEach-Object { [string]$_.operationId })
    $simReport = Invoke-XboxOSExperimentPlanSimulate `
        -Plan $plan `
        -ReadinessAssessment $ready `
        -RequestedOperationIds $eligibleIds `
        -FunctionalValidationCatalog $fvCatalog `
        -CompatibilityManifest $compatibility `
        -RepoRoot $RepoRoot `
        -ProposedWorkspaceRoot 'C:\XboxOS\Work\lab-m6b-inline-sim' `
        -EvidenceMode InlineSimulation `
        -SimulateOperatorConsent `
        -SimulateRiskAcceptance
    if ($simReport.decision -ne 'BlockedForExecution') {
        throw 'Inline M6A simulation must remain BlockedForExecution.'
    }

    $planHash = [string]$plan.contentHash
    $inventoryFingerprint = [string]$plan.inventoryFingerprint
    $readinessDigest = [string]$bind.readinessBindingDigest
    $isoSha = [string]$plan.sourceImage.isoSha256
    $experimentPlanHash = [string]$simReport.experimentPlan.contentHash
    $evidenceChain = [pscustomobject]@{
        valid                  = $true
        evidenceMode           = 'InlineSimulation'
        evidenceLabel          = 'InlineSimulationEvidence'
        planHash               = $planHash
        inventoryFingerprint   = $inventoryFingerprint
        readinessBindingDigest = $readinessDigest
        experimentPlanHash     = $experimentPlanHash
        sourceIsoSha256        = $isoSha
        errors                 = @()
        notes                  = @('Explicit -Simulation -AllowInlineSimulationReadiness fixture chain.')
        activatesProvisioning  = $false
        activatesLayerD        = $false
    }
}
else {
    Write-Host 'Mode: Authoritative evidence chain (M1/M4 + M5 + M6A). Label: ExternalValidatedEvidence.'
    if ($Simulation -and -not $AllowInlineSimulationReadiness) {
        throw '-Simulation without -AllowInlineSimulationReadiness does not enable synthetic evidence; provide authoritative reports or both switches.'
    }
    foreach ($pair in @(
            @{ n = 'M1/M4 compatibility inventory'; p = $CompatJsonPath },
            @{ n = 'M5 readiness report'; p = $ReadinessJsonPath },
            @{ n = 'M6A experiment plan report'; p = $ExperimentPlanJsonPath }
        )) {
        if (-not (Test-Path -LiteralPath $pair.p)) {
            throw ("Missing required {0}: {1}. Authoritative mode never falls back to synthetic evidence." -f $pair.n, $pair.p)
        }
    }

    $evidenceChain = Test-XboxOSLabEvidenceChain `
        -CompatJsonPath $CompatJsonPath `
        -ReadinessJsonPath $ReadinessJsonPath `
        -ExperimentPlanJsonPath $ExperimentPlanJsonPath `
        -RemoveAppsManifest $removeApps `
        -DisableFeaturesManifest $disableFeatures `
        -CompatibilityManifest $compatibility `
        -EvidenceMode ExternalValidated

    if (-not $evidenceChain.valid) {
        throw ("Authoritative evidence chain rejected (fail closed): {0}" -f ($evidenceChain.errors -join '; '))
    }

    $planHash = [string]$evidenceChain.planHash
    $inventoryFingerprint = [string]$evidenceChain.inventoryFingerprint
    $readinessDigest = [string]$evidenceChain.readinessBindingDigest
    $isoSha = [string]$evidenceChain.sourceIsoSha256
    $experimentPlanHash = [string]$evidenceChain.experimentPlanHash
    Write-Host ("Validated M2 plan hash:        {0}" -f $planHash)
    Write-Host ("Validated inventory fingerprint:{0}" -f $inventoryFingerprint)
    Write-Host ("Validated M5 binding digest:   {0}" -f $readinessDigest)
    Write-Host ("Validated M6A plan hash:       {0}" -f $experimentPlanHash)
}

Reset-XboxOSLabNonceRegistry

$report = Invoke-XboxOSIsolatedLabSimulate `
    -Topology $topology `
    -FunctionalValidationCatalog $fvCatalog `
    -PlanHash $planHash `
    -ReadinessBindingDigest $readinessDigest `
    -SourceIsoSha256 $isoSha `
    -ExperimentPlanHash $experimentPlanHash `
    -InventoryFingerprint $inventoryFingerprint `
    -OwnerId $OperatorId `
    -RepoRoot $RepoRoot `
    -EvidenceMode $evidenceMode `
    -EvidenceChain $evidenceChain `
    -SimulateOperatorReview:(-not $SkipOperatorReview)

$paths = Save-XboxOSIsolatedLabReport -Report $report -OutputDirectory $OutputDirectory -Stem $OutputStem -RepoRoot $RepoRoot

Write-Host ''
Write-Host ("Decision:                 {0}" -f $report.decision)
Write-Host ("Transaction state:        {0}" -f $report.transactionState)
Write-Host ("Evidence label:           {0}" -f $report.evidenceLabel)
Write-Host ("Isolation policy:         {0}" -f $report.isolation.policyValidationStatus)
Write-Host ("Actual isolation verified:{0}" -f $report.isolation.actualIsolationVerified)
Write-Host ("Hypervisor inspection:    {0}" -f $report.isolation.hypervisorInspectionStatus)
Write-Host ("Network verification:     {0}" -f $report.isolation.networkIsolationVerificationStatus)
Write-Host ("Layer D activated:        {0}" -f $report.layerDActivated)
Write-Host ("JSON:                     {0}" -f $paths.JsonPath)
Write-Host ("Markdown:                 {0}" -f $paths.MarkdownPath)

Assert-XboxOSIsolatedLabSafetyInvariants -Report $report
if ($report.decision -notin @('LabProvisioningBlocked', 'RecoveryRequired')) {
    throw 'Safety invariant violated: Milestone 6B must block real provisioning.'
}
if ($report.isolation.actualIsolationVerified) {
    throw 'Safety invariant violated: actual isolation must remain unverified in Milestone 6B.'
}
if (@($report.functionalTestPlan.tests | Where-Object { $_.plannedStatus -eq 'Passed' -or $_.claimedPassed }).Count -gt 0) {
    throw 'Safety invariant violated: functional tests must not be Passed without runtime evidence.'
}
exit 2
