#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a UEFI-bootable Windows installation ISO using Microsoft Oscdimg.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [object]$Context,

    [string]$OscdimgPath,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
Import-Module $modulePath -Force

$adk = Find-XboxOSAdkTools
if (-not $OscdimgPath) { $OscdimgPath = $adk.Oscdimg }
if ($DryRun -and (-not $OscdimgPath -or -not (Test-Path -LiteralPath $OscdimgPath))) {
    # A dry run never invokes oscdimg; report the planned command without requiring ADK.
    Write-XboxOSLog -Level Warning -Message 'DryRun: oscdimg.exe (Windows ADK Deployment Tools) not found; a real build will require it.'
    $OscdimgPath = 'oscdimg.exe'
}
elseif (-not $OscdimgPath -or -not (Test-Path -LiteralPath $OscdimgPath)) {
    throw @'
oscdimg.exe was not found. Install Windows ADK Deployment Tools:
https://learn.microsoft.com/windows-hardware/get-started/adk-install
Then re-run Test-Prerequisites.ps1.
'@
}

$config = $Context.Configuration.Raw
$sourceTree = $Context.Paths.SourceCopy
$workingWim = $Context.Paths.WorkingWim

$displayVersion = $null
$buildNumber = $null
$editionName = $null
if ($Context.SourceMeta) {
    if ($Context.SourceMeta.PSObject.Properties.Name -contains 'Edition') { $editionName = [string]$Context.SourceMeta.Edition }
    if ($Context.SourceMeta.PSObject.Properties.Name -contains 'BuildNumber') { $buildNumber = [string]$Context.SourceMeta.BuildNumber }
    if ($Context.SourceMeta.PSObject.Properties.Name -contains 'DisplayVersion') { $displayVersion = [string]$Context.SourceMeta.DisplayVersion }
}
# Prefer verified inventory metadata over assumed config release labels (e.g. do not invent 25H2 from 26300.9457).
if ($Context.InventoryAfter -and (Test-Path -LiteralPath $Context.InventoryAfter)) {
    try {
        $inv = Get-Content -LiteralPath $Context.InventoryAfter -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($inv.PSObject.Properties.Name -contains 'build' -and $inv.build) { $buildNumber = [string]$inv.build }
        if ($inv.PSObject.Properties.Name -contains 'displayVersion' -and $inv.displayVersion) { $displayVersion = [string]$inv.displayVersion }
        if ($inv.PSObject.Properties.Name -contains 'edition' -and $inv.edition) { $editionName = [string]$inv.edition }
    }
    catch {
        Write-XboxOSLog -Level Warning -Message "Could not read inventory metadata for ISO naming: $($_.Exception.Message)"
    }
}

$isoName = Get-XboxOSIsoFileName -Configuration $config -DisplayVersion $displayVersion -BuildNumber $buildNumber -Edition $editionName
Write-XboxOSLog -Level Information -Message "Resolved ISO file name '$isoName' from verified metadata (DisplayVersion='$displayVersion', Build='$buildNumber', Edition='$editionName')."
$isoPath = Join-Path $Context.Paths.Output $isoName
$threshold = [int64]$config.iso.splitWimThresholdBytes
if ($threshold -le 0) { $threshold = 4294967295 }

if (-not $DryRun) {
    if (-not (Test-Path -LiteralPath $sourceTree)) {
        throw "Source tree missing: $sourceTree"
    }
    if (-not (Test-Path -LiteralPath $workingWim)) {
        throw "Working WIM missing: $workingWim"
    }

    $destWim = Join-Path $sourceTree 'sources\install.wim'
    Copy-Item -LiteralPath $workingWim -Destination $destWim -Force

    $wimItem = Get-Item -LiteralPath $destWim
    if ($wimItem.Length -gt $threshold) {
        Write-XboxOSLog -Level Information -Message 'install.wim exceeds FAT32 single-file limit; creating split SWM set.'
        $swm = Join-Path $sourceTree 'sources\install.swm'
        if (Test-Path -LiteralPath $swm) {
            Remove-Item -LiteralPath (Join-Path $sourceTree 'sources\install*.swm') -Force -ErrorAction SilentlyContinue
        }
        $dism = Find-XboxOSDism
        Invoke-XboxOSDism -DismPath $dism -ArgumentList @(
            '/Split-Image'
            "/ImageFile:$destWim"
            "/SWMFile:$swm"
            '/FileSize:4096'
        ) | Out-Null
        Remove-Item -LiteralPath $destWim -Force
    }
}

$overlayDir = $null
if ($Context.PSObject.Properties.Name -contains 'MediaOverlayDirectory' -and $Context.MediaOverlayDirectory) {
    $overlayDir = [string]$Context.MediaOverlayDirectory
    $overlayCheck = Test-XboxOSMediaOverlay -Directory $overlayDir
    if (-not $overlayCheck.valid) {
        throw ("Media overlay rejected:`n - " + ($overlayCheck.errors -join "`n - "))
    }
    if ($DryRun) {
        Write-XboxOSLog -Level Information -Message ("DryRun: would copy media overlay files: {0}" -f ($overlayCheck.files -join ', '))
    }
    else {
        foreach ($rel in $overlayCheck.files) {
            $dest = Join-Path $sourceTree $rel
            New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $overlayDir $rel) -Destination $dest -Force
        }
        Write-XboxOSLog -Level Information -Message ("Copied {0} media overlay file(s) onto the ISO tree." -f @($overlayCheck.files).Count)
    }
}

$bootData = $null
if (-not $DryRun) {
    $bootData = New-XboxOSIsoBootData -SourceTree $sourceTree
}
else {
    $bootData = '-bootdata:2#p0,e,b{boot}\etfsboot.com#pEF,e,b{efi}\efisys.bin'
}

$label = ConvertTo-XboxOSSafeFileName -Name ([string]$config.iso.label)
$argList = @(
    '-m'
    '-o'
    '-u2'
    '-udfver102'
    "-l$label"
    $bootData
    $sourceTree
    $isoPath
)

$display = "$OscdimgPath $($argList -join ' ')"
Write-XboxOSLog -Level Information -Message "Oscdimg: $display"

if ($DryRun) {
    Write-XboxOSLog -Level Information -Message 'DryRun: skipping ISO generation.'
    $result = [pscustomobject]@{
        IsoPath = $isoPath
        Sha256  = $null
        Size    = 0
        DryRun  = $true
        Command = $display
    }
    $result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Context.Paths.Reports 'ExportIso.json') -Encoding UTF8
    return $result
}

$output = & $OscdimgPath @argList 2>&1
$exit = $LASTEXITCODE
$text = @($output | ForEach-Object { "$_" })
$text | ForEach-Object { Write-XboxOSLog -Level Debug -Message $_ }

if ($exit -ne 0) {
    throw "oscdimg failed with exit code $exit`n$($text -join "`n")"
}

if (-not (Test-Path -LiteralPath $isoPath)) {
    throw "ISO was not created: $isoPath"
}

$isoItem = Get-Item -LiteralPath $isoPath
if ($isoItem.Length -le 0) {
    throw "ISO has zero size: $isoPath"
}

$hash = Get-XboxOSFileHash -Path $isoPath -Algorithm SHA256
Write-XboxOSLog -Level Information -Message "ISO created: $isoPath ($($isoItem.Length) bytes) SHA256=$($hash.Hash)"

$result = [pscustomobject]@{
    IsoPath = $isoPath
    Sha256  = $hash.Hash
    Size    = $isoItem.Length
    DryRun  = $false
    Command = $display
}
$result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Context.Paths.Reports 'ExportIso.json') -Encoding UTF8
return $result
