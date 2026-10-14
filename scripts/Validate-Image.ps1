#Requires -Version 5.1
<#
.SYNOPSIS
    Validates the customized Windows image and writes JSON + text reports.
.NOTES
    A successful DISM run does not prove the image is bootable or Xbox-mode ready.
#>
[CmdletBinding()]
param(
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
$config = $Context.Configuration.Raw
$compatibility = Import-XboxOSManifest -Path $Context.Configuration.ResolvedPath.compatibilityManifest
$checks = New-Object System.Collections.Generic.List[object]

function Add-ValidationCheck {
    param($Name, $Passed, $Message, $Severity = 'Error')
    $checks.Add([pscustomobject]@{
        Name     = $Name
        Passed   = [bool]$Passed
        Message  = $Message
        Severity = $Severity
    }) | Out-Null
}

$wim = $Context.Paths.WorkingWim
$wimExists = $DryRun -or (Test-Path -LiteralPath $wim)
Add-ValidationCheck -Name 'WimExists' -Passed $wimExists -Message $(if ($wimExists) { "Working WIM present: $wim" } else { "Working WIM missing: $wim" })

if ($wimExists -and -not $DryRun) {
    $item = Get-Item -LiteralPath $wim
    Add-ValidationCheck -Name 'WimNonZero' -Passed ($item.Length -gt 0) -Message ("WIM size: {0:N0} bytes" -f $item.Length)

    try {
        $images = Get-XboxOSImageInfo -ImagePath $wim -DismPath $DismPath
        $idxOk = ($images.Count -ge 1)
        Add-ValidationCheck -Name 'ImageIndex' -Passed $idxOk -Message "Exported image count: $($images.Count) (expected 1 working index)"

        if ($images.Count -ge 1) {
            $img = $images[0]
            $editionOk = ($img.Name -like $config.target.imageNamePattern) -or ($img.Name -eq $config.target.edition)
            Add-ValidationCheck -Name 'Edition' -Passed $editionOk -Message "Image name: $($img.Name); configured: $($config.target.edition)"

            $arch = if ($img.Architecture) { $img.Architecture } else { $config.target.architecture }
            $normalized = $arch.ToLowerInvariant()
            if ($normalized -eq 'x64') { $normalized = 'amd64' }
            $target = ([string]$config.target.architecture).ToLowerInvariant()
            if ($target -eq 'x64') { $target = 'amd64' }
            Add-ValidationCheck -Name 'Architecture' -Passed ($normalized -eq $target) -Message "Image architecture: $arch"
        }
    }
    catch {
        Add-ValidationCheck -Name 'WimReadable' -Passed $false -Message $_.Exception.Message
    }
}
elseif ($DryRun) {
    Add-ValidationCheck -Name 'DryRunMode' -Passed $true -Message 'Dry-run validation skipped live WIM/DISM integrity probes.' -Severity 'Warning'
}

# Protected dependency expectations from remove-apps report if present
$removeReport = Join-Path $Context.Paths.Reports 'RemoveApps.json'
if (Test-Path -LiteralPath $removeReport) {
    $removeDoc = Get-Content -LiteralPath $removeReport -Raw | ConvertFrom-Json
    $removeEntries = if ($removeDoc.PSObject.Properties.Name -contains 'results') {
        @($removeDoc.results)
    }
    else {
        @($removeDoc)
    }
    $protectedHits = @($removeEntries | Where-Object {
            ($_.PSObject.Properties.Name -contains 'Message') -and
            ($_.PSObject.Properties.Name -contains 'Status') -and
            $_.Message -match 'Protected' -and
            $_.Status -eq 'Removed'
        })
    Add-ValidationCheck -Name 'ProtectedNotRemoved' -Passed ($protectedHits.Count -eq 0) `
        -Message $(if ($protectedHits.Count -eq 0) { 'No protected packages were removed.' } else { 'Protected packages were removed unexpectedly.' })
}

# Inventory after presence
if ($Context.InventoryAfter -and (Test-Path -LiteralPath $Context.InventoryAfter)) {
    $inv = Get-Content -LiteralPath $Context.InventoryAfter -Raw | ConvertFrom-Json
    $availability = if ($inv.PSObject.Properties.Name -contains 'inventoryAvailability') { [string]$inv.inventoryAvailability } else { 'Available' }
    $missingCritical = New-Object System.Collections.Generic.List[string]

    if ($availability -eq 'Unknown') {
        Add-ValidationCheck -Name 'StorePresentIfInventoried' -Passed $true `
            -Message 'After-inventory availability is Unknown (dry-run / unmounted); Store presence not evaluated.' `
            -Severity 'Warning'
    }
    else {
        $appx = @()
        if ($inv.PSObject.Properties.Name -contains 'appxPackages' -and $null -ne $inv.appxPackages) {
            $appx = @($inv.appxPackages)
        }
        if ($appx.Count -gt 0) {
            $store = @($appx | Where-Object { $_ -like 'Microsoft.WindowsStore*' })
            if ($store.Count -eq 0) {
                $missingCritical.Add('Microsoft.WindowsStore*') | Out-Null
            }
        }
        Add-ValidationCheck -Name 'StorePresentIfInventoried' -Passed ($missingCritical.Count -eq 0) `
            -Message $(if ($missingCritical.Count -eq 0) { 'Store package still present in after-inventory (or inventory empty).' } else { "Missing critical packages: $($missingCritical -join ', ')" }) `
            -Severity 'Warning'
    }
}
else {
    Add-ValidationCheck -Name 'AfterInventory' -Passed $DryRun -Message $(if ($DryRun) { 'After inventory not required in dry-run.' } else { 'After inventory missing.' }) -Severity 'Warning'
}

# Source tree consistency
$sourceTree = $Context.Paths.SourceCopy
$bootmgr = Join-Path $sourceTree 'bootmgr.efi'
$setup = Join-Path $sourceTree 'setup.exe'
if (-not $DryRun) {
    Add-ValidationCheck -Name 'SetupTree' -Passed ((Test-Path $bootmgr) -or (Test-Path $setup)) `
        -Message 'Windows Setup boot/setup files present in source tree' -Severity 'Warning'
}

$hardFailures = @($checks | Where-Object { -not $_.Passed -and $_.Severity -eq 'Error' })
$passed = $hardFailures.Count -eq 0

$report = [ordered]@{
    buildId     = $Context.BuildId
    dryRun      = [bool]$DryRun
    passed      = $passed
    disclaimer  = 'Validation confirms servicing consistency checks only. It does not prove the ISO is bootable or that Xbox mode works until tested on installed hardware.'
    checks      = $checks
    generatedUtc = (Get-Date).ToUniversalTime()
}

$jsonPath = Join-Path $Context.Paths.Reports 'Validation.json'
$txtPath = Join-Path $Context.Paths.Reports 'Validation.txt'
($report | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$lines = @(
    'XboxOS11 Validation Report'
    "BuildId: $($Context.BuildId)"
    "Passed: $passed"
    "DryRun: $DryRun"
    ''
    $report.disclaimer
    ''
    'Checks:'
)
foreach ($check in $checks) {
    $mark = if ($check.Passed) { 'PASS' } else { 'FAIL' }
    $lines += "[$mark/$($check.Severity)] $($check.Name): $($check.Message)"
}
$lines | Set-Content -LiteralPath $txtPath -Encoding UTF8

$Context.Validation = [pscustomobject]$report
Write-XboxOSLog -Level Information -Message "Validation complete. Passed=$passed"

if (-not $passed) {
    throw "Image validation failed with $($hardFailures.Count) error(s). See $txtPath"
}

return [pscustomobject]@{
    Passed = $passed
    Json   = $jsonPath
    Text   = $txtPath
    Report = [pscustomobject]$report
}
