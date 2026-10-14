#Requires -Version 5.1
<#
.SYNOPSIS
    Dismounts the working Windows image, committing or discarding changes.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [object]$Context,

    [string]$DismPath,
    [switch]$Discard,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
Import-Module $modulePath -Force

if (-not $DismPath) { $DismPath = Find-XboxOSDism }
$mount = $Context.Paths.Mount

if (-not $mount) {
    Write-XboxOSLog -Level Warning -Message 'No mount path recorded; nothing to dismount.'
    return
}

$action = if ($Discard) { 'Discard' } else { 'Commit' }
Write-XboxOSLog -Level Information -Message "Dismounting image ($action): $mount"

Invoke-XboxOSMountCleanup -MountPath $mount -DismPath $DismPath -Discard:$Discard -DryRun:$DryRun
$Context.MountedImagePath = $null

return [pscustomobject]@{
    MountPath = $mount
    Action    = $action
    DryRun    = [bool]$DryRun
}
