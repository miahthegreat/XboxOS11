#Requires -Version 5.1
<#
.SYNOPSIS
    Conservatively configures or documents Xbox Full Screen Experience / Xbox mode.
.DESCRIPTION
    Microsoft documents Xbox mode for Windows 11 24H2+. On non-handheld PCs, enablement is
    primarily through Settings > Gaming > Xbox mode (and Game Bar / Win+F11). Automatic
    "Enter Xbox mode on startup" is documented for gaming handhelds.

    Microsoft-Windows-Gaming-Configuration / StartupToGamingHome exists as an OEM unattend
    setting, but desktop validation is required before claiming automatic startup works.

    This script does NOT replace Explorer.exe or apply undocumented shell hacks.
.NOTES
    Milestone 1: prepared for later integration; not run automatically during Setup.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('DocumentOnly', 'AttemptSupportedSettings')]
    [string]$Mode = 'DocumentOnly',

    [switch]$GenerateUnattendSnippet,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\artifacts\output'),

    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$manualSteps = @(
    'Confirm Windows 11 version 24H2 or later (25H2 recommended).'
    'Install/update the Xbox app and Xbox Game Bar from the Microsoft Store.'
    'Connect an Xbox / XInput controller and verify input.'
    'Open Settings > Gaming > Xbox mode.'
    'On desktop/laptop: turn on "Enable Xbox mode". Optionally show Xbox mode in Task View.'
    'On gaming handhelds: choose a home app and optionally enable "Enter Xbox mode on startup".'
    'Enter Xbox mode via Game Bar, Task View, or Win+F11.'
    'Validate game launchers and Store sign-in before declaring success.'
)

$status = [ordered]@{
    mode                      = $Mode
    xboxModeClaimedWorking    = $false
    explorerShellReplaced     = $false
    startupToGamingHomeApplied = $false
    documentation             = @{
        fseSupport = 'https://support.microsoft.com/en-us/servicing/os/windows/docs/2025/10/windows-gaming-full-screen-experience'
        unattend   = 'https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-gaming-configuration-startuptogaminghome'
    }
    findings                  = @(
        'StartupToGamingHome is a documented Microsoft-Windows-Gaming-Configuration unattend boolean.'
        'Valid configuration passes: offlineServicing, specialize, oobeSystem.'
        'Desktop PCs should use Settings UI unless OEM unattend behavior is validated on the target build.'
        'Do not assume handheld defaults apply to desktop form factors.'
    )
    manualSteps               = $manualSteps
    actions                   = New-Object System.Collections.Generic.List[object]
}

if ($GenerateUnattendSnippet) {
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }
    $snippetPath = Join-Path $OutputDirectory 'StartupToGamingHome-snippet.xml'
    $snippet = @'
<!-- Optional OEM unattend fragment. Validate on target image before use.
     Parent: Microsoft-Windows-Gaming-Configuration
     Setting: StartupToGamingHome (boolean)
     Passes: offlineServicing | specialize | oobeSystem -->
<StartupToGamingHome>true</StartupToGamingHome>
'@
    if ($PSCmdlet.ShouldProcess($snippetPath, 'Write unattend snippet')) {
        Set-Content -LiteralPath $snippetPath -Value $snippet -Encoding UTF8
        $status.actions.Add([pscustomobject]@{ Action = 'WriteUnattendSnippet'; Path = $snippetPath; Status = 'Wrote' }) | Out-Null
    }
}

if ($Mode -eq 'AttemptSupportedSettings') {
    # Conservative: only open the supported Settings page when available; never force shell replacement.
    $settingsUri = 'ms-settings:gaming-xboxmode'
    try {
        if ($PSCmdlet.ShouldProcess($settingsUri, 'Launch Xbox mode settings page')) {
            Start-Process $settingsUri
            $status.actions.Add([pscustomobject]@{ Action = 'OpenSettings'; Status = 'Launched'; Uri = $settingsUri }) | Out-Null
        }
    }
    catch {
        $status.actions.Add([pscustomobject]@{ Action = 'OpenSettings'; Status = 'Failed'; Message = $_.Exception.Message }) | Out-Null
        Write-Warning 'Could not open ms-settings:gaming-xboxmode. Use Settings > Gaming > Xbox mode manually.'
    }
}
else {
    $status.actions.Add([pscustomobject]@{ Action = 'DocumentOnly'; Status = 'No automatic startup configuration applied' }) | Out-Null
}

Write-Host 'Xbox mode setup (conservative)'
Write-Host '------------------------------'
Write-Host 'Xbox mode is NOT claimed working until validated on an installed system.'
Write-Host ''
Write-Host 'Manual configuration workflow:'
foreach ($step in $manualSteps) { Write-Host " - $step" }

if ($PassThru) {
    return [pscustomobject]$status
}
