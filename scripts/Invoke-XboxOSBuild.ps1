#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a customized Windows 11 ISO from a saved XboxOS11 Builder profile.
.DESCRIPTION
    1. Imports and validates the profile (strict schema, protected components, supported settings only).
    2. Materializes an effective build configuration and media overlay outside the repository.
    3. Runs Build-ISO.ps1 with that configuration.

    With -EmitEvents, progress is written as XBOXOS-EVENT JSON lines for the native Builder.
    Exit codes: 0 success, 1 failure, 4 invalid profile.
.EXAMPLE
    .\scripts\Invoke-XboxOSBuild.ps1 -ProfilePath 'C:\XboxOS\Profiles\my-rig.json' -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProfilePath,
    [switch]$DryRun,
    [switch]$EmitEvents,
    [string]$WorkRoot = 'C:\XboxOS\Work\profiles',
    [switch]$SkipPrerequisites,
    [switch]$KeepWorkspaceOnSuccess
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force

function Send-BuildEvent {
    param([string]$Type, [hashtable]$Data = @{})
    if ($EmitEvents) { $null = Write-XboxOSBuilderEvent -Type $Type -Data $Data }
}

Send-BuildEvent -Type started -Data @{ profilePath = $ProfilePath; dryRun = [bool]$DryRun; engineVersion = (Get-XboxOSBuilderEngineVersion) }

try {
    $buildProfile = Import-XboxOSBuildProfile -Path $ProfilePath
    $check = Test-XboxOSBuildProfile -BuildProfile $buildProfile -ForBuild:(-not $DryRun)
    if ($check.valid -and [string]::IsNullOrWhiteSpace([string]$buildProfile.source.isoPath)) {
        $check = [pscustomobject]@{ valid = $false; errors = @('Select a Windows 11 ISO (source.isoPath).'); warnings = $check.warnings }
    }
    Send-BuildEvent -Type validation -Data @{ valid = [bool]$check.valid; errors = @($check.errors); warnings = @($check.warnings) }
    foreach ($w in @($check.warnings)) { Write-Warning $w }
    if (-not $check.valid) {
        foreach ($e in @($check.errors)) { Write-Host "Profile error: $e" -ForegroundColor Red }
        Send-BuildEvent -Type failed -Data @{ stage = 'validation'; message = 'Build profile is invalid.' }
        exit 4
    }

    $effective = New-XboxOSBuilderEffectiveConfiguration -BuildProfile $buildProfile -WorkRoot $WorkRoot -ForBuild:(-not $DryRun)
    Send-BuildEvent -Type log -Data @{ message = 'Effective configuration generated.'; configurationPath = $effective.ConfigurationPath; profileHash = $effective.ProfileHash; overlayFiles = @($effective.MediaOverlayFiles) }

    $buildArgs = @{
        SourceISO              = [string]$buildProfile.source.isoPath
        Configuration          = $effective.ConfigurationPath
        OutputDirectory        = [string]$buildProfile.output.directory
        DryRun                 = [bool]$DryRun
        SkipPrerequisites      = [bool]$SkipPrerequisites
        KeepWorkspaceOnSuccess = [bool]$KeepWorkspaceOnSuccess
        EmitEvents             = [bool]$EmitEvents
    }
    if ($effective.MediaOverlayDirectory) { $buildArgs['MediaOverlayDirectory'] = $effective.MediaOverlayDirectory }

    & (Join-Path $PSScriptRoot 'Build-ISO.ps1') @buildArgs

    $iso = $null
    if (-not $DryRun) {
        $iso = Get-ChildItem -LiteralPath ([string]$buildProfile.output.directory) -Filter '*.iso' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    }
    Send-BuildEvent -Type completed -Data @{
        dryRun          = [bool]$DryRun
        outputDirectory = [string]$buildProfile.output.directory
        isoPath         = $(if ($iso) { $iso.FullName } else { $null })
        profileHash     = $effective.ProfileHash
    }
    exit 0
}
catch {
    Write-Host ("Build failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Send-BuildEvent -Type failed -Data @{ stage = 'build'; message = $_.Exception.Message }
    exit 1
}
