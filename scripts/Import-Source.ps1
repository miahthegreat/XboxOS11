#Requires -Version 5.1
<#
.SYNOPSIS
    Imports an official Windows 11 ISO into an isolated workspace and exports the selected edition WIM.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SourceISO,

    [Parameter(Mandatory)]
    [object]$Context,

    [string]$DismPath,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
Import-Module $modulePath -Force

if (-not $DismPath) { $DismPath = Find-XboxOSDism }
if (-not $DismPath) { throw 'DISM is required for Import-Source.' }

$isoPath = Resolve-XboxOSPath -Path $SourceISO
if (-not (Test-Path -LiteralPath $isoPath)) {
    throw "Source ISO not found: $isoPath"
}

$config = $Context.Configuration.Raw
$edition = [string]$config.target.edition
$arch = [string]$config.target.architecture
$pattern = [string]$config.target.imageNamePattern
if ([string]::IsNullOrWhiteSpace($pattern)) { $pattern = "*$edition*" }

Write-XboxOSLog -Level Information -Message "Importing source ISO: $isoPath"

$hash = $null
if (-not $DryRun) {
    $hash = Get-XboxOSFileHash -Path $isoPath -Algorithm SHA256
    Write-XboxOSLog -Level Information -Message "Source SHA256: $($hash.Hash)"
}
else {
    Write-XboxOSLog -Level Information -Message 'DryRun: skipping SHA-256 calculation and ISO mount/copy.'
}

$mountedIso = $null
$mountResult = $null
try {
    if ($DryRun) {
        $meta = [pscustomobject]@{
            SourceISO     = $isoPath
            Sha256        = $null
            ImageFile     = '(dry-run)'
            ImageFormat   = 'wim'
            SelectedIndex = $null
            Edition       = $edition
            Architecture  = $arch
            Images        = @()
            DryRun        = $true
        }
        $Context.SourceMeta = $meta
        return $meta
    }

    $mountResult = Mount-DiskImage -ImagePath $isoPath -StorageType ISO -PassThru -ErrorAction Stop
    $mountedIso = $mountResult
    $Context.MountedIsoPath = $isoPath

    $volume = $mountResult | Get-Volume
    $driveRoot = "$($volume.DriveLetter):\"
    if (-not $volume.DriveLetter) {
        throw 'Mounted ISO did not receive a drive letter.'
    }

    Write-XboxOSLog -Level Information -Message "ISO mounted read-only at $driveRoot"

    $sources = Join-Path $driveRoot 'sources'
    $installWim = Join-Path $sources 'install.wim'
    $installEsd = Join-Path $sources 'install.esd'
    $imageFile = $null
    $imageFormat = $null
    if (Test-Path -LiteralPath $installWim) {
        $imageFile = $installWim
        $imageFormat = 'wim'
    }
    elseif (Test-Path -LiteralPath $installEsd) {
        $imageFile = $installEsd
        $imageFormat = 'esd'
    }
    else {
        throw 'Neither install.wim nor install.esd was found in the ISO sources folder.'
    }

    Write-XboxOSLog -Level Information -Message "Found installation image: $imageFile"

    # Copy installation tree into isolated workspace while preserving originals on the ISO.
    $dest = $Context.Paths.SourceCopy
    Write-XboxOSLog -Level Information -Message "Copying installation files to $dest"
    robocopy $driveRoot $dest /E /R:2 /W:2 /NFL /NDL /NJH /NJS /NP /XJ | Out-Null
    $roboExit = $LASTEXITCODE
    if ($roboExit -ge 8) {
        throw "robocopy failed while importing ISO contents (exit $roboExit)."
    }

    # Clear read-only attributes copied from optical media.
    Get-ChildItem -LiteralPath $dest -Recurse -Force | ForEach-Object {
        if ($_.Attributes -band [IO.FileAttributes]::ReadOnly) {
            $_.Attributes = $_.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
        }
    }

    $localImage = Join-Path $dest ("sources\install.{0}" -f $imageFormat)
    if (-not (Test-Path -LiteralPath $localImage)) {
        throw "Copied image file missing: $localImage"
    }

    $images = Get-XboxOSImageInfo -ImagePath $localImage -DismPath $DismPath
    if (-not $images -or $images.Count -eq 0) {
        throw "DISM did not return image indexes for $localImage"
    }

    Write-XboxOSLog -Level Information -Message "Available editions: $(($images | ForEach-Object { "$($_.Index)=$($_.Name)" }) -join '; ')"

    $selected = @($images | Where-Object {
            $_.Name -eq $edition -or
            $_.Name -like $pattern -or
            ($_.Description -and ($_.Description -eq $edition -or $_.Description -like $pattern))
        })

    if ($selected.Count -eq 0) {
        $available = ($images | ForEach-Object { "$($_.Index): $($_.Name)" }) -join '; '
        throw "Requested edition '$edition' (pattern '$pattern') was not found. Available: $available"
    }
    if ($selected.Count -gt 1) {
        # Prefer exact edition name match
        $exact = @($selected | Where-Object { $_.Name -eq $edition })
        if ($exact.Count -eq 1) {
            $selected = $exact
        }
        else {
            throw "Multiple editions matched '$edition' / '$pattern'. Narrow target.edition or imageNamePattern. Matches: $(($selected | ForEach-Object Name) -join ', ')"
        }
    }

    $chosen = $selected[0]
    $chosenArch = if ($chosen.Architecture) { $chosen.Architecture } else { $arch }
    $normalizedArch = $chosenArch.ToLowerInvariant()
    if ($normalizedArch -eq 'x64') { $normalizedArch = 'amd64' }
    $targetArch = $arch.ToLowerInvariant()
    if ($targetArch -eq 'x64') { $targetArch = 'amd64' }
    if ($normalizedArch -and $normalizedArch -ne $targetArch) {
        throw "Selected image architecture '$chosenArch' does not match configured '$arch'."
    }

    $workingWim = $Context.Paths.WorkingWim
    Write-XboxOSLog -Level Information -Message "Exporting index $($chosen.Index) ($($chosen.Name)) to $workingWim"
    Invoke-XboxOSDism -DismPath $DismPath -ArgumentList @(
        '/Export-Image'
        "/SourceImageFile:$localImage"
        "/SourceIndex:$($chosen.Index)"
        "/DestinationImageFile:$workingWim"
        '/Compress:max'
        '/CheckIntegrity'
    ) | Out-Null

    # Prefer install.wim in the source tree for ISO export later.
    $treeWim = Join-Path $dest 'sources\install.wim'
    if ($localImage -ne $treeWim) {
        if (Test-Path -LiteralPath (Join-Path $dest 'sources\install.esd')) {
            Remove-Item -LiteralPath (Join-Path $dest 'sources\install.esd') -Force
        }
    }
    Copy-Item -LiteralPath $workingWim -Destination $treeWim -Force

    $meta = [pscustomobject]@{
        SourceISO     = $isoPath
        Sha256        = $hash.Hash
        ImageFile     = $workingWim
        SourceTree    = $dest
        ImageFormat   = 'wim'
        SelectedIndex = 1
        SourceIndex   = $chosen.Index
        Edition       = $chosen.Name
        Description   = $chosen.Description
        Architecture  = $chosenArch
        Images        = $images
        DryRun        = $false
    }

    $Context.SourceMeta = $meta
    $meta | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Context.Paths.Reports 'SourceMeta.json') -Encoding UTF8
    Write-XboxOSLog -Level Information -Message "Source import complete: $($chosen.Name)"
    return $meta
}
finally {
    if ($mountedIso) {
        try {
            Dismount-DiskImage -ImagePath $isoPath -ErrorAction Stop | Out-Null
            Write-XboxOSLog -Level Information -Message 'Source ISO dismounted.'
        }
        catch {
            Write-XboxOSLog -Level Warning -Message "Failed to dismount source ISO: $($_.Exception.Message)"
        }
        finally {
            $Context.MountedIsoPath = $null
        }
    }
}
