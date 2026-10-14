#Requires -Version 5.1
<#
.SYNOPSIS
    Applies CAB/MSU update packages to the mounted image in a safe order.
.NOTES
    Recommended order: Servicing Stack Update (SSU) -> SafeOS -> Latest Cumulative Update (LCU) -> .NET cumulative -> other.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [object]$Context,

    [string]$UpdateDirectory,
    [string]$DismPath,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
Import-Module $modulePath -Force

if (-not $DismPath) { $DismPath = Find-XboxOSDism }
$config = $Context.Configuration
if (-not $UpdateDirectory) {
    $UpdateDirectory = $config.ResolvedPath.updateDirectory
}
$UpdateDirectory = Resolve-XboxOSPath -Path $UpdateDirectory -BasePath $config.RepoRoot
$mount = $Context.Paths.Mount

$found = Find-XboxOSUpdatePackages -UpdateDirectory $UpdateDirectory
$ordered = Get-XboxOSOrderedUpdatePackages -Packages $found
$results = New-Object System.Collections.Generic.List[object]

if ($ordered.Count -eq 0) {
    Write-XboxOSLog -Level Information -Message "No .cab/.msu updates found under $UpdateDirectory"
}

foreach ($package in $ordered) {
    if ($package.Extension -notin @('.cab', '.msu')) {
        $results.Add([pscustomobject]@{
            Path = $package.Path
            Kind = $package.Kind
            Status = 'Rejected'
            Message = 'Unsupported package format'
        }) | Out-Null
        continue
    }

    try {
        if ($DryRun) {
            Write-XboxOSLog -Level Information -Message "DryRun: would add update $($package.Name) ($($package.Kind))"
            $results.Add([pscustomobject]@{
                Path = $package.Path
                Kind = $package.Kind
                Status = 'DryRun'
                Message = 'Would apply update package'
            }) | Out-Null
        }
        else {
            Invoke-XboxOSDism -DismPath $DismPath -ArgumentList @(
                "/Image:$mount"
                '/Add-Package'
                "/PackagePath:$($package.Path)"
            ) | Out-Null
            $results.Add([pscustomobject]@{
                Path = $package.Path
                Kind = $package.Kind
                Status = 'Added'
                Message = 'Applied with DISM /Add-Package'
            }) | Out-Null
            Write-XboxOSLog -Level Information -Message "Added update: $($package.Name)"
        }
    }
    catch {
        $results.Add([pscustomobject]@{
            Path = $package.Path
            Kind = $package.Kind
            Status = 'Failed'
            Message = $_.Exception.Message
        }) | Out-Null
        throw
    }
}

$reportPath = Join-Path $Context.Paths.Reports 'AddUpdates.json'
$payload = [ordered]@{
    orderingNotes = @(
        'Apply servicing stack updates before cumulative updates.',
        'Apply only packages matching the image architecture and build family.',
        'Do not randomly reorder vendor package sets.'
    )
    results = $results
}
($payload | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $reportPath -Encoding UTF8

return [pscustomobject]@{
    Results = $results
    Report  = $reportPath
}
