#Requires -Version 5.1
<#
.SYNOPSIS
    Inventories a mounted Windows image and writes machine-readable JSON.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [object]$Context,

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
$mount = $Context.Paths.Mount

function Get-DismListedNames {
    param([string[]]$Output, [string]$Label)
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Output) {
        if ($line -match ("^\s*{0}\s*:\s*(.+)$" -f [regex]::Escape($Label))) {
            $names.Add($Matches[1].Trim()) | Out-Null
        }
    }
    return $names.ToArray()
}

if ($DryRun) {
    $inventory = [ordered]@{
        stage          = $Stage
        dryRun         = $true
        mountPath      = $mount
        edition        = $Context.SourceMeta.Edition
        architecture   = $Context.Configuration.Raw.target.architecture
        appxPackages   = @()
        features       = @()
        packages       = @()
        drivers        = @()
        capabilities   = @()
        servicingState = 'DryRun'
        capturedUtc    = (Get-Date).ToUniversalTime()
    }
}
else {
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
            reg.exe load $tempHive $hive | Out-Null
            $cv = Get-ItemProperty -Path 'HKLM:\XboxOSInventory\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
            $build = [string]$cv.CurrentBuild
            if ($cv.UBR) { $build = "$build.$($cv.UBR)" }
            if (-not $edition -and $cv.EditionID) { $edition = [string]$cv.EditionID }
        }
        catch {
            Write-XboxOSLog -Level Warning -Message "Registry inventory read failed: $($_.Exception.Message)"
        }
        finally {
            reg.exe unload $tempHive 2>$null | Out-Null
        }
    }

    $inventory = [ordered]@{
        stage          = $Stage
        dryRun         = $false
        mountPath      = $mount
        edition        = $edition
        build          = $build
        architecture   = $Context.Configuration.Raw.target.architecture
        appxPackages   = @(Get-DismListedNames -Output $appxOut.Output -Label 'PackageName')
        features       = @(Get-DismListedNames -Output $featOut.Output -Label 'Feature Name')
        packages       = @(Get-DismListedNames -Output $pkgOut.Output -Label 'Package Identity')
        drivers        = @(Get-DismListedNames -Output $drvOut.Output -Label 'Published Name')
        capabilities   = $(if ($capOut) { @(Get-DismListedNames -Output $capOut.Output -Label 'Capability Identity') } else { @() })
        servicingState = 'Captured'
        capturedUtc    = (Get-Date).ToUniversalTime()
    }
}

$fileName = "Inventory-$Stage.json"
$outPath = Join-Path $Context.Paths.Reports $fileName
($inventory | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $outPath -Encoding UTF8

if ($Stage -eq 'Before') { $Context.InventoryBefore = $outPath }
elseif ($Stage -eq 'After') { $Context.InventoryAfter = $outPath }

Write-XboxOSLog -Level Information -Message "Inventory written: $outPath"
return [pscustomobject]$inventory
