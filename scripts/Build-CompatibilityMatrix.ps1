#Requires -Version 5.1
<#
.SYNOPSIS
    Build a read-only compatibility matrix from captured DISM inventory fixtures or a prior compat JSON report.
.DESCRIPTION
    Does not run DISM, mount images, or authorize removals. Ambiguity checks and protected-component
    priority are preserved.
#>
[CmdletBinding()]
param(
    [string]$CompatJsonPath = 'C:\XboxOS\Logs\DISM-Compatibility-20261014-2.json',
    [string]$OutputDirectory = 'C:\XboxOS\Logs',
    [string]$OutputStem = 'XboxOS11-compatibility-matrix-26300.9457'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
Import-Module $modulePath -Force

$repoRoot = Get-XboxOSRepoRoot
$removeApps = Import-XboxOSManifest -Path (Join-Path $repoRoot 'config\remove-apps.json')
$disableFeatures = Import-XboxOSManifest -Path (Join-Path $repoRoot 'config\disable-features.json')
$compatibility = Import-XboxOSManifest -Path (Join-Path $repoRoot 'config\compatibility.json')

$appxNames = @()
$features = @()
$source = $null

if ($CompatJsonPath -and (Test-Path -LiteralPath $CompatJsonPath)) {
    $report = Get-Content -LiteralPath $CompatJsonPath -Raw | ConvertFrom-Json
    $source = $CompatJsonPath
    $appxCmd = @($report.commands | Where-Object { $_.Step -eq 'Get-ProvisionedAppxPackages' } | Select-Object -First 1)
    $featCmd = @($report.commands | Where-Object { $_.Step -eq 'Get-Features' } | Select-Object -First 1)
    if ($appxCmd.Count -eq 1) {
        $appxNames = @(ConvertFrom-XboxOSDismProvisionedAppxListOutput -Output @($appxCmd[0].Output) | ForEach-Object { $_.PackageName })
    }
    if ($featCmd.Count -eq 1) {
        $features = @(ConvertFrom-XboxOSDismFeatureListOutput -Output @($featCmd[0].Output))
    }
}
else {
    $source = 'tests/Fixtures/dism-get-*-26300.9457.txt'
    $appxNames = @(
        ConvertFrom-XboxOSDismProvisionedAppxListOutput -Output (Get-Content -LiteralPath (Join-Path $repoRoot 'tests\Fixtures\dism-get-appx-26300.9457.txt')) |
            ForEach-Object { $_.PackageName }
    )
    $features = @(
        ConvertFrom-XboxOSDismFeatureListOutput -Output (Get-Content -LiteralPath (Join-Path $repoRoot 'tests\Fixtures\dism-get-features-26300.9457.txt'))
    )
}

$matrix = New-XboxOSCompatibilityMatrix `
    -AppxPackages $appxNames `
    -Features $features `
    -RemoveAppsManifest $removeApps `
    -DisableFeaturesManifest $disableFeatures `
    -CompatibilityManifest $compatibility

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$jsonPath = Join-Path $OutputDirectory ($OutputStem + '.json')
$mdPath = Join-Path $OutputDirectory ($OutputStem + '.md')
$docsDir = Join-Path $repoRoot 'docs'
$docsPath = Join-Path $docsDir ($OutputStem + '.md')

$payload = [ordered]@{
    generatedUtc = $matrix.generatedUtc
    source       = $source
    appxCount    = $appxNames.Count
    featureCount = @($features).Count
    summary      = $matrix.summary
    rows         = $matrix.rows
    notes        = @(
        'Read-only analysis only. No package removal or feature disable is authorized by this matrix.'
        'Eligible means present + unprotected + enabled in manifest; still requires explicit Milestone-2 review.'
        'Ambiguous prefix matches are rejected and never treated as authorized removals.'
    )
}
($payload | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$nl = [Environment]::NewLine
$md = New-Object System.Collections.Generic.List[string]
$null = $md.Add('# XboxOS11 Compatibility Matrix (26300.9457 / 26H2)')
$null = $md.Add('')
$null = $md.Add(('Generated (UTC): {0}' -f $matrix.generatedUtc))
$null = $md.Add(('Source: `{0}`' -f $source))
$null = $md.Add(('AppX identities: {0}; Features: {1}' -f $appxNames.Count, @($features).Count))
$null = $md.Add('')
$null = $md.Add('## Summary')
$null = $md.Add('')
$null = $md.Add(('| Status | Count |'))
$null = $md.Add('|---|---|')
foreach ($key in @('present', 'absent', 'protected', 'eligible', 'ambiguous', 'conflicting')) {
    $null = $md.Add(('| {0} | {1} |' -f $key, $matrix.summary.$key))
}
$null = $md.Add('')
$null = $md.Add('## Rows')
$null = $md.Add('')
$null = $md.Add('| Kind | Candidate | Status | Feature/Matches | State | Detail |')
$null = $md.Add('|---|---|---|---|---|---|')
foreach ($row in @($matrix.rows)) {
    $matchText = if ($row.Kind -eq 'AppX') { (@($row.Matches) -join '; ') } else { [string]$row.Feature }
    if ([string]::IsNullOrWhiteSpace($matchText)) { $matchText = '-' }
    $stateText = if ($row.PSObject.Properties['State'] -and $row.State) { [string]$row.State } else { '-' }
    $null = $md.Add(('| {0} | {1} | {2} | {3} | {4} | {5} |' -f `
        $row.Kind, $row.Candidate, $row.Status, ($matchText -replace '\|', '/'), $stateText, ($row.Detail -replace '\|', '/')))
}
$null = $md.Add('')
$null = $md.Add('## Notes')
$null = $md.Add('')
foreach ($note in @($payload.notes)) {
    $null = $md.Add(('- {0}' -f $note))
}
$null = $md.Add('')

($md -join $nl) | Set-Content -LiteralPath $mdPath -Encoding UTF8
New-Item -ItemType Directory -Path $docsDir -Force | Out-Null
Copy-Item -LiteralPath $mdPath -Destination $docsPath -Force

Write-Host ("JSON: {0}" -f $jsonPath)
Write-Host ("Markdown: {0}" -f $mdPath)
Write-Host ("Docs copy: {0}" -f $docsPath)
Write-Host ("Summary: {0}" -f ($matrix.summary | ConvertTo-Json -Compress))
return [pscustomobject]@{ Json = $jsonPath; Markdown = $mdPath; Docs = $docsPath; Matrix = $matrix }
