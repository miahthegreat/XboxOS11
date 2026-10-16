#Requires -Version 5.1
<#
.SYNOPSIS
    Writes the enabled registry settings from image-tweaks.json into the mounted image's offline hives.
.NOTES
    Hives are loaded under run-owned HKLM keys, written only with reg.exe, and always unloaded. If an unload
    fails the phase throws RecoveryRequired so Build-ISO discards the mounted image instead of committing.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Alias('Context')]
    [object]$BuildContext,

    [string]$ManifestPath,
    [scriptblock]$RegCommand = $null,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
Import-Module $modulePath -Force

$config = $BuildContext.Configuration
if (-not $ManifestPath) { $ManifestPath = $config.ResolvedPath.imageTweaksManifest }
$catalog = Get-XboxOSImageTweakCatalog -Path $ManifestPath
$selected = @($catalog.tweaks | Where-Object { $_.PSObject.Properties['enabled'] -and [bool]$_.enabled })
$mount = $BuildContext.Paths.Mount

$effectiveDryRun = [bool]($DryRun -or -not $BuildContext.ImageMounted)
if (-not $effectiveDryRun) {
    $null = Assert-XboxOSServicingPathSafety -Path $mount -RepoRoot $config.RepoRoot -Purpose 'offline image registry settings'
}

$invokeArgs = @{ MountDir = $mount; Tweaks = $selected; DryRun = $effectiveDryRun }
if ($RegCommand) { $invokeArgs['RegCommand'] = $RegCommand }
$results = @(Invoke-XboxOSImageRegistryTweaks @invokeArgs)
foreach ($r in $results) { Write-XboxOSLog -Level Information -Message ("Image setting {0} {1}\{2}: {3}" -f $r.Tweak, $r.Path, $r.Name, $r.Status) }

$reportPath = Join-Path $BuildContext.Paths.Reports 'ImageTweaks.json'
([ordered]@{ dryRun = $effectiveDryRun; tweaks = @($selected | ForEach-Object { $_.id }); results = $results } | ConvertTo-Json -Depth 6) |
    Set-Content -LiteralPath $reportPath -Encoding UTF8

$failed = @($results | Where-Object { $_.Status -eq 'Failed' })
$outcome = [pscustomobject]@{
    Results = $results
    Report  = $reportPath
    Success = ($failed.Count -eq 0)
    Message = $(if ($failed.Count -eq 0) { 'OK' } else { ($failed | ForEach-Object { "$($_.Tweak): $($_.Message)" }) -join '; ' })
}
Assert-XboxOSPhaseOutcome -Result $outcome -PhaseName 'ImageTweaks' | Out-Null
return $outcome
