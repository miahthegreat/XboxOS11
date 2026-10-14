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
if (-not $OscdimgPath -or -not (Test-Path -LiteralPath $OscdimgPath)) {
    throw @'
oscdimg.exe was not found. Install Windows ADK Deployment Tools:
https://learn.microsoft.com/windows-hardware/get-started/adk-install
Then re-run Test-Prerequisites.ps1.
'@
}

$config = $Context.Configuration.Raw
$sourceTree = $Context.Paths.SourceCopy
$workingWim = $Context.Paths.WorkingWim
$isoName = ConvertTo-XboxOSSafeFileName -Name ([string]$config.iso.fileName)
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
