#Requires -Version 5.1
# Isolated DISM compatibility test for XboxOS11 M1.5
# Safety: read-only mount, discard unmount, never modify source ISO.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\modules\XboxOS.Build\XboxOS.Build.psd1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    if ($env:XBOXOS11_ROOT) {
        $modulePath = Join-Path $env:XBOXOS11_ROOT 'modules\XboxOS.Build\XboxOS.Build.psd1'
    }
}
if (-not (Test-Path -LiteralPath $modulePath)) {
    $fallbackRepo = 'C:\Users\schmi\OneDrive\WinDev Apps\XboxOS11\modules\XboxOS.Build\XboxOS.Build.psd1'
    if (Test-Path -LiteralPath $fallbackRepo) {
        $modulePath = $fallbackRepo
    }
}
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw 'XboxOS.Build module not found. Run from repository scripts\ or set XBOXOS11_ROOT.'
}
Import-Module $modulePath -Force

$transcriptPath = 'C:\XboxOS\Logs\DISM-Compatibility-20261014.transcript.log'
$sentinelPath = 'C:\XboxOS\Logs\DISM-Compatibility-20261014.done'
New-Item -ItemType Directory -Path 'C:\XboxOS\Logs' -Force | Out-Null
if (Test-Path -LiteralPath $sentinelPath) { Remove-Item -LiteralPath $sentinelPath -Force }
try { Stop-Transcript | Out-Null } catch { }
Start-Transcript -Path $transcriptPath -Force | Out-Null

$isoPath = 'C:\XboxOS\Sources\Windows11_Client_x64_en-us_26300_9457.iso'
$workRoot = 'C:\XboxOS\Work\dism-compat-20261014'
$logsRoot = 'C:\XboxOS\Logs'
$expectedEditionName = 'Windows 11 Pro'
$sourceIndex = $null
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
$sourceIndexName = $null
$sourceImageCatalog = @()
$sourceSelection = $null
$sourceSelectionVerified = $false
$exportVerified = $false
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
    $sourceImageCatalog = @(ConvertFrom-XboxOSDismImageInfoOutput -Output $sourceInfo)
    foreach ($entry in $sourceImageCatalog) {
        Write-Host ("Source catalog: Index={0} Name={1}" -f $entry.Index, $entry.Name)
    }

    Write-Step ("Select exact edition '{0}'" -f $expectedEditionName)
    $sourceSelection = Resolve-XboxOSExactImageIndex -Images $sourceImageCatalog -ExactName $expectedEditionName
    $sourceIndex = [int]$sourceSelection.Index
    $sourceIndexName = [string]$sourceSelection.Name
    if ($sourceIndex -lt 1) {
        throw "Selected source index '$sourceIndex' is invalid."
    }
    if (-not [string]::Equals($sourceIndexName.Trim(), $expectedEditionName, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("Selected source name '{0}' does not exactly match '{1}'." -f $sourceIndexName, $expectedEditionName)
    }
    $sourceSelectionVerified = $true
    Write-Host ("Selected source index {0} ('{1}') after exact-name verification." -f $sourceIndex, $sourceIndexName)

    Write-Step ("Export verified source index {0} to disposable WIM" -f $sourceIndex)
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
    $exportMeta = @(ConvertFrom-XboxOSDismImageInfoOutput -Output $exportInfo)
    if ($exportMeta.Count -ne 1) {
        throw "Expected a single-index exported WIM, found $($exportMeta.Count) indexes."
    }
    if ($exportMeta[0].Index -ne 1) {
        throw "Expected exported image index 1, found $($exportMeta[0].Index)."
    }
    if (-not [string]::Equals([string]$exportMeta[0].Name.Trim(), $expectedEditionName, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("Exported image name '{0}' does not exactly match '{1}'." -f $exportMeta[0].Name, $expectedEditionName)
    }
    $exportVerified = $true
    Write-Host ("Confirmed export: Index={0} Name={1}" -f $exportMeta[0].Index, $exportMeta[0].Name)

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
$success = (
    $errors.Count -eq 0 -and
    $cleanupOk -and
    $noMountsLeft -and
    $isoUnchanged -and
    $sourceSelectionVerified -and
    $exportVerified -and
    $null -ne $exportMeta
)
$generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
$mountPathForReport = Join-Path $workRoot 'mount'
$nl = [Environment]::NewLine

$mdLines = New-Object System.Collections.Generic.List[string]
$null = $mdLines.Add('# XboxOS11 DISM Compatibility Report')
$null = $mdLines.Add('')
$null = $mdLines.Add(('- Generated (UTC): {0}' -f $generatedUtc))
$null = $mdLines.Add('- Host elevated: True')
$null = $mdLines.Add(('- PowerShell: {0}' -f $PSVersionTable.PSVersion))
$null = $mdLines.Add(('- Source ISO: `{0}`' -f $isoPath))
$null = $mdLines.Add(('- Disposable WIM: `{0}`' -f $wimPath))
$null = $mdLines.Add(('- Mount directory: `{0}`' -f $mountPathForReport))
$null = $mdLines.Add(('- Overall success: **{0}**' -f $success))
$null = $mdLines.Add('')
$null = $mdLines.Add('## Safety checklist')
$null = $mdLines.Add('')
$null = $mdLines.Add('| Check | Result |')
$null = $mdLines.Add('|---|---|')
$null = $mdLines.Add(('| Original ISO unmodified | {0} |' -f $isoUnchanged))
$null = $mdLines.Add(('| Disposable WIM never committed (discard unmount) | {0} |' -f $cleanupOk))
$null = $mdLines.Add(('| No mounts remain for this test | {0} |' -f $noMountsLeft))
$null = $mdLines.Add('| No AppX removal / feature disable / drivers / updates | True |')
$null = $mdLines.Add('| No full Build-ISO production pipeline | True |')
$null = $mdLines.Add('| No OneDrive WIM/mount paths | True |')
$null = $mdLines.Add(('| Source edition selected by exact name (no index-6 fallback) | {0} |' -f $sourceSelectionVerified))
$null = $mdLines.Add(('| Exported WIM index 1 is Windows 11 Pro | {0} |' -f $exportVerified))
$null = $mdLines.Add('')
$null = $mdLines.Add('## DISM version')
$null = $mdLines.Add('')
$null = $mdLines.Add('```')
$null = $mdLines.Add((@($dismVersionOut) -join $nl))
$null = $mdLines.Add('```')
$null = $mdLines.Add('')
$null = $mdLines.Add('## Source image selection')
$null = $mdLines.Add('')
$null = $mdLines.Add(('- Expected edition name: `{0}`' -f $expectedEditionName))
$null = $mdLines.Add(('- Selected source index: {0}' -f $sourceIndex))
$null = $mdLines.Add(('- Selected source image name: `{0}`' -f $sourceIndexName))
$null = $mdLines.Add(('- Source selection verified before export: {0}' -f $sourceSelectionVerified))
$null = $mdLines.Add('')
$null = $mdLines.Add('### Source catalog')
$null = $mdLines.Add('')
if (@($sourceImageCatalog).Count -gt 0) {
    foreach ($entry in $sourceImageCatalog) {
        $null = $mdLines.Add(('- Index {0}: `{1}`' -f $entry.Index, $entry.Name))
    }
}
else {
    $null = $mdLines.Add('- Source catalog unavailable due to earlier failure.')
}
$null = $mdLines.Add('')
$null = $mdLines.Add('## Exported disposable WIM')
$null = $mdLines.Add('')
$null = $mdLines.Add(('- Export verified (index 1 / exact Windows 11 Pro): {0}' -f $exportVerified))
$null = $mdLines.Add('')
if ($exportMeta) {
    foreach ($img in $exportMeta) {
        $null = $mdLines.Add(('- Index: {0}' -f $img.Index))
        $null = $mdLines.Add(('- Name: {0}' -f $img.Name))
        $null = $mdLines.Add(('- Description: {0}' -f $img.Description))
        $null = $mdLines.Add(('- Architecture: {0}' -f $img.Architecture))
        $null = $mdLines.Add(('- Size: {0}' -f $img.Size))
    }
}
else {
    $null = $mdLines.Add('- Export metadata unavailable due to earlier failure.')
}
$null = $mdLines.Add('')
$null = $mdLines.Add('## Mounted image inventory summary')
$null = $mdLines.Add('')
$null = $mdLines.Add(('- Package identities counted: {0}' -f $packageCount))
$null = $mdLines.Add(('- Provisioned AppX packages counted: {0}' -f $appxCount))
$null = $mdLines.Add(('- Optional features counted: {0}' -f $featureCount))
$null = $mdLines.Add(('- Hive CurrentBuild/UBR: {0}' -f $buildNumber))
$null = $mdLines.Add(('- Hive DisplayVersion: {0}' -f $displayVersion))
$null = $mdLines.Add(('- Hive EditionID: {0}' -f $editionId))
$null = $mdLines.Add(('- Hive ProductName: {0}' -f $productName))
$null = $mdLines.Add('')
$null = $mdLines.Add('### Sample AppX packages (first 25)')
$null = $mdLines.Add('')
$null = $mdLines.Add('```')
$null = $mdLines.Add((@($appxSample | Select-Object -First 25) -join $nl))
$null = $mdLines.Add('```')
$null = $mdLines.Add('')
$null = $mdLines.Add('### Sample features (first 25)')
$null = $mdLines.Add('')
$null = $mdLines.Add('```')
$null = $mdLines.Add((@($featuresSample | Select-Object -First 25) -join $nl))
$null = $mdLines.Add('```')
$null = $mdLines.Add('')
$null = $mdLines.Add('### Sample packages (first 25)')
$null = $mdLines.Add('')
$null = $mdLines.Add('```')
$null = $mdLines.Add((@($packagesSample | Select-Object -First 25) -join $nl))
$null = $mdLines.Add('```')
$null = $mdLines.Add('')
$null = $mdLines.Add('## Commands and exit codes')
$null = $mdLines.Add('')
foreach ($cmd in $commandLog) {
    $null = $mdLines.Add(('### {0}' -f $cmd.Step))
    $null = $mdLines.Add('')
    $null = $mdLines.Add(('- Command: `{0}`' -f $cmd.Command))
    $null = $mdLines.Add(('- Exit code: **{0}**' -f $cmd.ExitCode))
    $null = $mdLines.Add('')
}
$null = $mdLines.Add('## Warnings')
$null = $mdLines.Add('')
if ($warnings.Count -eq 0) {
    $null = $mdLines.Add('- None')
}
else {
    foreach ($warningItem in $warnings) {
        $null = $mdLines.Add(('- {0}' -f $warningItem))
    }
}
$null = $mdLines.Add('')
$null = $mdLines.Add('## Errors')
$null = $mdLines.Add('')
if ($errors.Count -eq 0) {
    $null = $mdLines.Add('- None')
}
else {
    foreach ($errorItem in $errors) {
        $null = $mdLines.Add(('- {0}' -f $errorItem))
    }
}
$null = $mdLines.Add('')
$null = $mdLines.Add('## Compatibility findings')
$null = $mdLines.Add('')
$null = $mdLines.Add('- Source Windows 11 Pro index is discovered via DISM /Get-ImageInfo exact-name matching; index 6 is never assumed.')
$null = $mdLines.Add('- DISM can export the verified Pro source index into a disposable single-index WIM under C:\XboxOS\Work.')
$null = $mdLines.Add('- Exported image index is 1 and name exactly matches Windows 11 Pro, suitable as a writable-servicing candidate after this read-only validation.')
$null = $mdLines.Add('- Read-only mount + Get-Packages / Get-ProvisionedAppxPackages / Get-Features completed as recorded above.')
$null = $mdLines.Add('- ISO naming must use verified hive/DISM metadata (DisplayVersion / CurrentBuild) rather than assuming 25H2 from filename alone.')
$null = $mdLines.Add('- Writable servicing should only proceed if cleanup succeeded and no mounts remain.')
$null = $mdLines.Add('')
$null = $mdLines.Add('## ISO integrity')
$null = $mdLines.Add('')
$null = $mdLines.Add(('- SHA256 before: `{0}`' -f $isoHashBefore))
$null = $mdLines.Add(('- SHA256 after: `{0}`' -f $isoHashAfter))
$null = $mdLines.Add(('- Unchanged: {0}' -f $isoUnchanged))
$null = $mdLines.Add('')

($mdLines -join $nl) | Set-Content -LiteralPath $reportPath -Encoding UTF8

$json = [ordered]@{
    generatedUtc              = (Get-Date).ToUniversalTime()
    success                   = $success
    dismVersion               = $dismVersion
    dismVersionRaw            = $dismVersionOut
    sourceIso                 = $isoPath
    expectedEditionName       = $expectedEditionName
    sourceIndex               = $sourceIndex
    sourceIndexName           = $sourceIndexName
    sourceSelectionVerified   = $sourceSelectionVerified
    sourceImageCatalog        = @($sourceImageCatalog)
    sourceSelection           = $sourceSelection
    exportVerified            = $exportVerified
    disposableWim             = $wimPath
    mountDir                  = $mountPathForReport
    exportMeta                = $exportMeta
    packageCount              = $packageCount
    appxCount                 = $appxCount
    featureCount              = $featureCount
    buildNumber               = $buildNumber
    displayVersion            = $displayVersion
    editionId                 = $editionId
    productName               = $productName
    appxSample                = @($appxSample | Select-Object -First 50)
    featureSample             = @($featuresSample | Select-Object -First 50)
    packageSample             = @($packagesSample | Select-Object -First 50)
    commands                  = $commandLog
    warnings                  = @($warnings)
    errors                    = @($errors)
    cleanupOk                 = $cleanupOk
    noMountsLeft              = $noMountsLeft
    isoUnchanged              = $isoUnchanged
    isoSha256Before           = $isoHashBefore
    isoSha256After            = $isoHashAfter
}
($json | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $jsonReportPath -Encoding UTF8

Write-Host ''
Write-Host ('Report written: {0}' -f $reportPath)
Write-Host ('JSON written:   {0}' -f $jsonReportPath)
Write-Host ('Success={0} CleanupOk={1} NoMountsLeft={2} IsoUnchanged={3}' -f $success, $cleanupOk, $noMountsLeft, $isoUnchanged)

$exitCode = if ($success) { 0 } else { 1 }
$sentinelBody = @(
    ('success={0}' -f $success)
    ('exitCode={0}' -f $exitCode)
    ('cleanupOk={0}' -f $cleanupOk)
    ('noMountsLeft={0}' -f $noMountsLeft)
    ('isoUnchanged={0}' -f $isoUnchanged)
    ('report={0}' -f $reportPath)
    ('json={0}' -f $jsonReportPath)
    ('completedUtc={0}' -f $generatedUtc)
) -join $nl
$sentinelBody | Set-Content -LiteralPath $sentinelPath -Encoding UTF8

try { Stop-Transcript | Out-Null } catch { Write-Verbose 'Stop-Transcript skipped.' }
exit $exitCode
