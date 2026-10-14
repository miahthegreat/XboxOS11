#Requires -Version 5.1
<#
.SYNOPSIS
    Disables optional Windows features listed in disable-features.json using offline DISM.
.NOTES
    Inventory states:
      Unknown   - no mounted-image inventory (typical dry-run); candidates are NotEvaluated
      Empty     - inventory was queried and contained no matching feature names
      Available - inventory was queried and feature names are known
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Alias('Context')]
    [object]$BuildContext,

    [string]$ManifestPath,
    [string]$DismPath,

    [Parameter()]
    [AllowEmptyCollection()]
    [string[]]$AvailableFeatures,

    [ValidateSet('Unknown', 'Empty', 'Available')]
    [string]$InventoryState,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
Import-Module $modulePath -Force

if (-not $DismPath) { $DismPath = Find-XboxOSDism }
$config = $BuildContext.Configuration
if (-not $ManifestPath) { $ManifestPath = $config.ResolvedPath.disableFeaturesManifest }

$manifest = Import-XboxOSManifest -Path $ManifestPath
$mount = $BuildContext.Paths.Mount
$removePayload = [bool]$manifest.removePayload
$never = @()
if ($manifest.neverDisable) { $never = @($manifest.neverDisable) }

$featuresBound = $PSBoundParameters.ContainsKey('AvailableFeatures')
$stateBound = $PSBoundParameters.ContainsKey('InventoryState')

if ($featuresBound) {
    if (-not $stateBound) {
        $InventoryState = if (@($AvailableFeatures).Count -eq 0) { 'Empty' } else { 'Available' }
    }
}
elseif ($stateBound) {
    if ($InventoryState -eq 'Available') {
        throw 'InventoryState=Available requires -AvailableFeatures to be supplied.'
    }
    $AvailableFeatures = @()
}
elseif ($BuildContext.PSObject.Properties.Name -contains 'FeatureInventoryState' -and
        $BuildContext.FeatureInventoryState -and
        $BuildContext.FeatureInventoryState -ne 'Unknown') {
    $InventoryState = [string]$BuildContext.FeatureInventoryState
    $AvailableFeatures = @($BuildContext.FeatureInventory)
}
elseif ($DryRun -or -not $BuildContext.ImageMounted) {
    $InventoryState = 'Unknown'
    $AvailableFeatures = @()
}
else {
    if (-not $DryRun) {
        $null = Assert-XboxOSServicingPathSafety -Path $mount -RepoRoot $config.RepoRoot -Purpose 'feature disable'
    }
    $feat = Invoke-XboxOSDism -DismPath $DismPath -ArgumentList @("/Image:$mount", '/Get-Features')
    $AvailableFeatures = @(foreach ($line in $feat.Output) {
            if ($line -match '^\s*Feature Name\s*:\s*(.+)$') { $Matches[1].Trim() }
        })
    $InventoryState = if ($AvailableFeatures.Count -eq 0) { 'Empty' } else { 'Available' }
}

$availability = Get-XboxOSInventoryAvailability -State $InventoryState -Items @($AvailableFeatures)
$results = New-Object System.Collections.Generic.List[object]
$fatalErrors = New-Object System.Collections.Generic.List[string]

foreach ($candidate in @($manifest.candidates)) {
    if (-not $candidate.enabled) {
        $results.Add([pscustomobject]@{
            Candidate = $candidate.id
            Feature   = $null
            Status    = 'Skipped'
            Message   = 'Candidate disabled in manifest'
        }) | Out-Null
        continue
    }

    if (-not $availability.CanEvaluate) {
        foreach ($name in @($candidate.featureNames)) {
            $results.Add([pscustomobject]@{
                Candidate = $candidate.id
                Feature   = $name
                Status    = 'NotEvaluated'
                Message   = 'No mounted-image feature inventory is available; feature state cannot be evaluated.'
            }) | Out-Null
        }
        continue
    }

    $resolved = @(Resolve-XboxOSFeatureMatches -FeatureNames @($candidate.featureNames) -AvailableFeatures @($availability.Items))
    foreach ($item in $resolved) {
        if ($item.Status -eq 'Absent') {
            $results.Add([pscustomobject]@{
                Candidate = $candidate.id
                Feature   = $item.Requested
                Status    = 'Absent'
                Message   = 'Feature not present in known image inventory'
            }) | Out-Null
            continue
        }

        $feature = $item.Resolved
        if (Test-XboxOSFeatureProtected -FeatureName $feature -NeverDisable $never) {
            $results.Add([pscustomobject]@{
                Candidate = $candidate.id
                Feature   = $feature
                Status    = 'Skipped'
                Message   = 'Protected / neverDisable policy'
            }) | Out-Null
            Write-XboxOSLog -Level Warning -Message "Refusing to disable protected feature: $feature"
            continue
        }

        try {
            $dismArgs = @("/Image:$mount", '/Disable-Feature', "/FeatureName:$feature", '/NoRestart')
            if ($removePayload) { $dismArgs += '/Remove' }

            if ($DryRun) {
                Write-XboxOSLog -Level Information -Message "DryRun: would disable feature $feature"
                $results.Add([pscustomobject]@{
                    Candidate = $candidate.id
                    Feature   = $feature
                    Status    = 'DryRun'
                    Message   = 'Would disable feature (payload retained unless removePayload=true)'
                }) | Out-Null
            }
            else {
                $null = Assert-XboxOSServicingPathSafety -Path $mount -RepoRoot $config.RepoRoot -Purpose 'feature disable'
                Invoke-XboxOSDism -DismPath $DismPath -ArgumentList $dismArgs | Out-Null
                $results.Add([pscustomobject]@{
                    Candidate = $candidate.id
                    Feature   = $feature
                    Status    = 'Disabled'
                    Message   = $(if ($removePayload) { 'Disabled with payload removal' } else { 'Disabled; payload retained' })
                }) | Out-Null
                Write-XboxOSLog -Level Information -Message "Disabled feature: $feature"
            }
        }
        catch {
            $results.Add([pscustomobject]@{
                Candidate = $candidate.id
                Feature   = $feature
                Status    = 'Failed'
                Message   = $_.Exception.Message
            }) | Out-Null
            $fatalErrors.Add("Failed disabling ${feature}: $($_.Exception.Message)") | Out-Null
            Write-XboxOSLog -Level Error -Message "Failed disabling $feature : $($_.Exception.Message)"
        }
    }
}

$reportPath = Join-Path $BuildContext.Paths.Reports 'DisableFeatures.json'
$payload = [ordered]@{
    inventoryState = $InventoryState
    dryRun         = [bool]$DryRun
    results        = $results
}
($payload | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $reportPath -Encoding UTF8

$outcome = [pscustomobject]@{
    Results        = $results
    Report         = $reportPath
    InventoryState = $InventoryState
    Success        = ($fatalErrors.Count -eq 0)
    Message        = $(if ($fatalErrors.Count -eq 0) { 'OK' } else { ($fatalErrors -join '; ') })
}

Assert-XboxOSPhaseOutcome -Result $outcome -PhaseName 'DisableFeatures' | Out-Null
return $outcome
