#Requires -Version 7.0
<#
.SYNOPSIS
    Packages an XboxOS11 release: the self-contained Builder app with its toolkit, plus a toolkit-only zip.
.DESCRIPTION
    Produces, under -OutputDirectory\<version>\:
      XboxOS11-<version>-win-x64.zip     Builder app (self-contained) + toolkit\
      XboxOS11-<version>-win-arm64.zip   (when requested)
      XboxOS11-Toolkit-<version>.zip     PowerShell toolkit only (CLI use)
      SHA256SUMS.txt                     sha256sum-compatible checksums
      release-manifest.json              version, git commit, file sizes and hashes

    Never packages Windows media, tests, CI/automation files, or build outputs from the repository.
.EXAMPLE
    .\scripts\New-XboxOSRelease.ps1 -OutputDirectory C:\XboxOS\Releases
.EXAMPLE
    .\scripts\New-XboxOSRelease.ps1 -SkipAppBuild    # toolkit zip only (no .NET SDK needed)
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory = 'C:\XboxOS\Releases',
    [ValidateSet('win-x64', 'win-arm64')]
    [string[]]$Runtime = @('win-x64'),
    [switch]$SkipAppBuild,
    [switch]$AllowDirtyTree
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force

$version = Get-XboxOSToolkitVersion -RepoRoot $repoRoot
$consistency = Test-XboxOSReleaseVersionConsistency -RepoRoot $repoRoot
if (-not $consistency.consistent) {
    throw ("Version sources disagree:`n - " + ($consistency.errors -join "`n - "))
}

$gitSha = (& git -C $repoRoot rev-parse HEAD 2>$null)
$dirty = @(& git -C $repoRoot status --porcelain 2>$null | Where-Object { $_ -and $_ -notmatch '/(bin|obj)/' })
if ($dirty.Count -gt 0 -and -not $AllowDirtyTree) {
    throw "Working tree has uncommitted changes; commit them or pass -AllowDirtyTree for a local test package."
}

$outFull = [System.IO.Path]::GetFullPath($OutputDirectory)
if (Test-XboxOSPathEqualsOrUnder -Path $outFull -ParentPath $repoRoot) {
    throw "Release output must be outside the repository: $outFull"
}
$releaseDir = Join-Path $outFull $version
$staging = Join-Path $releaseDir '_staging'
if (Test-Path -LiteralPath $releaseDir) { Remove-Item -LiteralPath $releaseDir -Recurse -Force }
New-Item -ItemType Directory -Path $staging -Force | Out-Null

# ---- Toolkit -----------------------------------------------------------------------------
$toolkit = Join-Path $staging 'toolkit'
foreach ($dir in @('modules', 'scripts', 'config', 'postinstall', 'docs')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot $dir) -Destination (Join-Path $toolkit $dir) -Recurse -Force
}
foreach ($file in @('README.md', 'LICENSE', 'CHANGELOG.md', 'VERSION')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot $file) -Destination (Join-Path $toolkit $file) -Force
}
$forbidden = @(Get-ChildItem -LiteralPath $toolkit -Recurse -File -Include '*.iso', '*.wim', '*.esd', '*.swm', '*.msu', '*.cab', '*.pem', '*.pfx')
if ($forbidden.Count -gt 0) {
    throw ("Refusing to package media, update, or key files:`n" + ($forbidden.FullName -join "`n"))
}

$artifacts = New-Object System.Collections.Generic.List[string]
$toolkitZip = Join-Path $releaseDir ("XboxOS11-Toolkit-{0}.zip" -f $version)
Compress-Archive -Path (Join-Path $toolkit '*') -DestinationPath $toolkitZip -CompressionLevel Optimal
$artifacts.Add($toolkitZip)

# ---- Builder app ----------------------------------------------------------------------------
if (-not $SkipAppBuild) {
    $project = Join-Path $repoRoot 'src\XboxOS11.Builder.App\XboxOS11.Builder.App.csproj'
    foreach ($rid in $Runtime) {
        $platform = if ($rid -eq 'win-arm64') { 'ARM64' } else { 'x64' }
        $publishDir = Join-Path $staging "app-$rid"
        Write-Host "Publishing Builder app for $rid…"
        & dotnet publish $project -c Release -r $rid "-p:Platform=$platform" --self-contained -o $publishDir -nologo -v:minimal
        if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed for $rid (exit $LASTEXITCODE)." }
        if (-not (Test-Path -LiteralPath (Join-Path $publishDir 'XboxOS11.Builder.exe'))) { throw "Publish output missing XboxOS11.Builder.exe for $rid." }
        Copy-Item -LiteralPath $toolkit -Destination (Join-Path $publishDir 'toolkit') -Recurse -Force
        Get-ChildItem -LiteralPath $publishDir -Recurse -File -Filter '*.pdb' | Remove-Item -Force
        $zip = Join-Path $releaseDir ("XboxOS11-{0}-{1}.zip" -f $version, $rid)
        Compress-Archive -Path (Join-Path $publishDir '*') -DestinationPath $zip -CompressionLevel Optimal
        $artifacts.Add($zip)
    }
}

# ---- Checksums and manifest ------------------------------------------------------------------
$entries = foreach ($a in $artifacts) {
    $item = Get-Item -LiteralPath $a
    [ordered]@{ name = $item.Name; sizeBytes = $item.Length; sha256 = (Get-FileHash -LiteralPath $a -Algorithm SHA256).Hash.ToLowerInvariant() }
}
$sums = ($entries | ForEach-Object { '{0}  {1}' -f $_.sha256, $_.name }) -join "`n"
Set-Content -LiteralPath (Join-Path $releaseDir 'SHA256SUMS.txt') -Value ($sums + "`n") -Encoding ascii -NoNewline
$manifest = [ordered]@{
    schemaVersion = 'xboxos-release-manifest-v1'
    version       = $version
    gitCommit     = $(if ($gitSha) { ([string]$gitSha).Trim() } else { 'unknown' })
    dirtyTree     = [bool]($dirty.Count -gt 0)
    createdUtc    = [datetime]::UtcNow.ToString('o')
    artifacts     = @($entries)
    notes         = 'Contains no Microsoft Windows media. Bring your own official Windows 11 ISO.'
}
($manifest | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $releaseDir 'release-manifest.json') -Encoding UTF8
Remove-Item -LiteralPath $staging -Recurse -Force

Write-Host "Release $version written to $releaseDir"
foreach ($e in $entries) { Write-Host ("  {0}  {1:N1} MB  {2}" -f $e.name, ($e.sizeBytes / 1MB), $e.sha256) }
return [pscustomobject]@{
    Version   = $version
    Directory = $releaseDir
    Artifacts = $artifacts.ToArray()
    Manifest  = Join-Path $releaseDir 'release-manifest.json'
}
