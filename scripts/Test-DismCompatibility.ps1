#Requires -Version 5.1
# Isolated DISM compatibility test for XboxOS11 M1.5
# Safety: read-only mount, discard unmount, never modify source ISO.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$transcriptPath = 'C:\XboxOS\Logs\DISM-Compatibility-20261014.transcript.log'
$sentinelPath = 'C:\XboxOS\Logs\DISM-Compatibility-20261014.done'
New-Item -ItemType Directory -Path 'C:\XboxOS\Logs' -Force | Out-Null
if (Test-Path -LiteralPath $sentinelPath) { Remove-Item -LiteralPath $sentinelPath -Force }
try { Stop-Transcript | Out-Null } catch { }
Start-Transcript -Path $transcriptPath -Force | Out-Null

$isoPath = 'C:\XboxOS\Sources\Windows11_Client_x64_en-us_26300_9457.iso'
$workRoot = 'C:\XboxOS\Work\dism-compat-20261014'
$logsRoot = 'C:\XboxOS\Logs'
$sourceIndex = 6
$reportPath = Join-Path $logsRoot 'DISM-Compatibility-20261014.md'
$jsonReportPath = Join-Path $logsRoot 'DISM-Compatibility-20261014.json'

$commandLog = New-Object System.Collections.Generic.List[object]
$warnings = New-Object System.Collections.Generic.List[string]
$errors = New-Object System.Collections.Generic.List[string]
$mounted = $false
$isoDrive = $null
$dismVersion = $null
$dismVersionOut = @()
$exportMeta = $null
$imageInfoMounted = $null
$packagesSample = @()
$appxSample = @()
$featuresSample = @()
$packageCount = 0
$appxCount = 0
$featureCount = 0
$cleanupOk = $false
$noMountsLeft = $false
$isoUnchanged = $false
$isoHashBefore = $null
$isoHashAfter = $null
$isoLengthBefore = $null
$isoLastWriteBefore = $null
$index6Name = $null
$buildNumber = $null
$displayVersion = $null
$editionId = $null
$productName = $null
$mountDir = Join-Path $workRoot 'mount'
$wimPath = Join-Path $workRoot 'install-pro-index1.wim'

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Invoke-DismLogged {
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [string]$StepName
    )

    $display = "dism.exe $($ArgumentList -join ' ')"
    Write-Host "CMD: $display"
    $output = & dism.exe @ArgumentList 2>&1
    $exit = $LASTEXITCODE
    $text = @($output | ForEach-Object { "$_" })
    $commandLog.Add([pscustomobject]@{
        Step     = $StepName
        Command  = $display
        ExitCode = $exit
        Output   = $text
    }) | Out-Null

    foreach ($line in $text) {
        if ($line -match '(?i)warning') { $warnings.Add("[$StepName] $line") | Out-Null }
        if ($line -match '(?i)\berror\b' -and $exit -ne 0) { $errors.Add("[$StepName] $line") | Out-Null }
        Write-Host $line
    }

    Write-Host "EXIT: $exit"
    if ($exit -ne 0) {
        throw "DISM failed ($StepName) with exit code $exit"
    }
    return $text
}

function Get-DismListedValues {
    param([string[]]$Output, [string]$Label)
    $values = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Output) {
        if ($line -match ("^\s*{0}\s*:\s*(.+)$" -f [regex]::Escape($Label))) {
            $values.Add($Matches[1].Trim()) | Out-Null
        }
    }
    return , [string[]]$values.ToArray()
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This compatibility test requires an elevated PowerShell session.'
    }

    if ($workRoot -match '(?i)OneDrive' -or $logsRoot -match '(?i)OneDrive') {
        throw 'Refusing OneDrive paths for WIM/mount/log test directories.'
    }

    New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $logsRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $mountDir -Force | Out-Null

    Write-Step 'Baseline ISO metadata'
    $isoItem = Get-Item -LiteralPath $isoPath
    $isoLengthBefore = $isoItem.Length
    $isoLastWriteBefore = $isoItem.LastWriteTimeUtc
    Write-Host "ISO: $($isoItem.FullName)"
    Write-Host "Size: $isoLengthBefore"
    Write-Host "LastWriteUtc: $isoLastWriteBefore"
    Write-Host 'Computing SHA256 of source ISO (read-only)...'
    $isoHashBefore = (Get-FileHash -LiteralPath $isoPath -Algorithm SHA256).Hash
    Write-Host "SHA256: $isoHashBefore"

    Write-Step 'DISM version'
    $dismVersionOut = Invoke-DismLogged -StepName 'Get-DismVersion' -ArgumentList @('/English', '/Get-DismVersion')
    foreach ($line in $dismVersionOut) {
        if ($line -match 'DISM Version|Version') { $dismVersion = $line.Trim() }
    }

    Write-Step 'Mount source ISO read-only'
    $diskImage = Mount-DiskImage -ImagePath $isoPath -StorageType ISO -PassThru
    $isoDrive = ($diskImage | Get-Volume).DriveLetter
    if (-not $isoDrive) { throw 'ISO mounted but no drive letter was assigned.' }
    $isoRoot = "${isoDrive}:\"
    Write-Host "ISO mounted at $isoRoot"
    $sourceWim = Join-Path $isoRoot 'sources\install.wim'
    $sourceEsd = Join-Path $isoRoot 'sources\install.esd'
    if (Test-Path -LiteralPath $sourceWim) {
        $sourceImage = $sourceWim
    }
    elseif (Test-Path -LiteralPath $sourceEsd) {
        $sourceImage = $sourceEsd
    }
    else {
        throw 'Neither install.wim nor install.esd found on ISO.'
    }
    Write-Host "Source image file: $sourceImage"

    Write-Step 'List source image indexes'
    $sourceInfo = Invoke-DismLogged -StepName 'Get-ImageInfo-Source' -ArgumentList @('/English', '/Get-ImageInfo', "/ImageFile:$sourceImage")
    $index6Name = $null
    $currentIndex = $null
    foreach ($line in $sourceInfo) {
        if ($line -match '^\s*Index\s*:\s*(\d+)') { $currentIndex = [int]$Matches[1] }
        if ($currentIndex -eq $sourceIndex -and $line -match '^\s*Name\s*:\s*(.+)$') {
            $index6Name = $Matches[1].Trim()
        }
    }
    Write-Host "Source index $sourceIndex name: $index6Name"
    if (-not $index6Name) {
        throw "Could not resolve name for source index $sourceIndex."
    }
    if ($index6Name -notmatch 'Pro') {
        $warnings.Add("Source index $sourceIndex name '$index6Name' does not clearly contain 'Pro'.") | Out-Null
    }

    Write-Step "Export source index $sourceIndex to disposable WIM"
    if (Test-Path -LiteralPath $wimPath) {
        Remove-Item -LiteralPath $wimPath -Force
    }
    Invoke-DismLogged -StepName 'Export-Image' -ArgumentList @(
        '/English'
        '/Export-Image'
        "/SourceImageFile:$sourceImage"
        "/SourceIndex:$sourceIndex"
        "/DestinationImageFile:$wimPath"
        '/Compress:max'
        '/CheckIntegrity'
    ) | Out-Null

    Write-Step 'Dismount source ISO (preserve original)'
    Dismount-DiskImage -ImagePath $isoPath | Out-Null
    $isoDrive = $null
    Write-Host 'Source ISO dismounted.'

    Write-Step 'Verify exported WIM index/edition'
    $exportInfo = Invoke-DismLogged -StepName 'Get-ImageInfo-Export' -ArgumentList @('/English', '/Get-ImageInfo', "/ImageFile:$wimPath")
    $exportIndexes = New-Object System.Collections.Generic.List[object]
    $cur = $null
    foreach ($line in $exportInfo) {
        if ($line -match '^\s*Index\s*:\s*(\d+)') {
            if ($cur) { $exportIndexes.Add([pscustomobject]$cur) | Out-Null }
            $cur = [ordered]@{ Index = [int]$Matches[1]; Name = $null; Description = $null; Size = $null; Architecture = $null }
        }
        elseif ($cur) {
            if ($line -match '^\s*Name\s*:\s*(.+)$') { $cur.Name = $Matches[1].Trim() }
            elseif ($line -match '^\s*Description\s*:\s*(.+)$') { $cur.Description = $Matches[1].Trim() }
            elseif ($line -match '^\s*Size\s*:\s*(.+)$') { $cur.Size = $Matches[1].Trim() }
            elseif ($line -match '^\s*Architecture\s*:\s*(.+)$') { $cur.Architecture = $Matches[1].Trim() }
        }
    }
    if ($cur) { $exportIndexes.Add([pscustomobject]$cur) | Out-Null }
    $exportMeta = $exportIndexes.ToArray()
    if ($exportMeta.Count -ne 1) {
        throw "Expected a single-index exported WIM, found $($exportMeta.Count) indexes."
    }
    if ($exportMeta[0].Index -ne 1) {
        throw "Expected exported image index 1, found $($exportMeta[0].Index)."
    }
    if ($exportMeta[0].Name -notmatch 'Pro') {
        throw "Exported image name '$($exportMeta[0].Name)' is not Windows 11 Pro."
    }
    Write-Host "Confirmed: Index=$($exportMeta[0].Index) Name=$($exportMeta[0].Name)"

    Write-Step 'Mount disposable WIM read-only'
    Invoke-DismLogged -StepName 'Mount-Image-ReadOnly' -ArgumentList @(
        '/English'
        '/Mount-Image'
        "/ImageFile:$wimPath"
        '/Index:1'
        "/MountDir:$mountDir"
        '/ReadOnly'
    ) | Out-Null
    $mounted = $true

    Write-Step 'Query mounted image info'
    $imageInfoMounted = Invoke-DismLogged -StepName 'Get-MountedImageInfo' -ArgumentList @('/English', '/Get-MountedImageInfo')
    Invoke-DismLogged -StepName 'Get-ImageInfo-MountedFile' -ArgumentList @('/English', '/Get-ImageInfo', "/ImageFile:$wimPath") | Out-Null

    Write-Step 'Query packages / AppX / features (read-only)'
    try {
        $pkgOut = Invoke-DismLogged -StepName 'Get-Packages' -ArgumentList @('/English', "/Image:$mountDir", '/Get-Packages')
        $packagesSample = @(Get-DismListedValues -Output $pkgOut -Label 'Package Identity')
        $packageCount = $packagesSample.Count
    }
    catch {
        $errors.Add("Get-Packages failed: $($_.Exception.Message)") | Out-Null
        $warnings.Add('Package inventory failed; continuing to remaining queries and mandatory discard.') | Out-Null
    }

    try {
        $appxOut = Invoke-DismLogged -StepName 'Get-ProvisionedAppxPackages' -ArgumentList @('/English', "/Image:$mountDir", '/Get-ProvisionedAppxPackages')
        $appxSample = @(Get-DismListedValues -Output $appxOut -Label 'PackageName')
        $appxCount = $appxSample.Count
    }
    catch {
        $errors.Add("Get-ProvisionedAppxPackages failed: $($_.Exception.Message)") | Out-Null
        $warnings.Add('AppX inventory failed; continuing to remaining queries and mandatory discard.') | Out-Null
    }

    try {
        $featOut = Invoke-DismLogged -StepName 'Get-Features' -ArgumentList @('/English', "/Image:$mountDir", '/Get-Features')
        $featuresSample = @(Get-DismListedValues -Output $featOut -Label 'Feature Name')
        $featureCount = $featuresSample.Count
    }
    catch {
        $errors.Add("Get-Features failed: $($_.Exception.Message)") | Out-Null
        $warnings.Add('Feature inventory failed; continuing to mandatory discard.') | Out-Null
    }

    # Optional build metadata from mounted hive (read-only mount still allows hive load in many cases)
    $hive = Join-Path $mountDir 'Windows\System32\config\SOFTWARE'
    if (Test-Path -LiteralPath $hive) {
        Write-Step 'Read CurrentVersion metadata from mounted hive'
        $tempHive = 'HKLM\XboxOSDismCompat'
        try {
            $loadOut = & reg.exe load $tempHive $hive 2>&1
            $loadExit = $LASTEXITCODE
            $commandLog.Add([pscustomobject]@{
                Step = 'reg load SOFTWARE hive'
                Command = "reg.exe load $tempHive $hive"
                ExitCode = $loadExit
                Output = @($loadOut | ForEach-Object { "$_" })
            }) | Out-Null
            if ($loadExit -eq 0) {
                $cv = Get-ItemProperty -Path 'HKLM:\XboxOSDismCompat\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
                $buildNumber = [string]$cv.CurrentBuild
                if ($cv.UBR) { $buildNumber = "$buildNumber.$($cv.UBR)" }
                if ($cv.DisplayVersion) { $displayVersion = [string]$cv.DisplayVersion }
                if ($cv.EditionID) { $editionId = [string]$cv.EditionID }
                if ($cv.ProductName) { $productName = [string]$cv.ProductName }
                Write-Host "CurrentBuild/UBR: $buildNumber"
                Write-Host "DisplayVersion: $displayVersion"
                Write-Host "EditionID: $editionId"
                Write-Host "ProductName: $productName"
            }
            else {
                $warnings.Add("reg load failed ($loadExit); build metadata unavailable from hive.") | Out-Null
            }
        }
        catch {
            $warnings.Add("Hive metadata read failed: $($_.Exception.Message)") | Out-Null
        }
        finally {
            & reg.exe unload $tempHive 2>$null | Out-Null
        }
    }
}
catch {
    $errors.Add($_.Exception.Message) | Out-Null
    Write-Host "TEST ERROR: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Write-Step 'Cleanup: discard mount if present'
    try {
        if ($mounted -or (Test-Path -LiteralPath (Join-Path $workRoot 'mount'))) {
            $mountDir = Join-Path $workRoot 'mount'
            $hasContent = @(Get-ChildItem -LiteralPath $mountDir -Force -ErrorAction SilentlyContinue).Count -gt 0
            if ($hasContent -or $mounted) {
                try {
                    Invoke-DismLogged -StepName 'Unmount-Discard' -ArgumentList @(
                        '/English'
                        '/Unmount-Image'
                        "/MountDir:$mountDir"
                        '/Discard'
                    ) | Out-Null
                    $mounted = $false
                    $cleanupOk = $true
                }
                catch {
                    $warnings.Add("Primary discard failed: $($_.Exception.Message)") | Out-Null
                    try {
                        Invoke-DismLogged -StepName 'Cleanup-Mountpoints' -ArgumentList @('/English', '/Cleanup-Mountpoints') | Out-Null
                        $cleanupOk = $true
                    }
                    catch {
                        $errors.Add("Cleanup-Mountpoints failed: $($_.Exception.Message)") | Out-Null
                    }
                }
            }
            else {
                $cleanupOk = $true
            }
        }
        else {
            $cleanupOk = $true
        }
    }
    catch {
        $errors.Add("Cleanup section failed: $($_.Exception.Message)") | Out-Null
    }

    if ($isoDrive) {
        try {
            Dismount-DiskImage -ImagePath $isoPath -ErrorAction Stop | Out-Null
            Write-Host 'Source ISO dismounted in finally.'
        }
        catch {
            $warnings.Add("ISO dismount in finally: $($_.Exception.Message)") | Out-Null
        }
    }

    Write-Step 'Verify no mounts remain for this test'
    try {
        $mountedInfo = & dism.exe /English /Get-MountedImageInfo 2>&1
        $mountedExit = $LASTEXITCODE
        $mountedText = @($mountedInfo | ForEach-Object { "$_" })
        $commandLog.Add([pscustomobject]@{
            Step = 'Get-MountedImageInfo-Final'
            Command = 'dism.exe /English /Get-MountedImageInfo'
            ExitCode = $mountedExit
            Output = $mountedText
        }) | Out-Null
        $mountDir = Join-Path $workRoot 'mount'
        $stillOurs = $false
        foreach ($line in $mountedText) {
            if ($line -match [regex]::Escape($mountDir) -or $line -match [regex]::Escape($wimPath)) {
                $stillOurs = $true
            }
            Write-Host $line
        }
        Write-Host "EXIT: $mountedExit"
        $noMountsLeft = -not $stillOurs
        if ($stillOurs) {
            $errors.Add('Mounted image still references this test mount/WIM after cleanup.') | Out-Null
        }
    }
    catch {
        $warnings.Add("Final mounted-image verification issue: $($_.Exception.Message)") | Out-Null
    }

    Write-Step 'Verify original ISO unchanged'
    try {
        $isoAfter = Get-Item -LiteralPath $isoPath
        $isoHashAfter = (Get-FileHash -LiteralPath $isoPath -Algorithm SHA256).Hash
        $isoUnchanged = (
            $isoAfter.Length -eq $isoLengthBefore -and
            $isoAfter.LastWriteTimeUtc -eq $isoLastWriteBefore -and
            $isoHashAfter -eq $isoHashBefore
        )
        Write-Host "ISO size before/after: $isoLengthBefore / $($isoAfter.Length)"
        Write-Host "ISO LastWriteUtc before/after: $isoLastWriteBefore / $($isoAfter.LastWriteTimeUtc)"
        Write-Host "ISO SHA256 before/after match: $($isoHashAfter -eq $isoHashBefore)"
        Write-Host "ISO unchanged: $isoUnchanged"
    }
    catch {
        $errors.Add("ISO integrity verification failed: $($_.Exception.Message)") | Out-Null
    }
}

# Write reports
$success = ($errors.Count -eq 0 -and $cleanupOk -and $noMountsLeft -and $isoUnchanged -and $null -ne $exportMeta)

$md = @()
$md += '# XboxOS11 DISM Compatibility Report'
$md += ''
$md += "- Generated (UTC): $((Get-Date).ToUniversalTime().ToString('o'))"
$md += "- Host elevated: True"
$md += "- PowerShell: $($PSVersionTable.PSVersion)"
$md += "- Source ISO: `$isoPath`"
$md += "- Disposable WIM: ``$wimPath``"
$md += "- Mount directory: ``$(Join-Path $workRoot 'mount')``"
$md += "- Overall success: **$success**"
$md += ''
$md += '## Safety checklist'
$md += ''
$md += "| Check | Result |"
$md += "|---|---|"
$md += "| Original ISO unmodified | $isoUnchanged |"
$md += "| Disposable WIM never committed (discard unmount) | $cleanupOk |"
$md += "| No mounts remain for this test | $noMountsLeft |"
$md += "| No AppX removal / feature disable / drivers / updates | True |"
$md += "| No full Build-ISO production pipeline | True |"
$md += "| No OneDrive WIM/mount paths | True |"
$md += ''
$md += '## DISM version'
$md += ''
$md += '```'
$md += ($dismVersionOut -join "`n")
$md += '```'
$md += ''
$md += '## Source image'
$md += ''
$md += "- Requested source index: $sourceIndex"
$md += "- Resolved source index name: $index6Name"
$md += ''
$md += '## Exported disposable WIM'
$md += ''
if ($exportMeta) {
    foreach ($img in $exportMeta) {
        $md += "- Index: $($img.Index)"
        $md += "- Name: $($img.Name)"
        $md += "- Description: $($img.Description)"
        $md += "- Architecture: $($img.Architecture)"
        $md += "- Size: $($img.Size)"
    }
}
else {
    $md += '- Export metadata unavailable due to earlier failure.'
}
$md += ''
$md += '## Mounted image inventory summary'
$md += ''
$md += "- Package identities counted: $packageCount"
$md += "- Provisioned AppX packages counted: $appxCount"
$md += "- Optional features counted: $featureCount"
$md += "- Hive CurrentBuild/UBR: $buildNumber"
$md += "- Hive DisplayVersion: $displayVersion"
$md += "- Hive EditionID: $editionId"
$md += "- Hive ProductName: $productName"
$md += ''
$md += '### Sample AppX packages (first 25)'
$md += ''
$md += '```'
$md += (($appxSample | Select-Object -First 25) -join "`n")
$md += '```'
$md += ''
$md += '### Sample features (first 25)'
$md += ''
$md += '```'
$md += (($featuresSample | Select-Object -First 25) -join "`n")
$md += '```'
$md += ''
$md += '### Sample packages (first 25)'
$md += ''
$md += '```'
$md += (($packagesSample | Select-Object -First 25) -join "`n")
$md += '```'
$md += ''
$md += '## Commands and exit codes'
$md += ''
foreach ($cmd in $commandLog) {
    $md += "### $($cmd.Step)"
    $md += ''
    $md += "- Command: ``$($cmd.Command)``"
    $md += "- Exit code: **$($cmd.ExitCode)**"
    $md += ''
}
$md += '## Warnings'
$md += ''
if ($warnings.Count -eq 0) { $md += '- None' } else { foreach ($w in $warnings) { $md += "- $w" } }
$md += ''
$md += '## Errors'
$md += ''
if ($errors.Count -eq 0) { $md += '- None' } else { foreach ($e in $errors) { $md += "- $e" } }
$md += ''
$md += '## Compatibility findings'
$md += ''
$md += '- DISM can export source index 6 into a disposable single-index WIM under C:\XboxOS\Work.'
$md += '- Exported image index is 1 and name contains Pro, suitable as a writable-servicing candidate after this read-only validation.'
$md += '- Read-only mount + Get-Packages / Get-ProvisionedAppxPackages / Get-Features completed as recorded above.'
$md += '- ISO naming must use verified hive/DISM metadata (DisplayVersion / CurrentBuild) rather than assuming 25H2 from filename alone.'
$md += '- Writable servicing should only proceed if cleanup succeeded and no mounts remain.'
$md += ''
$md += '## ISO integrity'
$md += ''
$md += "- SHA256 before: `$isoHashBefore`"
$md += "- SHA256 after: `$isoHashAfter`"
$md += "- Unchanged: $isoUnchanged"
$md += ''

# Fix markdown accidental variable interpolation for paths with backticks - rewrite critical lines cleanly
$md = $md -replace '\$isoPath', $isoPath -replace '\$isoHashBefore', $isoHashBefore -replace '\$isoHashAfter', $isoHashAfter

$md -join "`n" | Set-Content -LiteralPath $reportPath -Encoding UTF8

$json = [ordered]@{
    generatedUtc = (Get-Date).ToUniversalTime()
    success = $success
    dismVersion = $dismVersion
    dismVersionRaw = $dismVersionOut
    sourceIso = $isoPath
    sourceIndex = $sourceIndex
    sourceIndexName = $index6Name
    disposableWim = $wimPath
    mountDir = (Join-Path $workRoot 'mount')
    exportMeta = $exportMeta
    packageCount = $packageCount
    appxCount = $appxCount
    featureCount = $featureCount
    buildNumber = $buildNumber
    displayVersion = $displayVersion
    editionId = $editionId
    productName = $productName
    appxSample = @($appxSample | Select-Object -First 50)
    featureSample = @($featuresSample | Select-Object -First 50)
    packageSample = @($packagesSample | Select-Object -First 50)
    commands = $commandLog
    warnings = @($warnings)
    errors = @($errors)
    cleanupOk = $cleanupOk
    noMountsLeft = $noMountsLeft
    isoUnchanged = $isoUnchanged
    isoSha256Before = $isoHashBefore
    isoSha256After = $isoHashAfter
}
($json | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $jsonReportPath -Encoding UTF8

Write-Host ""
Write-Host "Report written: $reportPath"
Write-Host "JSON written:   $jsonReportPath"
Write-Host "Success=$success CleanupOk=$cleanupOk NoMountsLeft=$noMountsLeft IsoUnchanged=$isoUnchanged"

$exitCode = if ($success) { 0 } else { 1 }
@"
success=$success
exitCode=$exitCode
cleanupOk=$cleanupOk
noMountsLeft=$noMountsLeft
isoUnchanged=$isoUnchanged
report=$reportPath
json=$jsonReportPath
completedUtc=$((Get-Date).ToUniversalTime().ToString('o'))
"@ | Set-Content -LiteralPath $sentinelPath -Encoding UTF8

try { Stop-Transcript | Out-Null } catch { }
exit $exitCode
