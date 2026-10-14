#Requires -Version 5.1
<#
.SYNOPSIS
    Removes provisioned AppX packages listed in remove-apps.json after inventory-based matching.
.NOTES
    Inventory states:
      Unknown   - no mounted-image inventory (typical dry-run); candidates are NotEvaluated
      Empty     - inventory was queried and contained no packages
      Available - inventory was queried and packages are known
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Alias('Context')]
    [object]$BuildContext,

    [string]$ManifestPath,
    [string]$CompatibilityPath,
    [string]$DismPath,

    [Parameter()]
    [AllowEmptyCollection()]
    [string[]]$AvailablePackages,

    [ValidateSet('Unknown', 'Empty', 'Available')]
    [string]$InventoryState,

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

$packagesBound = $PSBoundParameters.ContainsKey('AvailablePackages')
$stateBound = $PSBoundParameters.ContainsKey('InventoryState')

if ($packagesBound) {
    if (-not $stateBound) {
        $InventoryState = if (@($AvailablePackages).Count -eq 0) { 'Empty' } else { 'Available' }
    }
}
elseif ($stateBound) {
    if ($InventoryState -eq 'Available') {
        throw 'InventoryState=Available requires -AvailablePackages to be supplied.'
    }
    $AvailablePackages = @()
}
elseif ($BuildContext.PSObject.Properties.Name -contains 'AppxInventoryState' -and
        $BuildContext.AppxInventoryState -and
        $BuildContext.AppxInventoryState -ne 'Unknown') {
    $InventoryState = [string]$BuildContext.AppxInventoryState
    $AvailablePackages = @($BuildContext.AppxInventory)
}
elseif ($DryRun -or -not $BuildContext.ImageMounted) {
    $InventoryState = 'Unknown'
    $AvailablePackages = @()
}
else {
    if (-not $DryRun) {
        $null = Assert-XboxOSServicingPathSafety -Path $mount -RepoRoot $config.RepoRoot -Purpose 'AppX removal'
    }
    $inv = Invoke-XboxOSDism -DismPath $DismPath -ArgumentList @("/Image:$mount", '/Get-ProvisionedAppxPackages')
    $AvailablePackages = @(foreach ($line in $inv.Output) {
            if ($line -match '^\s*PackageName\s*:\s*(.+)$') { $Matches[1].Trim() }
        })
    $InventoryState = if ($AvailablePackages.Count -eq 0) { 'Empty' } else { 'Available' }
}

$availability = Get-XboxOSInventoryAvailability -State $InventoryState -Items @($AvailablePackages)
$results = New-Object System.Collections.Generic.List[object]
$fatalErrors = New-Object System.Collections.Generic.List[string]

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

    if (-not $availability.CanEvaluate) {
        $results.Add([pscustomobject]@{
            Candidate = $candidate.id
            Package   = $null
            Status    = 'NotEvaluated'
            Message   = 'No mounted-image AppX inventory is available; package presence cannot be evaluated.'
        }) | Out-Null
        continue
    }

    try {
        $resolvedPackages = @(Resolve-XboxOSPackageMatches -Patterns @($candidate.patterns) -AvailablePackages @($availability.Items) -RejectAmbiguous:$rejectAmbiguous)
    }
    catch {
        $results.Add([pscustomobject]@{
            Candidate = $candidate.id
            Package   = $null
            Status    = 'Failed'
            Message   = $_.Exception.Message
        }) | Out-Null
        $fatalErrors.Add($_.Exception.Message) | Out-Null
        Write-XboxOSLog -Level Error -Message $_.Exception.Message
        continue
    }

    if ($resolvedPackages.Count -eq 0) {
        $results.Add([pscustomobject]@{
            Candidate = $candidate.id
            Package   = $null
            Status    = 'Absent'
            Message   = 'No provisioned package matched approved patterns in the known inventory'
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
                $null = Assert-XboxOSServicingPathSafety -Path $mount -RepoRoot $config.RepoRoot -Purpose 'AppX removal'
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
            $fatalErrors.Add("Failed removing ${package}: $($_.Exception.Message)") | Out-Null
            Write-XboxOSLog -Level Error -Message "Failed removing $package : $($_.Exception.Message)"
        }
    }
}

$reportPath = Join-Path $BuildContext.Paths.Reports 'RemoveApps.json'
$payload = [ordered]@{
    inventoryState = $InventoryState
    dryRun         = [bool]$DryRun
    results        = $results
}
($payload | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $reportPath -Encoding UTF8

$outcome = [pscustomobject]@{
    Results        = $results
    Report         = $reportPath
    InventoryState = $InventoryState
    Success        = ($fatalErrors.Count -eq 0)
    Message        = $(if ($fatalErrors.Count -eq 0) { 'OK' } else { ($fatalErrors -join '; ') })
}

Assert-XboxOSPhaseOutcome -Result $outcome -PhaseName 'RemoveApps' | Out-Null
return $outcome
