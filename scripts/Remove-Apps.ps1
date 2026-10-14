#Requires -Version 5.1
<#
.SYNOPSIS
    Removes provisioned AppX packages listed in remove-apps.json after inventory-based matching.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Alias('Context')]
    [object]$BuildContext,

    [string]$ManifestPath,
    [string]$CompatibilityPath,
    [string]$DismPath,
    [string[]]$AvailablePackages,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
Import-Module $modulePath -Force

if (-not $DismPath) { $DismPath = Find-XboxOSDism }
$config = $BuildContext.Configuration
if (-not $ManifestPath) { $ManifestPath = $config.ResolvedPath.removeAppsManifest }
if (-not $CompatibilityPath) { $CompatibilityPath = $config.ResolvedPath.compatibilityManifest }

$manifest = Import-XboxOSManifest -Path $ManifestPath
$compatibility = Import-XboxOSManifest -Path $CompatibilityPath
$protected = Get-XboxOSProtectedAppxPatterns -CompatibilityManifest $compatibility
$rejectAmbiguous = [bool]$config.Raw.safety.rejectAmbiguousPackageMatches
$mount = $BuildContext.Paths.Mount

if (-not $AvailablePackages) {
    if ($DryRun) {
        $AvailablePackages = @()
    }
    else {
        $inv = Invoke-XboxOSDism -DismPath $DismPath -ArgumentList @("/Image:$mount", '/Get-ProvisionedAppxPackages')
        $AvailablePackages = foreach ($line in $inv.Output) {
            if ($line -match '^\s*PackageName\s*:\s*(.+)$') { $Matches[1].Trim() }
        }
    }
}

$results = New-Object System.Collections.Generic.List[object]

foreach ($candidate in @($manifest.candidates)) {
    if (-not $candidate.enabled) {
        $results.Add([pscustomobject]@{
            Candidate = $candidate.id
            Package   = $null
            Status    = 'Skipped'
            Message   = 'Candidate disabled in manifest'
        }) | Out-Null
        continue
    }

    try {
        $resolvedPackages = @(Resolve-XboxOSPackageMatches -Patterns @($candidate.patterns) -AvailablePackages @($AvailablePackages) -RejectAmbiguous:$rejectAmbiguous)
    }
    catch {
        $results.Add([pscustomobject]@{
            Candidate = $candidate.id
            Package   = $null
            Status    = 'Failed'
            Message   = $_.Exception.Message
        }) | Out-Null
        Write-XboxOSLog -Level Error -Message $_.Exception.Message
        continue
    }

    if ($resolvedPackages.Count -eq 0) {
        $results.Add([pscustomobject]@{
            Candidate = $candidate.id
            Package   = $null
            Status    = 'Absent'
            Message   = 'No provisioned package matched approved patterns'
        }) | Out-Null
        continue
    }

    foreach ($package in $resolvedPackages) {
        if (Test-XboxOSPackageProtected -PackageName $package -ProtectedPatterns $protected) {
            $results.Add([pscustomobject]@{
                Candidate = $candidate.id
                Package   = $package
                Status    = 'Skipped'
                Message   = 'Protected by compatibility.json'
            }) | Out-Null
            Write-XboxOSLog -Level Warning -Message "Refusing to remove protected package: $package"
            continue
        }

        # Extra guard: package must be in the approved candidate match set only (already true)
        try {
            if ($DryRun) {
                Write-XboxOSLog -Level Information -Message "DryRun: would remove $package"
                $results.Add([pscustomobject]@{
                    Candidate = $candidate.id
                    Package   = $package
                    Status    = 'DryRun'
                    Message   = 'Would remove provisioned package'
                }) | Out-Null
            }
            else {
                Invoke-XboxOSDism -DismPath $DismPath -ArgumentList @(
                    "/Image:$mount"
                    '/Remove-ProvisionedAppxPackage'
                    "/PackageName:$package"
                ) | Out-Null
                $results.Add([pscustomobject]@{
                    Candidate = $candidate.id
                    Package   = $package
                    Status    = 'Removed'
                    Message   = 'Removed via DISM'
                }) | Out-Null
                Write-XboxOSLog -Level Information -Message "Removed provisioned package: $package"
            }
        }
        catch {
            $results.Add([pscustomobject]@{
                Candidate = $candidate.id
                Package   = $package
                Status    = 'Failed'
                Message   = $_.Exception.Message
            }) | Out-Null
            Write-XboxOSLog -Level Error -Message "Failed removing $package : $($_.Exception.Message)"
            throw
        }
    }
}

$reportPath = Join-Path $BuildContext.Paths.Reports 'RemoveApps.json'
($results | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $reportPath -Encoding UTF8

return [pscustomobject]@{
    Results = $results
    Report  = $reportPath
}
