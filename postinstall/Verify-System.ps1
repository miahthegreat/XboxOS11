#Requires -Version 5.1
<#
.SYNOPSIS
    Reports whether essential gaming dependencies appear present and operational.
#>
[CmdletBinding()]
param(
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$checks = New-Object System.Collections.Generic.List[object]

function Add-SystemCheck {
    param($Name, $Passed, $Message, $Category = 'General')
    $checks.Add([pscustomobject]@{
        Category = $Category
        Name     = $Name
        Passed   = [bool]$Passed
        Message  = $Message
    }) | Out-Null
}

# Windows version
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$build = [int]$cv.CurrentBuild
Add-SystemCheck -Category 'OS' -Name 'Windows11_24H2Plus' -Passed ($build -ge 26100) `
    -Message "CurrentBuild=$build (26100+ required for documented Xbox mode)"

# Services
foreach ($svcName in @('wuauserv', 'mpssvc', 'AudioSrv', 'bthserv', 'InstallService', 'ClipSVC', 'CryptSvc')) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    Add-SystemCheck -Category 'Service' -Name $svcName -Passed ($null -ne $svc) `
        -Message $(if ($svc) { "Status=$($svc.Status) StartType=$($svc.StartType)" } else { 'Service not found' })
}

# Gaming Services (may be provisioned after Store install)
foreach ($svcName in @('GamingServices', 'GamingServicesNet')) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    Add-SystemCheck -Category 'Xbox' -Name $svcName -Passed ($null -ne $svc) `
        -Message $(if ($svc) { "Status=$($svc.Status)" } else { 'Not installed yet (install Xbox / Gaming Services from Store)' })
}

# Appx packages
$packagePatterns = @{
    'Microsoft.WindowsStore' = 'Store'
    'Microsoft.Xbox.TCUI'     = 'Xbox'
    'Microsoft.GamingApp'     = 'Xbox'
    'Microsoft.XboxGamingOverlay' = 'GameBar'
}

foreach ($pattern in $packagePatterns.Keys) {
    $pkgs = Get-AppxPackage -Name $pattern -ErrorAction SilentlyContinue
    Add-SystemCheck -Category $packagePatterns[$pattern] -Name $pattern -Passed ($null -ne $pkgs -and @($pkgs).Count -gt 0) `
        -Message $(if ($pkgs) { (@($pkgs) | Select-Object -First 1).PackageFullName } else { 'Package not found for current user' })
}

# DirectX / graphics smoke
$dxdiag = Join-Path $env:SystemRoot 'System32\dxdiag.exe'
Add-SystemCheck -Category 'Graphics' -Name 'DxDiagPresent' -Passed (Test-Path -LiteralPath $dxdiag) -Message $dxdiag

# WebView2
$webview = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -ErrorAction SilentlyContinue
if (-not $webview) {
    $webview = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients' -ErrorAction SilentlyContinue | Select-Object -First 1
}
Add-SystemCheck -Category 'Runtime' -Name 'WebView2' -Passed ($null -ne $webview) `
    -Message $(if ($webview) { 'WebView2 runtime registry evidence found' } else { 'WebView2 not detected; launchers may install it' })

# Gaming hardware guidance (read-only; this script never changes settings)
$cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
if ($cpu -and [string]$cpu.Name -match 'X3D') {
    $activeScheme = [string](& powercfg.exe /getactivescheme 2>$null)
    $balanced = $activeScheme -match '381b4222-f694-41f0-9685-ff5bb260df2e'
    Add-SystemCheck -Category 'Performance' -Name 'X3DBalancedPowerPlan' -Passed $balanced `
        -Message $(if ($balanced) { 'Balanced plan active (recommended for Ryzen X3D)' } else { "Active: $activeScheme. AMD recommends Balanced for X3D processors." })
    $vcache = @(Get-Service -Name 'amd3dvcache*' -ErrorAction SilentlyContinue)
    Add-SystemCheck -Category 'Performance' -Name 'AMD3DVCacheOptimizer' -Passed ($vcache.Count -gt 0) `
        -Message $(if ($vcache.Count -gt 0) { 'AMD 3D V-Cache Performance Optimizer present' } else { 'Install the AMD chipset driver from amd.com to add the 3D V-Cache Performance Optimizer' })
}

foreach ($gpu in @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue)) {
    $name = [string]$gpu.Name
    $basic = $name -match 'Microsoft Basic Display'
    Add-SystemCheck -Category 'Graphics' -Name ('GPU: ' + $name) -Passed (-not $basic) `
        -Message $(if ($basic) { 'No vendor driver installed. Install AMD Software: Adrenalin Edition from amd.com.' } else { "Driver $($gpu.DriverVersion)" })
}

$gameBar = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'UseNexusForGameBarEnabled' -ErrorAction SilentlyContinue
$gameBarOn = ($null -eq $gameBar) -or ([int]$gameBar.UseNexusForGameBarEnabled -ne 0)
Add-SystemCheck -Category 'Xbox' -Name 'GameBarEnabled' -Passed $gameBarOn `
    -Message $(if ($gameBarOn) { 'Game Bar enabled (needed for Xbox mode and X3D game detection)' } else { 'Game Bar is turned off in Settings > Gaming > Game Bar' })

Write-Host 'XboxOS11 system verification'
Write-Host '============================'
foreach ($check in $checks) {
    $mark = if ($check.Passed) { '[OK]' } else { '[!!]' }
    Write-Host "$mark [$($check.Category)] $($check.Name): $($check.Message)"
}

Write-Host ''
Write-Host 'This report does not prove Xbox mode or anti-cheat compatibility. Validate in-game.'

if ($PassThru) {
    return [pscustomobject]@{
        Checks  = $checks
        Passed  = (@($checks | Where-Object { -not $_.Passed }).Count -eq 0)
        Build   = $build
    }
}
