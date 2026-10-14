#Requires -Version 5.1
<#
.SYNOPSIS
    Mounts the working Windows image for offline servicing.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [object]$Context,

    [int]$Index = 1,
    [string]$DismPath,
    [switch]$DryRun,
    [switch]$ReadOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
Import-Module $modulePath -Force

if (-not $DismPath) { $DismPath = Find-XboxOSDism }
$wim = $Context.Paths.WorkingWim
$mount = $Context.Paths.Mount

if (-not $DryRun -and -not (Test-Path -LiteralPath $wim)) {
    throw "Working WIM not found: $wim. Run Import-Source.ps1 first."
}

New-XboxOSDirectory -Path $mount | Out-Null

$args = @(
    '/Mount-Image'
    "/ImageFile:$wim"
    "/Index:$Index"
    "/MountDir:$mount"
)
if ($ReadOnly) { $args += '/ReadOnly' }

Invoke-XboxOSDism -DismPath $DismPath -ArgumentList $args -DryRun:$DryRun | Out-Null
$Context.MountedImagePath = $mount
Write-XboxOSLog -Level Information -Message "Image mounted at $mount (index $Index)"

return [pscustomobject]@{
    MountPath = $mount
    ImageFile = $wim
    Index     = $Index
    DryRun    = [bool]$DryRun
}
