# Milestone 11 - Lean image: optional capability removal, offline image registry settings, and image-size
# reduction (component store cleanup and recompression). Everything here acts on the mounted working copy of
# install.wim in the isolated workspace; nothing touches the build host's own Windows installation.

$script:XboxOSImageTweaksSchemaVersion = 'xboxos-image-tweaks-v1'
$script:XboxOSImageCompressionModes = @('Default', 'Max', 'Recovery')

# Hive files inside a mounted image, keyed by the hive names used in config/image-tweaks.json.
$script:XboxOSImageHiveFiles = [ordered]@{
    DefaultUser = 'Users\Default\NTUSER.DAT'
    Software    = 'Windows\System32\config\SOFTWARE'
    System      = 'Windows\System32\config\SYSTEM'
}

function Get-XboxOSImageCompressionModes { return [string[]]$script:XboxOSImageCompressionModes }

#region Capabilities

function ConvertFrom-XboxOSDismCapabilityListOutput {
    <#
    .SYNOPSIS
      Parses `DISM /Get-Capabilities` output into identity/state objects.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)

    $items = New-Object System.Collections.Generic.List[object]
    $current = $null
    foreach ($line in $Lines) {
        if ($line -match '^\s*Capability Identity\s*:\s*(.+?)\s*$') {
            $current = [pscustomobject]@{ Identity = $Matches[1]; State = 'Unknown' }
            $items.Add($current) | Out-Null
        }
        elseif ($null -ne $current -and $line -match '^\s*State\s*:\s*(.+?)\s*$') {
            $current.State = $Matches[1]
        }
    }
    return [object[]]$items.ToArray()
}

function Test-XboxOSCapabilityCandidateProtected {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Candidate, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ProtectedPatterns)

    foreach ($pattern in @($Candidate.patterns)) {
        $probe = ([string]$pattern).TrimEnd('*')
        foreach ($p in $ProtectedPatterns) {
            if ($probe -like $p -or ([string]$p).TrimEnd('*') -like [string]$pattern) { return $true }
        }
    }
    return $false
}

#endregion

#region Offline image registry settings

function Get-XboxOSImageTweakCatalog {
    [CmdletBinding()]
    param([string]$Path = $null)

    if (-not $Path) { $Path = Join-Path (Get-XboxOSRepoRoot) 'config\image-tweaks.json' }
    $catalog = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$catalog.schemaVersion -ne $script:XboxOSImageTweaksSchemaVersion) {
        throw ("Unsupported image tweak catalog '{0}'." -f $catalog.schemaVersion)
    }
    foreach ($t in @($catalog.tweaks)) {
        foreach ($v in @($t.values)) {
            if (-not $script:XboxOSImageHiveFiles.Contains([string]$v.hive)) {
                throw ("Image tweak '{0}' uses unknown hive '{1}'." -f $t.id, $v.hive)
            }
            if ([string]$v.action -notin @('Set', 'Delete')) {
                throw ("Image tweak '{0}' uses unknown action '{1}'." -f $t.id, $v.action)
            }
            if ([string]$v.action -eq 'Set' -and [string]$v.type -notin @('DWord', 'String')) {
                throw ("Image tweak '{0}' uses unsupported type '{1}'." -f $t.id, $v.type)
            }
            if ([string]$v.path -match '\.\.' -or [string]$v.path -match '^[\\/]') {
                throw ("Image tweak '{0}' has an unsafe registry path." -f $t.id)
            }
        }
    }
    return $catalog
}

function New-XboxOSImageHiveLeafName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Hive)
    return ('XboxOSImage-{0}-{1}' -f $Hive, [guid]::NewGuid().ToString('N').Substring(0, 12))
}

function Invoke-XboxOSImageRegistryTweaks {
    <#
    .SYNOPSIS
      Applies registry values to hives inside a mounted image. Each hive is loaded under a uniquely named,
      run-owned HKLM key, written only through reg.exe (no lingering handles), and always unloaded in finally.
    .PARAMETER RegCommand
      Test seam: scriptblock receiving an argument array for reg.exe and returning @{ ExitCode; Output }.
      Production runs reg.exe. Tests never load real hives.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MountDir,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Tweaks,
        [scriptblock]$RegCommand = $null,
        [switch]$DryRun
    )

    if (-not $RegCommand) {
        $RegCommand = {
            param([string[]]$Arguments)
            $out = & reg.exe @Arguments 2>&1
            @{ ExitCode = $LASTEXITCODE; Output = @($out | ForEach-Object { "$_" }) }
        }
    }

    $results = New-Object System.Collections.Generic.List[object]
    $byHive = [ordered]@{}
    foreach ($t in $Tweaks) {
        foreach ($v in @($t.values)) {
            $h = [string]$v.hive
            if (-not $byHive.Contains($h)) { $byHive[$h] = New-Object System.Collections.Generic.List[object] }
            $byHive[$h].Add([pscustomobject]@{ TweakId = [string]$t.id; Value = $v }) | Out-Null
        }
    }

    foreach ($hive in $byHive.Keys) {
        $hiveFile = Join-Path $MountDir $script:XboxOSImageHiveFiles[$hive]
        if ($DryRun) {
            foreach ($entry in $byHive[$hive]) {
                $results.Add([pscustomobject]@{ Tweak = $entry.TweakId; Hive = $hive; Path = [string]$entry.Value.path; Name = [string]$entry.Value.name; Status = 'DryRun'; Message = "Would $($entry.Value.action) in $hive" }) | Out-Null
            }
            continue
        }

        $leaf = New-XboxOSImageHiveLeafName -Hive $hive
        $root = "HKLM\$leaf"
        $load = & $RegCommand @('load', $root, $hiveFile)
        if ([int]$load.ExitCode -ne 0) {
            throw ("Failed to load image hive {0} ({1}): {2}" -f $hive, $hiveFile, (@($load.Output) -join ' '))
        }
        try {
            foreach ($entry in $byHive[$hive]) {
                $v = $entry.Value
                $key = "$root\$([string]$v.path)"
                if ([string]$v.action -eq 'Set') {
                    $regType = if ([string]$v.type -eq 'DWord') { 'REG_DWORD' } else { 'REG_SZ' }
                    $r = & $RegCommand @('add', $key, '/v', [string]$v.name, '/t', $regType, '/d', [string]$v.data, '/f')
                    $status = if ([int]$r.ExitCode -eq 0) { 'Set' } else { 'Failed' }
                }
                else {
                    $q = & $RegCommand @('query', $key, '/v', [string]$v.name)
                    if ([int]$q.ExitCode -ne 0) {
                        $status = 'AlreadyAbsent'
                        $r = $q
                    }
                    else {
                        $r = & $RegCommand @('delete', $key, '/v', [string]$v.name, '/f')
                        $status = if ([int]$r.ExitCode -eq 0) { 'Deleted' } else { 'Failed' }
                    }
                }
                $msg = if ($status -eq 'Failed') { (@($r.Output) -join ' ') } else { '' }
                $results.Add([pscustomobject]@{ Tweak = $entry.TweakId; Hive = $hive; Path = [string]$v.path; Name = [string]$v.name; Status = $status; Message = $msg }) | Out-Null
            }
        }
        finally {
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
            $unload = & $RegCommand @('unload', $root)
            if ([int]$unload.ExitCode -ne 0) {
                throw ("RecoveryRequired: failed to unload image hive {0} at {1}. Run 'reg unload {1}' before dismounting with /Discard. Output: {2}" -f $hive, $root, (@($unload.Output) -join ' '))
            }
        }
    }
    return [object[]]$results.ToArray()
}

#endregion

#region Image size

function Get-XboxOSComponentCleanupArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MountDir, [switch]$ResetBase)

    $a = @("/Image:$MountDir", '/Cleanup-Image', '/StartComponentCleanup')
    if ($ResetBase) { $a += '/ResetBase' }
    return [string[]]$a
}

function Get-XboxOSImageExportArguments {
    <#
    .SYNOPSIS
      DISM /Export-Image arguments to recompress the serviced image. Recovery compression produces an .esd.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceImage,
        [Parameter(Mandatory)][string]$DestinationImage,
        [Parameter(Mandatory)][ValidateSet('Max', 'Recovery')][string]$Compression
    )

    $ext = [System.IO.Path]::GetExtension($DestinationImage).ToLowerInvariant()
    if ($Compression -eq 'Recovery' -and $ext -ne '.esd') { throw 'Recovery compression requires an .esd destination.' }
    if ($Compression -eq 'Max' -and $ext -ne '.wim') { throw 'Max compression requires a .wim destination.' }
    return [string[]]@(
        '/Export-Image'
        "/SourceImageFile:$SourceImage"
        '/SourceIndex:1'
        "/DestinationImageFile:$DestinationImage"
        "/Compress:$($Compression.ToLowerInvariant())"
        '/CheckIntegrity'
    )
}

function Clear-XboxOSIsoInstallImages {
    <#
    .SYNOPSIS
      Removes every install.wim / install.esd / install*.swm from an ISO working tree so Setup only sees the
      serviced image that is copied in next. Only files directly in <tree>\sources named install* are touched.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceTree)

    $sources = Join-Path $SourceTree 'sources'
    $removed = New-Object System.Collections.Generic.List[string]
    foreach ($f in @(Get-ChildItem -LiteralPath $sources -File -Filter 'install*' -ErrorAction SilentlyContinue)) {
        if ($f.Extension -in @('.wim', '.esd', '.swm')) {
            Remove-Item -LiteralPath $f.FullName -Force
            $removed.Add($f.Name) | Out-Null
        }
    }
    return [string[]]$removed.ToArray()
}

function Get-XboxOSFinalImagePath {
    <#
    .SYNOPSIS
      The image that goes onto the ISO: the recompressed image when one was produced, otherwise the working WIM.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Context)

    if ($Context.PSObject.Properties.Name -contains 'FinalImagePath' -and $Context.FinalImagePath) {
        return [string]$Context.FinalImagePath
    }
    return [string]$Context.Paths.WorkingWim
}

#endregion
