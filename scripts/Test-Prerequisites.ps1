#Requires -Version 5.1
<#
.SYNOPSIS
    Validates host prerequisites for XboxOS11 image builds.
.DESCRIPTION
    Detects Windows host, elevation, PowerShell, DISM, Windows ADK/Oscdimg,
    disk space, source ISO, workspace writability, and architecture support.
    Does not install missing dependencies.
#>
[CmdletBinding()]
param(
    [string]$SourceISO,
    [string]$Configuration = (Join-Path $PSScriptRoot '..\config\build.json'),
    [string]$Workspace,
    [long]$MinimumFreeGb,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
Import-Module $modulePath -Force

$configWrapper = Get-XboxOSBuildConfiguration -Path $Configuration
$config = $configWrapper.Raw

if (-not $MinimumFreeGb) {
    $MinimumFreeGb = [long]$config.workspace.minimumFreeGb
}
if (-not $Workspace) {
    $Workspace = Resolve-XboxOSPath -Path ([string]$config.workspace.root) -BasePath $configWrapper.RepoRoot
}

$checks = New-Object System.Collections.Generic.List[object]
function Add-Check {
    param($Name, $Passed, $Message, $Remediation = $null)
    $checks.Add([pscustomobject]@{
        Name        = $Name
        Passed      = [bool]$Passed
        Message     = $Message
        Remediation = $Remediation
    }) | Out-Null
}

# Host OS
$hostOk = Test-XboxOSWindowsHost
Add-Check -Name 'WindowsHost' -Passed $hostOk `
    -Message $(if ($hostOk) { "Windows host detected ($env:OS)" } else { 'XboxOS11 builds require a Windows host.' }) `
    -Remediation 'Run this pipeline on Windows 10/11 x64 with administrator rights.'

# Administrator
$adminOk = Test-XboxOSAdministrator
Add-Check -Name 'Administrator' -Passed $adminOk `
    -Message $(if ($adminOk) { 'Process is elevated.' } else { 'Administrator privileges are required for DISM image servicing.' }) `
    -Remediation 'Re-open PowerShell using "Run as administrator".'

# PowerShell version
$psOk = $PSVersionTable.PSVersion -ge [version]'5.1'
$psMessage = "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $psMessage += '. PowerShell 7 is recommended for orchestration; Windows PowerShell 5.1 remains supported.'
}
Add-Check -Name 'PowerShell' -Passed $psOk -Message $psMessage `
    -Remediation 'Install PowerShell 7 from https://aka.ms/powershell and/or ensure Windows PowerShell 5.1 is available.'

# DISM
$dism = Find-XboxOSDism
Add-Check -Name 'DISM' -Passed ([bool]$dism) `
    -Message $(if ($dism) { "DISM found: $dism" } else { 'DISM executable was not found.' }) `
    -Remediation 'DISM ships with Windows. Repair system files or install Windows ADK Deployment Tools.'

# ADK / Oscdimg
$adk = Find-XboxOSAdkTools
Add-Check -Name 'WindowsADK' -Passed ([bool]$adk.AdkRoot) `
    -Message $(if ($adk.AdkRoot) { "ADK root: $($adk.AdkRoot)" } else { 'Windows Assessment and Deployment Kit was not detected.' }) `
    -Remediation 'Install Windows ADK (Deployment Tools) from https://learn.microsoft.com/windows-hardware/get-started/adk-install'

Add-Check -Name 'Oscdimg' -Passed ([bool]$adk.Oscdimg) `
    -Message $(if ($adk.Oscdimg) { "oscdimg found: $($adk.Oscdimg)" } else { 'oscdimg.exe was not found under ADK Deployment Tools.' }) `
    -Remediation 'Install Windows ADK with the Deployment Tools feature enabled. Oscdimg is required to produce bootable ISOs.'

$logsPath = Resolve-XboxOSPath -Path ([string]$config.workspace.logs) -BasePath $configWrapper.RepoRoot
$cachePath = Resolve-XboxOSPath -Path ([string]$config.workspace.cache) -BasePath $configWrapper.RepoRoot
$tempPath = Resolve-XboxOSPath -Path ([string]$config.workspace.temp) -BasePath $configWrapper.RepoRoot
$outputPath = Resolve-XboxOSPath -Path ([string]$config.workspace.output) -BasePath $configWrapper.RepoRoot

# Disk space
$workspaceParent = Split-Path -Parent $Workspace
if (-not (Test-Path -LiteralPath $workspaceParent)) {
    New-XboxOSDirectory -Path $workspaceParent | Out-Null
}
$freeBytes = Get-XboxOSDiskFreeBytes -Path $Workspace
$needed = [int64]$MinimumFreeGb * 1GB
$spaceOk = $freeBytes -ge $needed
Add-Check -Name 'DiskSpace' -Passed $spaceOk `
    -Message ("Free space on workspace volume: {0:N2} GB (required: {1} GB)" -f ($freeBytes / 1GB), $MinimumFreeGb) `
    -Remediation 'Free disk space or relocate workspace/output to a larger volume.'

# Workspace writable
$writable = Test-XboxOSWritablePath -Path $Workspace
Add-Check -Name 'WritableWorkspace' -Passed $writable `
    -Message $(if ($writable) { "Workspace is writable: $Workspace" } else { "Workspace is not writable: $Workspace" }) `
    -Remediation 'Choose a writable directory and ensure NTFS permissions allow create/write/delete.'

try {
    Assert-XboxOSBuildSafety -WorkspaceRoot $Workspace -RepoRoot $configWrapper.RepoRoot -AdditionalPaths @(
        $logsPath
        $cachePath
        $tempPath
        $outputPath
    ) | Out-Null
    Add-Check -Name 'WorkspaceSafety' -Passed $true `
        -Message "Workspace isolation OK: Work=$Workspace; Logs=$logsPath; Output=$outputPath"
}
catch {
    Add-Check -Name 'WorkspaceSafety' -Passed $false -Message $_.Exception.Message `
        -Remediation 'Set workspace.root/logs/temp/output to local non-synced paths such as C:\XboxOS\Work, C:\XboxOS\Logs, and C:\XboxOS\Output.'
}

# Architecture
$arch = [string]$config.target.architecture
$archOk = Test-XboxOSArchitectureSupported -Architecture $arch
Add-Check -Name 'Architecture' -Passed $archOk `
    -Message $(if ($archOk) { "Configured architecture '$arch' is supported." } else { "Unsupported architecture '$arch'." }) `
    -Remediation 'Set target.architecture to amd64 (recommended) or arm64 in config/build.json.'

# Source ISO (optional unless provided)
if ($SourceISO) {
    $isoPath = Resolve-XboxOSPath -Path $SourceISO
    $isoOk = Test-Path -LiteralPath $isoPath
    Add-Check -Name 'SourceISO' -Passed $isoOk `
        -Message $(if ($isoOk) { "Source ISO found: $isoPath" } else { "Source ISO not found: $isoPath" }) `
        -Remediation 'Download an official Windows 11 ISO from Microsoft and pass -SourceISO.'
}
else {
    Add-Check -Name 'SourceISO' -Passed $true `
        -Message 'Source ISO not supplied to prerequisite check (skipped). Provide -SourceISO for a full validation.'
}

# Filesystem permissions probe on logs/output/temp/cache
foreach ($pair in @(
        @{ Name = 'logs'; Path = $logsPath }
        @{ Name = 'output'; Path = $outputPath }
        @{ Name = 'temp'; Path = $tempPath }
        @{ Name = 'cache'; Path = $cachePath }
    )) {
    $ok = Test-XboxOSWritablePath -Path $pair.Path
    Add-Check -Name ("Writable_$($pair.Name)") -Passed $ok `
        -Message $(if ($ok) { "$($pair.Name) path writable: $($pair.Path)" } else { "$($pair.Name) path not writable: $($pair.Path)" }) `
        -Remediation "Ensure write permission for $($pair.Path)"
}

$failed = @($checks | Where-Object { -not $_.Passed })
Write-Host ''
Write-Host 'XboxOS11 prerequisite check'
Write-Host '==========================='
foreach ($check in $checks) {
    $mark = if ($check.Passed) { '[PASS]' } else { '[FAIL]' }
    Write-Host "$mark $($check.Name): $($check.Message)"
    if (-not $check.Passed -and $check.Remediation) {
        Write-Host "       Fix: $($check.Remediation)"
    }
}

$result = [pscustomobject]@{
    Passed       = ($failed.Count -eq 0)
    Checks       = $checks
    DismPath     = $dism
    Adk          = $adk
    FailedCount  = $failed.Count
    Failed       = $failed
}

if (-not $result.Passed) {
    $message = "Prerequisite validation failed with $($failed.Count) issue(s). Install missing tools manually; this script does not install dependencies."
    if ($PassThru) {
        Write-Warning $message
        return $result
    }
    throw $message
}

if ($PassThru) {
    return $result
}

Write-Host ''
Write-Host 'All required prerequisites passed.' -ForegroundColor Green
