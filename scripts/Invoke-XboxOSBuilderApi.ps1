#Requires -Version 5.1
<#
.SYNOPSIS
    Stable JSON request/response surface for the native XboxOS11 Builder frontend.
.DESCRIPTION
    Writes exactly one result line: 'XBOXOS-RESULT ' followed by compact JSON:
      { "ok": true,  "command": "...", "data": { ... } }
      { "ok": false, "command": "...", "error": "..." }
    Other host output may appear; clients must parse only the XBOXOS-RESULT line.

    Commands:
      catalog                                   Presets, launchers, privacy options, schema versions
      new-profile  -PresetId -Name [-SourceIso] [-OutputPath]   New profile (optionally saved)
      validate     -ProfilePath [-ForBuild]     Validation errors / warnings
      review       -ProfilePath                 Dependency-aware component review
      unattend     -ProfilePath                 Generated autounattend.xml text
      save-profile (-ProfileJson | -ProfilePath) -OutputPath   Validate and save a client-supplied profile
      image-info   -SourceIso                   Editions in the ISO (read-only; requires elevation)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('catalog', 'new-profile', 'validate', 'review', 'unattend', 'save-profile', 'image-info')]
    [string]$Command,
    [string]$ProfilePath,
    [string]$ProfileJson,
    [string]$PresetId = 'gaming-balanced',
    [string]$Name = 'My XboxOS11 build',
    [string]$SourceIso,
    [string]$OutputPath,
    [switch]$ForBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot

function Write-ApiResult {
    param([bool]$Ok, [object]$Data = $null, [string]$ErrorMessage = '')
    $doc = [ordered]@{ ok = $Ok; command = $Command; apiVersion = 'xboxos-builder-api-v1' }
    if ($Ok) { $doc['data'] = $Data } else { $doc['error'] = $ErrorMessage }
    Write-Output ('XBOXOS-RESULT ' + ($doc | ConvertTo-Json -Compress -Depth 12))
}

try {
    Import-Module (Join-Path $repoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force
    $data = $null
    switch ($Command) {
        'catalog' {
            $data = [ordered]@{
                engineVersion        = Get-XboxOSBuilderEngineVersion
                toolkitVersion       = Get-XboxOSToolkitVersion
                profileSchemaVersion = Get-XboxOSBuildProfileSchemaVersion
                presets              = @(Get-XboxOSBuilderPreset | ForEach-Object {
                        [ordered]@{ id = $_.id; displayName = $_.displayName; description = $_.description; recommended = [bool]$_.recommended; order = [int]$_.order }
                    })
                launchers            = @(Get-XboxOSBuilderLauncherCatalog)
                optimizations        = @((Get-XboxOSGamingTweakCatalog).tweaks | Where-Object { -not $_.PSObject.Properties['profileField'] } | ForEach-Object {
                        [ordered]@{
                            id = [string]$_.id; title = [string]$_.title; description = [string]$_.description; scope = [string]$_.scope
                            requiresRestart = [bool]$_.requiresRestart; defaultEnabled = [bool]$_.defaultEnabled; settingsPage = [string]$_.settingsPage
                        }
                    })
                neverChange          = @((Get-XboxOSGamingTweakCatalog).neverChange | ForEach-Object { [ordered]@{ item = [string]$_.item; reason = [string]$_.reason } })
                privacyOptions       = @('Minimal', 'Recommended')
                compressionModes     = @(Get-XboxOSImageCompressionModes)
                defaultOutput        = 'C:\XboxOS\Output'
                defaultProfileFolder = 'C:\XboxOS\Profiles'
            }
        }
        'new-profile' {
            $p = New-XboxOSBuildProfile -Name $Name -PresetId $PresetId -SourceIso $SourceIso
            if ($OutputPath) { $null = Export-XboxOSBuildProfile -BuildProfile $p -Path $OutputPath }
            $data = $p
        }
        'validate' {
            if (-not $ProfilePath) { throw '-ProfilePath is required.' }
            $data = Test-XboxOSBuildProfile -BuildProfile (Import-XboxOSBuildProfile -Path $ProfilePath) -ForBuild:$ForBuild
        }
        'review' {
            if (-not $ProfilePath) { throw '-ProfilePath is required.' }
            $data = Get-XboxOSBuildProfileReview -BuildProfile (Import-XboxOSBuildProfile -Path $ProfilePath)
        }
        'unattend' {
            if (-not $ProfilePath) { throw '-ProfilePath is required.' }
            $data = [ordered]@{ xml = New-XboxOSUnattendXml -BuildProfile (Import-XboxOSBuildProfile -Path $ProfilePath) }
        }
        'save-profile' {
            if ((-not $ProfileJson -and -not $ProfilePath) -or -not $OutputPath) { throw '-ProfileJson or -ProfilePath, and -OutputPath, are required.' }
            $p = if ($ProfilePath) { Import-XboxOSBuildProfile -Path $ProfilePath } else { $ProfileJson | ConvertFrom-Json }
            $check = Test-XboxOSBuildProfile -BuildProfile $p
            if (-not $check.valid) { throw ("Profile is invalid: " + ($check.errors -join '; ')) }
            $data = [ordered]@{ path = Export-XboxOSBuildProfile -BuildProfile $p -Path $OutputPath; warnings = @($check.warnings) }
        }
        'image-info' {
            if (-not $SourceIso) { throw '-SourceIso is required.' }
            if (-not (Test-Path -LiteralPath $SourceIso -PathType Leaf)) { throw "ISO not found: $SourceIso" }
            if (-not (Test-XboxOSAdministrator)) { throw 'Reading ISO editions requires an elevated (Administrator) session.' }
            $mount = Mount-DiskImage -ImagePath $SourceIso -Access ReadOnly -StorageType ISO -PassThru
            try {
                $letter = ($mount | Get-Volume).DriveLetter
                $wim = @("${letter}:\sources\install.wim", "${letter}:\sources\install.esd") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
                if (-not $wim) { throw 'No install.wim or install.esd found; is this a Windows 11 installation ISO?' }
                $data = [ordered]@{
                    imageFile = Split-Path -Leaf $wim
                    images    = @(Get-WindowsImage -ImagePath $wim | ForEach-Object {
                            [ordered]@{ index = [int]$_.ImageIndex; name = [string]$_.ImageName; sizeBytes = [int64]$_.ImageSize }
                        })
                }
            }
            finally {
                Dismount-DiskImage -ImagePath $SourceIso | Out-Null
            }
        }
    }
    Write-ApiResult -Ok $true -Data $data
    exit 0
}
catch {
    Write-ApiResult -Ok $false -ErrorMessage $_.Exception.Message
    exit 1
}
