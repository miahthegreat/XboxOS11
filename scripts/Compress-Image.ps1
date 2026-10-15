#Requires -Version 5.1
<#
.SYNOPSIS
    Re-exports the committed working image with stronger compression for a smaller ISO.
.NOTES
    image.compression = Max      -> install.wim (/Compress:max)
    image.compression = Recovery -> install.esd (/Compress:recovery; smallest, slowest, Setup-supported)
    Sets $Context.FinalImagePath, which Validate-Image and Export-ISO use. The working WIM is left in place.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [object]$Context,

    [string]$DismPath,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
Import-Module $modulePath -Force

if (-not $DismPath) { $DismPath = Find-XboxOSDism }
$config = $Context.Configuration
$compression = 'Default'
if ($config.Raw.PSObject.Properties['image'] -and $config.Raw.image.PSObject.Properties['compression']) { $compression = [string]$config.Raw.image.compression }
if ($compression -notin (Get-XboxOSImageCompressionModes)) { throw "Unsupported image.compression '$compression'." }

$source = $Context.Paths.WorkingWim
if ($compression -eq 'Default') {
    return [pscustomobject]@{ Results = @(); Success = $true; Message = 'Default compression; image not re-exported.'; FinalImagePath = $source }
}

$ext = if ($compression -eq 'Recovery') { '.esd' } else { '.wim' }
$destination = Join-Path (Split-Path -Parent $source) ("install-final$ext")
$null = Assert-XboxOSServicingPathSafety -Path $destination -RepoRoot $config.RepoRoot -Purpose 'recompressed image'
$dismArgs = Get-XboxOSImageExportArguments -SourceImage $source -DestinationImage $destination -Compression $compression
$command = "dism.exe $($dismArgs -join ' ')"

$before = $null
$after = $null
if ($DryRun) {
    Write-XboxOSLog -Level Information -Message "DryRun: would run $command"
    $status = 'DryRun'
}
else {
    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force }
    $before = (Get-Item -LiteralPath $source).Length
    Invoke-XboxOSDism -DismPath $DismPath -ArgumentList $dismArgs | Out-Null
    if (-not (Test-Path -LiteralPath $destination)) { throw "Recompressed image was not created: $destination" }
    $after = (Get-Item -LiteralPath $destination).Length
    $status = 'Recompressed'
    Write-XboxOSLog -Level Information -Message ("Recompressed image ({0}): {1:N0} -> {2:N0} bytes" -f $compression, $before, $after)
}

$Context | Add-Member -NotePropertyName FinalImagePath -NotePropertyValue $destination -Force
$reportPath = Join-Path $Context.Paths.Reports 'Recompress.json'
([ordered]@{ status = $status; compression = $compression; command = $command; sourceBytes = $before; finalBytes = $after; finalImagePath = $destination } |
    ConvertTo-Json) | Set-Content -LiteralPath $reportPath -Encoding UTF8
return [pscustomobject]@{ Results = @([pscustomobject]@{ Status = $status }); Report = $reportPath; Success = $true; Message = 'OK'; FinalImagePath = $destination }
