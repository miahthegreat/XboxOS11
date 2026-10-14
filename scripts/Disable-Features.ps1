#Requires -Version 5.1
<#
.SYNOPSIS
    Disables optional Windows features listed in disable-features.json using offline DISM.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [object]$Context,

    [string]$ManifestPath,
    [string]$DismPath,
    [string[]]$AvailableFeatures,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
Import-Module $modulePath -Force

if (-not $DismPath) { $DismPath = Find-XboxOSDism }
$config = $Context.Configuration
if (-not $ManifestPath) { $ManifestPath = $config.ResolvedPath.disableFeaturesManifest }

$manifest = Import-XboxOSManifest -Path $ManifestPath
$mount = $Context.Paths.Mount
$removePayload = [bool]$manifest.removePayload
$never = @()
if ($manifest.neverDisable) { $never = @($manifest.neverDisable) }

if (-not $AvailableFeatures) {
    if ($DryRun) {
        $AvailableFeatures = @()
    }
    else {
        $feat = Invoke-XboxOSDism -DismPath $DismPath -ArgumentList @("/Image:$mount", '/Get-Features')
        $AvailableFeatures = foreach ($line in $feat.Output) {
            if ($line -match '^\s*Feature Name\s*:\s*(.+)$') { $Matches[1].Trim() }
        }
    }
}

$results = New-Object System.Collections.Generic.List[object]

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

    $resolved = Resolve-XboxOSFeatureMatches -FeatureNames @($candidate.featureNames) -AvailableFeatures $AvailableFeatures
    foreach ($item in $resolved) {
        if ($item.Status -eq 'Absent') {
            $results.Add([pscustomobject]@{
                Candidate = $candidate.id
                Feature   = $item.Requested
                Status    = 'Absent'
                Message   = 'Feature not present in image inventory'
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
            $args = @("/Image:$mount", '/Disable-Feature', "/FeatureName:$feature", '/NoRestart')
            # Retain payloads by default for safer servicing.
            if ($removePayload) { $args += '/Remove' }

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
                Invoke-XboxOSDism -DismPath $DismPath -ArgumentList $args | Out-Null
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
            throw
        }
    }
}

$reportPath = Join-Path $Context.Paths.Reports 'DisableFeatures.json'
($results | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $reportPath -Encoding UTF8

return [pscustomobject]@{
    Results = $results
    Report  = $reportPath
}
