#Requires -Version 5.1
<#
.SYNOPSIS
    Removes optional Windows capabilities listed (enabled) in remove-capabilities.json from the mounted image.
.NOTES
    Inventory states:
      Unknown   - no mounted-image inventory (typical dry-run); candidates are NotEvaluated
      Empty     - inventory was queried and contained no capabilities
      Available - inventory was queried and capability identities are known
    Only installed capabilities that match exactly one candidate pattern are removed. Capabilities matching
    compatibility.json protectedCapabilities are never removed.
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
    [string[]]$InstalledCapabilities,

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
if (-not $ManifestPath) { $ManifestPath = $config.ResolvedPath.removeCapabilitiesManifest }
if (-not $CompatibilityPath) { $CompatibilityPath = $config.ResolvedPath.compatibilityManifest }

$manifest = Import-XboxOSManifest -Path $ManifestPath
$compatibility = Import-XboxOSManifest -Path $CompatibilityPath
$protected = @()
if ($compatibility.PSObject.Properties['protectedCapabilities']) { $protected = @($compatibility.protectedCapabilities | ForEach-Object { [string]$_ }) }
$mount = $BuildContext.Paths.Mount

if ($PSBoundParameters.ContainsKey('InstalledCapabilities')) {
    if (-not $PSBoundParameters.ContainsKey('InventoryState')) {
        $InventoryState = if (@($InstalledCapabilities).Count -eq 0) { 'Empty' } else { 'Available' }
    }
}
elseif ($PSBoundParameters.ContainsKey('InventoryState')) {
    if ($InventoryState -eq 'Available') { throw 'InventoryState=Available requires -InstalledCapabilities.' }
    $InstalledCapabilities = @()
}
elseif ($DryRun -or -not $BuildContext.ImageMounted) {
    $InventoryState = 'Unknown'
    $InstalledCapabilities = @()
}
else {
    $null = Assert-XboxOSServicingPathSafety -Path $mount -RepoRoot $config.RepoRoot -Purpose 'capability inventory'
    $inv = Invoke-XboxOSDism -DismPath $DismPath -ArgumentList @("/Image:$mount", '/Get-Capabilities')
    $InstalledCapabilities = @(ConvertFrom-XboxOSDismCapabilityListOutput -Lines @($inv.Output) |
            Where-Object { $_.State -eq 'Installed' } | ForEach-Object { $_.Identity })
    $InventoryState = if ($InstalledCapabilities.Count -eq 0) { 'Empty' } else { 'Available' }
}

$availability = Get-XboxOSInventoryAvailability -State $InventoryState -Items @($InstalledCapabilities)
$results = New-Object System.Collections.Generic.List[object]
$fatalErrors = New-Object System.Collections.Generic.List[string]

foreach ($candidate in @($manifest.candidates)) {
    if (-not [bool]$candidate.enabled) {
        $results.Add([pscustomobject]@{ Candidate = $candidate.id; Capability = $null; Status = 'Skipped'; Message = 'Candidate disabled in manifest' }) | Out-Null
        continue
    }
    if (Test-XboxOSCapabilityCandidateProtected -Candidate $candidate -ProtectedPatterns $protected) {
        $results.Add([pscustomobject]@{ Candidate = $candidate.id; Capability = $null; Status = 'Skipped'; Message = 'Protected by compatibility.json' }) | Out-Null
        continue
    }
    if (-not $availability.CanEvaluate) {
        $results.Add([pscustomobject]@{ Candidate = $candidate.id; Capability = $null; Status = 'NotEvaluated'; Message = 'No mounted-image capability inventory is available.' }) | Out-Null
        continue
    }

    try {
        $resolved = @(Resolve-XboxOSPackageMatches -Patterns @($candidate.patterns) -AvailablePackages @($availability.Items) -RejectAmbiguous)
    }
    catch {
        $results.Add([pscustomobject]@{ Candidate = $candidate.id; Capability = $null; Status = 'Failed'; Message = $_.Exception.Message }) | Out-Null
        $fatalErrors.Add($_.Exception.Message) | Out-Null
        continue
    }
    if ($resolved.Count -eq 0) {
        $results.Add([pscustomobject]@{ Candidate = $candidate.id; Capability = $null; Status = 'Absent'; Message = 'Not installed in this image' }) | Out-Null
        continue
    }

    foreach ($capability in $resolved) {
        if (Test-XboxOSPackageProtected -PackageName $capability -ProtectedPatterns $protected) {
            $results.Add([pscustomobject]@{ Candidate = $candidate.id; Capability = $capability; Status = 'Skipped'; Message = 'Protected by compatibility.json' }) | Out-Null
            continue
        }
        if ($DryRun) {
            $results.Add([pscustomobject]@{ Candidate = $candidate.id; Capability = $capability; Status = 'DryRun'; Message = 'Would remove capability' }) | Out-Null
            continue
        }
        try {
            $null = Assert-XboxOSServicingPathSafety -Path $mount -RepoRoot $config.RepoRoot -Purpose 'capability removal'
            Invoke-XboxOSDism -DismPath $DismPath -ArgumentList @("/Image:$mount", '/Remove-Capability', "/CapabilityName:$capability") | Out-Null
            $results.Add([pscustomobject]@{ Candidate = $candidate.id; Capability = $capability; Status = 'Removed'; Message = 'Removed' }) | Out-Null
            Write-XboxOSLog -Level Information -Message "Removed capability: $capability"
        }
        catch {
            $results.Add([pscustomobject]@{ Candidate = $candidate.id; Capability = $capability; Status = 'Failed'; Message = $_.Exception.Message }) | Out-Null
            $fatalErrors.Add("Failed removing ${capability}: $($_.Exception.Message)") | Out-Null
        }
    }
}

$reportPath = Join-Path $BuildContext.Paths.Reports 'RemoveCapabilities.json'
([ordered]@{ inventoryState = $InventoryState; dryRun = [bool]$DryRun; results = $results.ToArray() } | ConvertTo-Json -Depth 6) |
    Set-Content -LiteralPath $reportPath -Encoding UTF8

$outcome = [pscustomobject]@{
    Results        = $results.ToArray()
    Report         = $reportPath
    InventoryState = $InventoryState
    Success        = ($fatalErrors.Count -eq 0)
    Message        = $(if ($fatalErrors.Count -eq 0) { 'OK' } else { ($fatalErrors -join '; ') })
}
Assert-XboxOSPhaseOutcome -Result $outcome -PhaseName 'RemoveCapabilities' | Out-Null
return $outcome
