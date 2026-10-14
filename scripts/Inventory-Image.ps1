#Requires -Version 5.1
<#
.SYNOPSIS
    Inventories a mounted Windows image and writes machine-readable JSON.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Alias('Context')]
    [object]$BuildContext,

    [ValidateSet('Before', 'After', 'AdHoc')]
    [string]$Stage = 'AdHoc',

    [string]$DismPath,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
Import-Module $modulePath -Force

if (-not $DismPath) { $DismPath = Find-XboxOSDism }
$mount = $BuildContext.Paths.Mount

if ($DryRun -or -not $BuildContext.ImageMounted) {
    $inventory = [ordered]@{
        stage                 = $Stage
        dryRun                = [bool]$DryRun
        mountPath             = $mount
        edition               = $(if ($BuildContext.SourceMeta) { $BuildContext.SourceMeta.Edition } else { $null })
        architecture          = $BuildContext.Configuration.Raw.target.architecture
        inventoryAvailability = 'Unknown'
        appxPackages          = $null
        features              = $null
        packages              = $null
        drivers               = $null
        capabilities          = $null
        servicingState        = 'NotCaptured'
        capturedUtc           = (Get-Date).ToUniversalTime()
        notes                 = 'Dry-run / unmounted image: inventories are unknown, not empty.'
    }

    $BuildContext.AppxInventoryState = 'Unknown'
    $BuildContext.FeatureInventoryState = 'Unknown'
    $BuildContext.AppxInventory = $null
    $BuildContext.FeatureInventory = $null
}
else {
    $null = Assert-XboxOSServicingPathSafety -Path $mount -RepoRoot $BuildContext.Configuration.RepoRoot -Purpose 'image inventory'
    if (-not (Test-Path -LiteralPath $mount)) {
        throw "Mount path not found: $mount"
    }

    Write-XboxOSLog -Level Information -Message "Inventorying mounted image ($Stage)"

    $appxOut = Invoke-XboxOSDism -DismPath $DismPath -ArgumentList @('/Image:' + $mount, '/Get-ProvisionedAppxPackages')
    $featOut = Invoke-XboxOSDism -DismPath $DismPath -ArgumentList @('/Image:' + $mount, '/Get-Features')
    $pkgOut = Invoke-XboxOSDism -DismPath $DismPath -ArgumentList @('/Image:' + $mount, '/Get-Packages')
    $drvOut = Invoke-XboxOSDism -DismPath $DismPath -ArgumentList @('/Image:' + $mount, '/Get-Drivers')
    $capOut = $null
    try {
        $capOut = Invoke-XboxOSDism -DismPath $DismPath -ArgumentList @('/Image:' + $mount, '/Get-Capabilities')
    }
    catch {
        Write-XboxOSLog -Level Warning -Message "Get-Capabilities unavailable: $($_.Exception.Message)"
    }

    $edition = $null
    $build = $null
    $displayVersion = $null
    $productName = $null
    try {
        $info = Invoke-XboxOSDism -DismPath $DismPath -ArgumentList @('/Image:' + $mount, '/Get-CurrentEdition')
        foreach ($line in $info.Output) {
            if ($line -match 'Current Edition\s*:\s*(.+)$') { $edition = $Matches[1].Trim() }
        }
    }
    catch {
        Write-XboxOSLog -Level Warning -Message "Get-CurrentEdition failed: $($_.Exception.Message)"
    }

    $hive = Join-Path $mount 'Windows\System32\config\SOFTWARE'
    if (Test-Path -LiteralPath $hive) {
        $tempHive = 'HKLM\XboxOSInventory'
        try {
            $regLoad = & reg.exe load $tempHive $hive 2>&1
            if ($LASTEXITCODE -ne 0) { throw "reg load failed ($LASTEXITCODE): $($regLoad -join ' ')" }
            $cv = Get-ItemProperty -Path 'HKLM:\XboxOSInventory\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
            $build = [string]$cv.CurrentBuild
            if ($cv.UBR) { $build = "$build.$($cv.UBR)" }
            if (-not $edition -and $cv.EditionID) { $edition = [string]$cv.EditionID }
            if ($cv.DisplayVersion) { $displayVersion = [string]$cv.DisplayVersion }
            if ($cv.ProductName) { $productName = [string]$cv.ProductName }
        }
        catch {
            Write-XboxOSLog -Level Warning -Message "Registry inventory read failed: $($_.Exception.Message)"
        }
        finally {
            & reg.exe unload $tempHive 2>$null | Out-Null
        }
    }

    $appxRecords = @(ConvertFrom-XboxOSDismProvisionedAppxListOutput -Output @($appxOut.Output))
    $featureRecords = @(ConvertFrom-XboxOSDismFeatureListOutput -Output @($featOut.Output))
    $packageRecords = @(ConvertFrom-XboxOSDismPackageListOutput -Output @($pkgOut.Output))
    $appx = [string[]]@($appxRecords | ForEach-Object { [string]$_.PackageName })
    $features = [string[]]@($featureRecords | ForEach-Object { [string]$_.Name })
    $packages = [string[]]@($packageRecords | ForEach-Object { [string]$_.Identity })
    $drivers = [string[]]@(Get-XboxOSDismListedValues -Output @($drvOut.Output) -Label 'Published Name')
    $capabilities = if ($capOut) {
        [string[]]@(Get-XboxOSDismListedValues -Output @($capOut.Output) -Label 'Capability Identity')
    } else {
        @()
    }

    $inventory = [ordered]@{
        stage                 = $Stage
        dryRun                = $false
        mountPath             = $mount
        edition               = $edition
        build                 = $build
        displayVersion        = $displayVersion
        productName           = $productName
        architecture          = $BuildContext.Configuration.Raw.target.architecture
        inventoryAvailability = 'Available'
        appxPackages          = $appx
        appxPackageRecords    = $appxRecords
        features              = $features
        featureRecords        = $featureRecords
        packages              = $packages
        packageRecords        = $packageRecords
        drivers               = $drivers
        capabilities          = $capabilities
        servicingState        = 'Captured'
        capturedUtc           = (Get-Date).ToUniversalTime()
    }

    $BuildContext.AppxInventory = $appx
    $BuildContext.FeatureInventory = $features
    $BuildContext.AppxInventoryState = if ($appx.Count -eq 0) { 'Empty' } else { 'Available' }
    $BuildContext.FeatureInventoryState = if ($features.Count -eq 0) { 'Empty' } else { 'Available' }
}

$fileName = "Inventory-$Stage.json"
$outPath = Join-Path $BuildContext.Paths.Reports $fileName
($inventory | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $outPath -Encoding UTF8

if ($Stage -eq 'Before') { $BuildContext.InventoryBefore = $outPath }
elseif ($Stage -eq 'After') { $BuildContext.InventoryAfter = $outPath }

Write-XboxOSLog -Level Information -Message "Inventory written: $outPath (availability=$($inventory.inventoryAvailability))"
return [pscustomobject]$inventory
