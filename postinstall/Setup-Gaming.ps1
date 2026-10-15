#Requires -Version 5.1
<#
.SYNOPSIS
    Applies Game Mode and (optionally) hardware-accelerated GPU scheduling.
.DESCRIPTION
    Compatibility wrapper over Set-GamingOptimizations.ps1, which captures original values so changes can
    be undone with: .\Set-GamingOptimizations.ps1 -Restore
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$EnableGameMode,
    [switch]$EnableHardwareAcceleratedGPUScheduling,
    [string]$StatePath = 'C:\ProgramData\XboxOS11\gaming-state.json',
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ids = New-Object System.Collections.Generic.List[string]
# Game Mode is on unless explicitly turned off with -EnableGameMode:$false.
if ($EnableGameMode -or -not $PSBoundParameters.ContainsKey('EnableGameMode')) { $ids.Add('GameMode') | Out-Null }
if ($EnableHardwareAcceleratedGPUScheduling) { $ids.Add('HardwareAcceleratedGpuScheduling') | Out-Null }

$results = & (Join-Path $PSScriptRoot 'Set-GamingOptimizations.ps1') -Enable $ids.ToArray() -StatePath $StatePath -PassThru -WhatIf:$WhatIfPreference
Write-Host 'Setup-Gaming complete (idempotent, reversible with Set-GamingOptimizations.ps1 -Restore).'
if ($PassThru) { return $results }
