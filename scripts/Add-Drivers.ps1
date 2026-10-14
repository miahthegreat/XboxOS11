#Requires -Version 5.1
<#
.SYNOPSIS
    Integrates INF-based driver packages into the mounted Windows image.
.NOTES
    Full AMD Adrenalin installers cannot be injected offline. Install GPU software after Setup.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [object]$Context,

    [string]$DriverDirectory,
    [string]$ManifestPath,
    [string]$DismPath,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
Import-Module $modulePath -Force

if (-not $DismPath) { $DismPath = Find-XboxOSDism }
$config = $Context.Configuration
if (-not $ManifestPath) { $ManifestPath = $config.ResolvedPath.driversManifest }
$manifest = Import-XboxOSManifest -Path $ManifestPath

if (-not $DriverDirectory) {
    $DriverDirectory = $config.ResolvedPath.driverDirectory
}
$DriverDirectory = Resolve-XboxOSPath -Path $DriverDirectory -BasePath $config.RepoRoot

$arch = [string]$config.Raw.target.architecture
if (-not (Test-XboxOSArchitectureSupported -Architecture $arch)) {
    throw "Unsupported target architecture for driver integration: $arch"
}
if ($manifest.architecture -and $manifest.architecture -ne $arch -and -not ($arch -eq 'amd64' -and $manifest.architecture -eq 'x64')) {
    throw "Driver manifest architecture '$($manifest.architecture)' does not match target '$arch'."
}

$packages = Find-XboxOSDriverPackages -DriverDirectory $DriverDirectory -DriversManifest $manifest -Recursive
$results = New-Object System.Collections.Generic.List[object]
$mount = $Context.Paths.Mount

if ($packages.Count -eq 0) {
    Write-XboxOSLog -Level Information -Message "No INF driver packages found under $DriverDirectory"
}

foreach ($package in $packages) {
    if ($package.Rejected -or -not $package.ValidInf) {
        $results.Add([pscustomobject]@{
            Path   = $package.Path
            Status = 'Rejected'
            Message = $package.Reason
        }) | Out-Null
        Write-XboxOSLog -Level Warning -Message "Rejected driver package: $($package.Path) ($($package.Reason))"
        continue
    }

    try {
        if ($DryRun) {
            Write-XboxOSLog -Level Information -Message "DryRun: would add driver $($package.Path)"
            $results.Add([pscustomobject]@{
                Path = $package.Path
                Status = 'DryRun'
                Message = 'Would integrate INF driver package'
            }) | Out-Null
        }
        else {
            Invoke-XboxOSDism -DismPath $DismPath -ArgumentList @(
                "/Image:$mount"
                '/Add-Driver'
                "/Driver:$($package.Path)"
            ) | Out-Null
            $results.Add([pscustomobject]@{
                Path = $package.Path
                Status = 'Added'
                Message = 'Integrated with DISM /Add-Driver'
            }) | Out-Null
            Write-XboxOSLog -Level Information -Message "Added driver: $($package.Path)"
        }
    }
    catch {
        $results.Add([pscustomobject]@{
            Path = $package.Path
            Status = 'Failed'
            Message = $_.Exception.Message
        }) | Out-Null
        throw
    }
}

$reportPath = Join-Path $Context.Paths.Reports 'AddDrivers.json'
($results | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $reportPath -Encoding UTF8

return [pscustomobject]@{
    Results = $results
    Report  = $reportPath
    Notes   = 'AMD Adrenalin full installer must be installed after Windows Setup; INF-only packages are supported offline.'
}
