#Requires -Version 5.1
<#
.SYNOPSIS
    Applies safe, idempotent gaming-related Windows configuration after installation.
.NOTES
    Milestone 1 prepares this script; it is not executed automatically during Windows Setup.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$EnableGameMode,
    [switch]$EnableHardwareAcceleratedGPUScheduling,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$results = New-Object System.Collections.Generic.List[object]

function Set-GameDvrRegistry {
    param([string]$Path, [string]$Name, [object]$Value, [string]$Type = 'DWord')
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    $current = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($current -and $current.$Name -eq $Value) {
        return 'Unchanged'
    }
    if ($PSCmdlet.ShouldProcess("$Path\$Name", "Set to $Value")) {
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        return 'Applied'
    }
    return 'Skipped'
}

# Game Mode (supported Settings-backed value)
if ($EnableGameMode -or -not $PSBoundParameters.ContainsKey('EnableGameMode')) {
    try {
        $status = Set-GameDvrRegistry -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AutoGameModeEnabled' -Value 1
        $results.Add([pscustomobject]@{ Setting = 'GameMode'; Status = $status }) | Out-Null
    }
    catch {
        $results.Add([pscustomobject]@{ Setting = 'GameMode'; Status = "Failed: $($_.Exception.Message)" }) | Out-Null
    }
}

# HAGS is hardware/driver dependent; only toggle when requested.
if ($EnableHardwareAcceleratedGPUScheduling) {
    try {
        $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
        $status = Set-GameDvrRegistry -Path $path -Name 'HwSchMode' -Value 2
        $results.Add([pscustomobject]@{ Setting = 'HAGS'; Status = $status; Notes = 'Requires reboot and compatible GPU driver.' }) | Out-Null
    }
    catch {
        $results.Add([pscustomobject]@{ Setting = 'HAGS'; Status = "Failed: $($_.Exception.Message)" }) | Out-Null
    }
}

Write-Host 'Setup-Gaming complete (idempotent). Review results before relying on performance claims.'
$results | Format-Table -AutoSize | Out-String | Write-Host

if ($PassThru) { return $results }
