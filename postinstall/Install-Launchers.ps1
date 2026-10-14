#Requires -Version 5.1
<#
.SYNOPSIS
    Optionally installs trusted gaming launchers using verified package identifiers.
.DESCRIPTION
    Supports winget package IDs with explicit user approval. Does not silently install
    untrusted third-party software. Milestone 1 prepares interfaces and dry-run behavior.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Xbox', 'Steam', 'BattleNet', 'EA', 'Ubisoft', 'Epic')]
    [string[]]$Launchers = @('Xbox', 'Steam'),

    [ValidateSet('winget')]
    [string]$PackageManager = 'winget',

    [switch]$DryRun,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$catalog = @{
    Xbox     = [pscustomobject]@{ Id = '9MV0B5HZVK9Z'; Name = 'Xbox'; Source = 'msstore'; Notes = 'Microsoft Store Xbox app' }
    Steam    = [pscustomobject]@{ Id = 'Valve.Steam'; Name = 'Steam'; Source = 'winget'; Notes = 'Official Steam package id' }
    BattleNet= [pscustomobject]@{ Id = 'Blizzard.BattleNet'; Name = 'Battle.net'; Source = 'winget'; Notes = 'Verify id with winget search before production use' }
    EA       = [pscustomobject]@{ Id = 'ElectronicArts.EADesktop'; Name = 'EA App'; Source = 'winget'; Notes = 'Verify id with winget search before production use' }
    Ubisoft  = [pscustomobject]@{ Id = 'Ubisoft.Connect'; Name = 'Ubisoft Connect'; Source = 'winget'; Notes = 'Verify id with winget search before production use' }
    Epic     = [pscustomobject]@{ Id = 'EpicGames.EpicGamesLauncher'; Name = 'Epic Games Launcher'; Source = 'winget'; Notes = 'Official Epic package id' }
}

$results = New-Object System.Collections.Generic.List[object]
$winget = Get-Command winget.exe -ErrorAction SilentlyContinue

foreach ($launcher in $Launchers) {
    $pkg = $catalog[$launcher]
    if (-not $pkg) {
        $results.Add([pscustomobject]@{ Launcher = $launcher; Status = 'Failed'; Message = 'Unknown launcher' }) | Out-Null
        continue
    }

    if ($PackageManager -ne 'winget' -or -not $winget) {
        $results.Add([pscustomobject]@{
            Launcher = $launcher
            Status   = 'Skipped'
            Message  = 'winget not available; install App Installer from Microsoft Store, then re-run with approval.'
            PackageId = $pkg.Id
        }) | Out-Null
        continue
    }

    $args = @('install', '--id', $pkg.Id, '-e', '--accept-package-agreements', '--accept-source-agreements')
    if ($DryRun -or -not $PSCmdlet.ShouldProcess($pkg.Name, "Install via winget ($($pkg.Id))")) {
        $results.Add([pscustomobject]@{
            Launcher = $launcher
            Status   = 'DryRun'
            Message  = "Would run: winget $($args -join ' ')"
            PackageId = $pkg.Id
        }) | Out-Null
        continue
    }

    try {
        & winget.exe @args
        if ($LASTEXITCODE -ne 0) { throw "winget exit code $LASTEXITCODE" }
        $results.Add([pscustomobject]@{ Launcher = $launcher; Status = 'Installed'; PackageId = $pkg.Id }) | Out-Null
    }
    catch {
        $results.Add([pscustomobject]@{ Launcher = $launcher; Status = 'Failed'; Message = $_.Exception.Message; PackageId = $pkg.Id }) | Out-Null
    }
}

$results | Format-Table -AutoSize | Out-String | Write-Host
if ($PassThru) { return $results }
