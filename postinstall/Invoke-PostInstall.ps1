#Requires -Version 5.1
<#
.SYNOPSIS
    XboxOS11 first-logon entrypoint. Applies the post-install options chosen in the Builder profile.
.DESCRIPTION
    Staged by the Builder to %WINDIR%\Setup\Scripts\XboxOS11 via sources\$OEM$ and launched once from
    FirstLogonCommands. Reads postinstall.json next to this script. Every step is idempotent and
    failure-tolerant: a failed step is logged and never blocks sign-in. Nothing here disables security
    features, Windows Update, Defender, Store, or Xbox components.

    Runs under Windows PowerShell 5.1 (inbox) - keep syntax 5.1-compatible.
#>
[CmdletBinding()]
param(
    [string]$OptionsPath = (Join-Path $PSScriptRoot 'postinstall.json'),
    [int]$WingetWaitSeconds = 600,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$options = $null
if (Test-Path -LiteralPath $OptionsPath) {
    $options = Get-Content -LiteralPath $OptionsPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
else {
    $options = [pscustomobject]@{
        schemaVersion = 'xboxos-postinstall-options-v1'; profileName = 'default'; gameMode = $true
        hardwareAcceleratedGpuScheduling = $false; launchers = @(); logPath = 'C:\ProgramData\XboxOS11\postinstall.log'
    }
}

$logPath = [string]$options.logPath
$logDir = Split-Path -Parent $logPath
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$transcribing = $false
try { Start-Transcript -LiteralPath $logPath -Append -ErrorAction Stop | Out-Null; $transcribing = $true } catch { Write-Warning "Transcript unavailable: $($_.Exception.Message)" }

$summary = New-Object System.Collections.Generic.List[object]
function Add-StepResult {
    param([string]$Step, [string]$Status, [string]$Message = '')
    $summary.Add([pscustomobject]@{ Step = $Step; Status = $Status; Message = $Message; Utc = [datetime]::UtcNow.ToString('o') }) | Out-Null
    Write-Host ("[{0}] {1}: {2} {3}" -f [datetime]::Now.ToString('HH:mm:ss'), $Step, $Status, $Message)
}

try {
    Write-Host ("XboxOS11 post-install for profile '{0}'" -f $options.profileName)

    # 1. Gaming configuration (Game Mode / optional HAGS).
    try {
        $gamingArgs = @{ PassThru = $true; EnableGameMode = [bool]$options.gameMode }
        if ([bool]$options.hardwareAcceleratedGpuScheduling) { $gamingArgs['EnableHardwareAcceleratedGPUScheduling'] = $true }
        if ($DryRun) { $gamingArgs['WhatIf'] = $true }
        $null = & (Join-Path $PSScriptRoot 'Setup-Gaming.ps1') @gamingArgs
        Add-StepResult -Step 'GamingSettings' -Status 'Completed'
    }
    catch { Add-StepResult -Step 'GamingSettings' -Status 'Failed' -Message $_.Exception.Message }

    # 2. Launchers via winget (App Installer can take several minutes to register after first sign-in).
    $launchers = @($options.launchers | Where-Object { $_ })
    if ($launchers.Count -gt 0) {
        $deadline = [datetime]::UtcNow.AddSeconds($WingetWaitSeconds)
        while (-not (Get-Command winget.exe -ErrorAction SilentlyContinue) -and [datetime]::UtcNow -lt $deadline -and -not $DryRun) {
            Start-Sleep -Seconds 15
        }
        try {
            $launcherArgs = @{ Launchers = [string[]]$launchers; PassThru = $true; Confirm = $false }
            if ($DryRun) { $launcherArgs['DryRun'] = $true }
            $results = & (Join-Path $PSScriptRoot 'Install-Launchers.ps1') @launcherArgs
            foreach ($r in @($results)) {
                $message = ''
                if ($r.PSObject.Properties['Message']) { $message = [string]$r.Message }
                Add-StepResult -Step ('Launcher:' + $r.Launcher) -Status ([string]$r.Status) -Message $message
            }
        }
        catch { Add-StepResult -Step 'Launchers' -Status 'Failed' -Message $_.Exception.Message }
    }
    else {
        Add-StepResult -Step 'Launchers' -Status 'Skipped' -Message 'No launchers selected.'
    }

    # 3. Dependency verification report.
    try {
        $checks = & (Join-Path $PSScriptRoot 'Verify-System.ps1') -PassThru
        $failed = @($checks | Where-Object { -not $_.Passed })
        $status = 'Completed'
        if ($failed.Count -gt 0) { $status = 'Attention' }
        Add-StepResult -Step 'VerifySystem' -Status $status -Message ('{0} check(s) need attention.' -f $failed.Count)
    }
    catch { Add-StepResult -Step 'VerifySystem' -Status 'Failed' -Message $_.Exception.Message }

    Write-Host 'Next steps: install AMD chipset and Radeon Adrenalin drivers from amd.com, then run Windows Update.'
}
finally {
    $summaryPath = Join-Path $logDir 'postinstall-summary.json'
    $summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    if ($transcribing) { Stop-Transcript | Out-Null }
}
