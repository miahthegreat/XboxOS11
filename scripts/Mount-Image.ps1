#Requires -Version 5.1
<#
.SYNOPSIS
    Mounts the working Windows image for offline servicing.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Alias('Context')]
    [object]$BuildContext,

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
$wim = $BuildContext.Paths.WorkingWim
$mount = $BuildContext.Paths.Mount

$null = Assert-XboxOSServicingPathSafety -Path $mount -RepoRoot $BuildContext.Configuration.RepoRoot -Purpose 'WIM mount'
$null = Assert-XboxOSServicingPathSafety -Path $wim -RepoRoot $BuildContext.Configuration.RepoRoot -Purpose 'working WIM'

if ($DryRun) {
    Write-XboxOSLog -Level Information -Message 'DryRun: skipping image mount; inventory remains Unknown.'
    $BuildContext.MountedImagePath = $null
    $BuildContext.ImageMounted = $false
    return [pscustomobject]@{
        MountPath    = $mount
        ImageFile    = $wim
        Index        = $Index
        DryRun       = $true
        ImageMounted = $false
    }
}

if (-not (Test-Path -LiteralPath $wim)) {
    throw "Working WIM not found: $wim. Run Import-Source.ps1 first."
}

New-XboxOSDirectory -Path $mount | Out-Null

$dismArgs = @(
    '/Mount-Image'
    "/ImageFile:$wim"
    "/Index:$Index"
    "/MountDir:$mount"
)
if ($ReadOnly) { $dismArgs += '/ReadOnly' }

Invoke-XboxOSDism -DismPath $DismPath -ArgumentList $dismArgs | Out-Null
$BuildContext.MountedImagePath = $mount
$BuildContext.ImageMounted = $true
Write-XboxOSLog -Level Information -Message "Image mounted at $mount (index $Index)"

return [pscustomobject]@{
    MountPath    = $mount
    ImageFile    = $wim
    Index        = $Index
    DryRun       = $false
    ImageMounted = $true
}
