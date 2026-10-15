#Requires -Version 5.1
<#
.SYNOPSIS
    Reviews and undoes what an XboxOS11 image changed, using the build record staged on the installed PC.
.DESCRIPTION
    Reads build-record.json (next to this script in %WINDIR%\Setup\Scripts\XboxOS11, or
    C:\ProgramData\XboxOS11) and can:

      -Features        Re-enable optional features the build disabled (payloads were kept, so no media is
                       needed). Requires administrator. A restart may be required.
      -GamingSettings  Restore every gaming optimization to its recorded original value.
      -Apps            List removed apps; with -OpenStore, open each one's Microsoft Store search page
                       so you can reinstall it. Apps are never installed silently.
      -All             All of the above.

    With no action switch, prints the build record summary only. Supports -WhatIf.
    Runs under Windows PowerShell 5.1 - keep syntax 5.1-compatible.
.EXAMPLE
    .\Restore-XboxOS11Components.ps1
.EXAMPLE
    .\Restore-XboxOS11Components.ps1 -Features -GamingSettings -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Features,
    [switch]$GamingSettings,
    [switch]$Apps,
    [switch]$All,
    [switch]$OpenStore,
    [string]$RecordPath,
    [string]$StatePath = 'C:\ProgramData\XboxOS11\gaming-state.json',
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $RecordPath) {
    $candidates = @(
        (Join-Path $PSScriptRoot 'build-record.json'),
        'C:\ProgramData\XboxOS11\build-record.json'
    )
    $found = @($candidates | Where-Object { Test-Path -LiteralPath $_ })
    $RecordPath = if ($found.Count -gt 0) { [string]$found[0] } else { [string]$candidates[0] }
}
if (-not (Test-Path -LiteralPath $RecordPath)) {
    throw "No XboxOS11 build record found at $RecordPath. This PC may not have been installed from an XboxOS11 image."
}
$record = Get-Content -LiteralPath $RecordPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$record.schemaVersion -ne 'xboxos-build-record-v1') {
    throw "Unsupported build record schema: $($record.schemaVersion)"
}

if ($All) { $Features = $true; $GamingSettings = $true; $Apps = $true }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Area, [string]$Item, [string]$Status, [string]$Message = '')
    $results.Add([pscustomobject]@{ Area = $Area; Item = $Item; Status = $Status; Message = $Message }) | Out-Null
}

Write-Host ("XboxOS11 build record: profile '{0}' (preset {1}), toolkit {2}, built {3}" -f $record.profileName, $record.presetId, $record.toolkitVersion, $record.createdUtc)
Write-Host ("Removed apps: {0}" -f ((@($record.removedApps) | ForEach-Object { $_.displayName }) -join ', '))
Write-Host ("Disabled features: {0}" -f ((@($record.disabledFeatures) | ForEach-Object { @($_.featureNames) -join '/' }) -join ', '))

if ($Features) {
    foreach ($group in @($record.disabledFeatures)) {
        foreach ($name in @($group.featureNames)) {
            if (-not $isAdmin) {
                Add-Result -Area 'Feature' -Item $name -Status 'SkippedRequiresAdministrator' -Message 'Run as administrator.'
                continue
            }
            try {
                $feature = Get-WindowsOptionalFeature -Online -FeatureName $name -ErrorAction Stop
                if (-not $feature) {
                    Add-Result -Area 'Feature' -Item $name -Status 'NotPresent'
                    continue
                }
                if ([string]$feature.State -eq 'Enabled') {
                    Add-Result -Area 'Feature' -Item $name -Status 'AlreadyEnabled'
                    continue
                }
                if ($PSCmdlet.ShouldProcess($name, 'Enable Windows optional feature')) {
                    $r = Enable-WindowsOptionalFeature -Online -FeatureName $name -NoRestart -ErrorAction Stop
                    $msg = ''
                    if ($r -and $r.PSObject.Properties['RestartNeeded'] -and [bool]$r.RestartNeeded) { $msg = 'Restart required.' }
                    Add-Result -Area 'Feature' -Item $name -Status 'Enabled' -Message $msg
                }
                else {
                    Add-Result -Area 'Feature' -Item $name -Status 'WhatIf'
                }
            }
            catch {
                Add-Result -Area 'Feature' -Item $name -Status 'Failed' -Message $_.Exception.Message
            }
        }
    }
}

if ($GamingSettings) {
    $tweakScript = Join-Path $PSScriptRoot 'Set-GamingOptimizations.ps1'
    if (-not (Test-Path -LiteralPath $tweakScript)) {
        Add-Result -Area 'GamingSettings' -Item 'All' -Status 'Failed' -Message 'Set-GamingOptimizations.ps1 not found next to this script.'
    }
    elseif (-not (Test-Path -LiteralPath $StatePath)) {
        Add-Result -Area 'GamingSettings' -Item 'All' -Status 'NothingToRestore' -Message 'No recorded gaming changes.'
    }
    else {
        $restored = & $tweakScript -Restore -StatePath $StatePath -PassThru -WhatIf:$WhatIfPreference
        foreach ($t in @($restored)) { Add-Result -Area 'GamingSettings' -Item ([string]$t.Tweak) -Status ([string]$t.Status) -Message ([string]$t.Message) }
    }
}

if ($Apps) {
    foreach ($app in @($record.removedApps)) {
        $query = [uri]::EscapeDataString([string]$app.displayName)
        $uri = "ms-windows-store://search/?query=$query"
        if ($OpenStore -and $PSCmdlet.ShouldProcess([string]$app.displayName, 'Open Microsoft Store search')) {
            Start-Process $uri
            Add-Result -Area 'App' -Item ([string]$app.displayName) -Status 'StoreOpened' -Message $uri
        }
        else {
            Add-Result -Area 'App' -Item ([string]$app.displayName) -Status 'Listed' -Message "Reinstall from the Microsoft Store: $uri"
        }
    }
}

if ($results.Count -gt 0) {
    $results | Format-Table -AutoSize | Out-String | Write-Host
}
else {
    Write-Host 'Use -Features, -GamingSettings, -Apps, or -All to restore components. Add -WhatIf to preview.'
}
Write-Host 'To return to completely stock Windows, use Settings > System > Recovery > Reset this PC, or reinstall from official Microsoft media.'
if ($PassThru) { return $results.ToArray() }
