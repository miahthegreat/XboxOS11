# Milestone 4 disposable-image read-only preflight. Dotted into XboxOS.Build.psm1.
# Live DISM mounts/exports are gated; CI uses mocks/fixtures only.

$script:XboxOSPreflightEngineVersion = '4.1.2'
$script:XboxOSReadOnlyDismAdapterVersion = 'readonly-dism-v1'
$script:XboxOSDisposableWorkspaceSchemaVersion = 'workspace-v1'
$script:XboxOSImageIntegritySchemaVersion = 'image-integrity-v1'
$script:XboxOSApprovalAuthSchemaVersion = 'approval-auth-v1'
$script:XboxOSExpectedIsoSha256 = 'BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650'
$script:XboxOSExpectedEditionName = 'Windows 11 Pro'
$script:XboxOSExpectedBuildNumber = '26300.9457'
$script:XboxOSExpectedDisplayVersion = '26H2'

$script:XboxOSReadOnlyDismOperations = [ordered]@{
    GetDismVersion              = [ordered]@{ Class = 'PureInspection'; Template = @('/English', '/?') }
    GetImageInfo                = [ordered]@{ Class = 'PureInspection'; Template = @('/English', '/Get-ImageInfo', '/ImageFile:{ImageFile}') }
    ExportImage                 = [ordered]@{ Class = 'DisposablePreparation'; Template = @('/English', '/Export-Image', '/SourceImageFile:{SourceImageFile}', '/SourceIndex:{SourceIndex}', '/DestinationImageFile:{DestinationImageFile}', '/Compress:max', '/CheckIntegrity') }
    GetExportedImageInfo        = [ordered]@{ Class = 'PureInspection'; Template = @('/English', '/Get-ImageInfo', '/ImageFile:{ImageFile}') }
    MountImageReadOnly          = [ordered]@{ Class = 'DisposablePreparation'; Template = @('/English', '/Mount-Image', '/ImageFile:{ImageFile}', '/Index:{Index}', '/MountDir:{MountDir}', '/ReadOnly') }
    GetPackages                 = [ordered]@{ Class = 'PureInspection'; Template = @('/English', '/Image:{MountDir}', '/Get-Packages') }
    GetProvisionedAppxPackages  = [ordered]@{ Class = 'PureInspection'; Template = @('/English', '/Image:{MountDir}', '/Get-ProvisionedAppxPackages') }
    GetFeatures                 = [ordered]@{ Class = 'PureInspection'; Template = @('/English', '/Image:{MountDir}', '/Get-Features') }
    GetMountedImageInfo         = [ordered]@{ Class = 'PureInspection'; Template = @('/English', '/Get-MountedImageInfo') }
    UnmountDiscard              = [ordered]@{ Class = 'Cleanup'; Template = @('/English', '/Unmount-Image', '/MountDir:{MountDir}', '/Discard') }
}

$script:XboxOSProhibitedDismTokens = @(
    '/Commit', '/Remove-ProvisionedAppxPackage', '/Disable-Feature', '/Enable-Feature',
    '/Add-Driver', '/Add-Package', '/Apply-Image', '/Capture-Image', '/Cleanup-Mountpoints',
    '/Remount-Image', '/Set-ProductKey', '/ScratchDir'
)

function Get-XboxOSPreflightEngineVersion {
    [CmdletBinding()]
    param()
    return $script:XboxOSPreflightEngineVersion
}

function Get-XboxOSReadOnlyDismAdapterVersion {
    [CmdletBinding()]
    param()
    return $script:XboxOSReadOnlyDismAdapterVersion
}

function Get-XboxOSExpectedSourceIsoSha256 {
    [CmdletBinding()]
    param()
    return $script:XboxOSExpectedIsoSha256
}

function Test-XboxOSDismArgumentListMatchesAllowlist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ArgumentList
    )

    foreach ($operation in @($script:XboxOSReadOnlyDismOperations.Keys)) {
        $template = @($script:XboxOSReadOnlyDismOperations[$operation].Template)
        if ($template.Count -ne @($ArgumentList).Count) {
            continue
        }
        $matched = $true
        for ($i = 0; $i -lt $template.Count; $i++) {
            $token = [string]$template[$i]
            $actual = [string]$ArgumentList[$i]
            if ($token -match '^(?<prefix>.+):\{[A-Za-z]+\}$') {
                $prefix = $Matches['prefix'] + ':'
                if (-not $actual.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $matched = $false
                    break
                }
                $value = $actual.Substring($prefix.Length)
                if ([string]::IsNullOrWhiteSpace($value) -or (Test-XboxOSPathContainsTraversal -Path $value)) {
                    $matched = $false
                    break
                }
            }
            elseif ($token -match '\{[A-Za-z]+\}') {
                if ([string]::IsNullOrWhiteSpace($actual) -or (Test-XboxOSPathContainsTraversal -Path $actual)) {
                    $matched = $false
                    break
                }
            }
            elseif (-not [string]::Equals($token, $actual, [System.StringComparison]::OrdinalIgnoreCase)) {
                $matched = $false
                break
            }
        }
        if ($matched) {
            return [pscustomobject]@{
                Allowed   = $true
                Reason    = "Matched allowlisted operation '$operation'."
                Class     = [string]$script:XboxOSReadOnlyDismOperations[$operation].Class
                Operation = $operation
            }
        }
    }

    return [pscustomobject]@{
        Allowed   = $false
        Reason    = 'Argument list does not match any readonly-dism-v1 operation template.'
        Class     = 'Prohibited'
        Operation = $null
    }
}

function Test-XboxOSDismArgumentListAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$ArgumentList
    )

    $joined = ($ArgumentList -join ' ')
    foreach ($token in $script:XboxOSProhibitedDismTokens) {
        if ($joined -match [regex]::Escape($token)) {
            return [pscustomobject]@{
                Allowed = $false
                Reason  = "Prohibited DISM token detected: $token"
                Class   = 'Prohibited'
            }
        }
    }

    # Writable mount without /ReadOnly is prohibited.
    if ($joined -match '/Mount-Image' -and $joined -notmatch '/ReadOnly') {
        return [pscustomobject]@{
            Allowed = $false
            Reason  = 'Mount-Image without /ReadOnly is prohibited.'
            Class   = 'Prohibited'
        }
    }

    $shape = Test-XboxOSDismArgumentListMatchesAllowlist -ArgumentList @($ArgumentList)
    if (-not $shape.Allowed) {
        return $shape
    }

    return [pscustomobject]@{
        Allowed   = $true
        Reason    = $shape.Reason
        Class     = $shape.Class
        Operation = $shape.Operation
    }
}

function Test-XboxOSContinuousIntegrationEnvironment {
    [CmdletBinding()]
    param()

    return [bool](
        ($env:GITHUB_ACTIONS -eq 'true') -or
        ($env:CI -eq 'true') -or
        ($env:TF_BUILD -eq 'True')
    )
}

function ConvertTo-XboxOSNormalizedBuildNumber {
    [CmdletBinding()]
    param([string]$VersionText)

    if ([string]::IsNullOrWhiteSpace($VersionText)) { return $null }
    $text = $VersionText.Trim()
    if ($text -match '^10\.0\.(\d+)\.(\d+)$') {
        return ('{0}.{1}' -f $Matches[1], $Matches[2])
    }
    if ($text -match '^(\d+)\.(\d+)$') {
        return $text
    }
    return $null
}

function Get-XboxOSExpectedSourceImageIdentity {
    [CmdletBinding()]
    param()

    return [pscustomobject]@{
        editionName    = $script:XboxOSExpectedEditionName
        buildNumber    = $script:XboxOSExpectedBuildNumber
        displayVersion = $script:XboxOSExpectedDisplayVersion
        isoSha256      = Get-XboxOSExpectedSourceIsoSha256
    }
}

function Assert-XboxOSObservedSourceImageIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Observed,
        [object]$Expected = $null
    )

    if (-not $Expected) { $Expected = Get-XboxOSExpectedSourceImageIdentity }
    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($field in @('editionName', 'buildNumber', 'displayVersion', 'isoSha256')) {
        $value = $null
        if ($Observed.PSObject.Properties[$field]) { $value = [string]$Observed.$field }
        if ([string]::IsNullOrWhiteSpace($value)) {
            $null = $errors.Add("Observed source image missing required field '$field'.")
        }
    }
    if ($Observed.PSObject.Properties['exportedIndex'] -and [int]$Observed.exportedIndex -ne 1) {
        $null = $errors.Add(("Observed exported index must be 1; was {0}." -f $Observed.exportedIndex))
    }
    if ($Observed.PSObject.Properties['sourceIndex'] -and [int]$Observed.sourceIndex -lt 1) {
        $null = $errors.Add('Observed source index is invalid.')
    }

    if ($Observed.editionName -and -not [string]::Equals([string]$Observed.editionName.Trim(), [string]$Expected.editionName, [System.StringComparison]::OrdinalIgnoreCase)) {
        $null = $errors.Add(("Observed edition '{0}' does not match expected '{1}'." -f $Observed.editionName, $Expected.editionName))
    }
    if ($Observed.buildNumber -and -not [string]::Equals([string]$Observed.buildNumber, [string]$Expected.buildNumber, [System.StringComparison]::OrdinalIgnoreCase)) {
        $null = $errors.Add(("Observed buildNumber '{0}' does not match expected '{1}'." -f $Observed.buildNumber, $Expected.buildNumber))
    }
    if ($Observed.displayVersion -and -not [string]::Equals([string]$Observed.displayVersion, [string]$Expected.displayVersion, [System.StringComparison]::OrdinalIgnoreCase)) {
        $null = $errors.Add(("Observed displayVersion '{0}' does not match expected '{1}'." -f $Observed.displayVersion, $Expected.displayVersion))
    }
    if ($Observed.isoSha256 -and -not [string]::Equals([string]$Observed.isoSha256, [string]$Expected.isoSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        $null = $errors.Add(("Observed isoSha256 '{0}' does not match expected '{1}'." -f $Observed.isoSha256, $Expected.isoSha256))
    }

    if ($errors.Count -gt 0) {
        throw ('Observed source image identity verification failed: {0}' -f ($errors -join ' '))
    }
}

function New-XboxOSOwnedRegistryHiveMountSpec {
    [CmdletBinding()]
    param(
        [string]$RunId = '',
        [string]$OwnershipSeed = ''
    )

    if (-not $RunId) {
        $RunId = [datetime]::UtcNow.ToString('yyyyMMddHHmmssfff')
    }
    $sanitized = ($RunId -replace '[^A-Za-z0-9\-]', '')
    if ([string]::IsNullOrWhiteSpace($sanitized)) {
        $sanitized = [datetime]::UtcNow.ToString('yyyyMMddHHmmssfff')
    }
    $safeLen = [math]::Min(24, $sanitized.Length)
    $safeRun = $sanitized.Substring(0, $safeLen)
    $nonce = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $leafName = 'XboxOSPreflight-{0}-{1}' -f $safeRun, $nonce
    if (-not $OwnershipSeed) {
        $OwnershipSeed = '{0}|{1}|{2}' -f $leafName, $PID, [guid]::NewGuid().ToString('N')
    }
    $ownershipToken = Get-XboxOSUtf8Sha256Hex -Text ("{0}|{1}|{2}" -f $leafName, $OwnershipSeed, $PID)

    return [pscustomobject]@{
        leafName           = $leafName
        regKeyPath         = "HKLM\$leafName"
        psProviderPath     = "HKLM:\$leafName"
        ownershipToken     = $ownershipToken
        ownershipSeed      = $OwnershipSeed
        ownerProcessId     = $PID
        createdUtc         = [datetime]::UtcNow
        loadedByThisRun    = $false
        unloadVerified     = $false
    }
}

function Test-XboxOSRegistryHiveMountPresent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LeafName,
        [scriptblock]$PresenceTester = $null
    )

    if ([string]::IsNullOrWhiteSpace($LeafName)) {
        throw 'LeafName is required for registry hive presence test.'
    }
    if ($LeafName -match '[\\/]' -or $LeafName -match '\.\.') {
        throw "Refusing unsafe registry hive leaf name: $LeafName"
    }
    if ($PresenceTester) {
        return [bool](& $PresenceTester -LeafName $LeafName)
    }
    return [bool](Test-Path -LiteralPath ("HKLM:\{0}" -f $LeafName))
}

function Assert-XboxOSOwnedRegistryHiveMount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$HiveMountSpec,
        [Parameter(Mandatory)][string]$ExpectedOwnershipToken
    )

    if (-not $HiveMountSpec -or [string]::IsNullOrWhiteSpace([string]$HiveMountSpec.leafName)) {
        throw 'Registry hive mount spec is missing leafName.'
    }
    if ($HiveMountSpec.ownerProcessId -ne $PID) {
        throw ("Refusing registry hive operation for mount owned by another process. leaf={0} ownerPid={1} thisPid={2}" -f `
                $HiveMountSpec.leafName, $HiveMountSpec.ownerProcessId, $PID)
    }
    if (-not [string]::Equals([string]$HiveMountSpec.ownershipToken, $ExpectedOwnershipToken, [System.StringComparison]::Ordinal)) {
        throw ("Registry hive ownership token mismatch for leaf '{0}'." -f $HiveMountSpec.leafName)
    }
    if ($HiveMountSpec.leafName -notmatch '^XboxOSPreflight-[A-Za-z0-9\-]+$') {
        throw ("Registry hive leaf name is not a valid XboxOS preflight mount: {0}" -f $HiveMountSpec.leafName)
    }
}

function Invoke-XboxOSOwnedRegistryHiveUnload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$HiveMountSpec,
        [Parameter(Mandatory)][string]$ExpectedOwnershipToken,
        [scriptblock]$RegUnload = $null,
        [scriptblock]$PresenceTester = $null
    )

    Assert-XboxOSOwnedRegistryHiveMount -HiveMountSpec $HiveMountSpec -ExpectedOwnershipToken $ExpectedOwnershipToken

    $presentBefore = Test-XboxOSRegistryHiveMountPresent -LeafName $HiveMountSpec.leafName -PresenceTester $PresenceTester
    if (-not $presentBefore) {
        $HiveMountSpec.unloadVerified = $true
        $HiveMountSpec.loadedByThisRun = $false
        return [pscustomobject]@{
            verified     = $true
            alreadyAbsent = $true
            leafName     = $HiveMountSpec.leafName
            unloadExitCode = 0
            unloadOutput = @('Hive already absent before unload.')
        }
    }

    $unloadOutput = @()
    $unloadExit = $null
    if ($RegUnload) {
        $result = & $RegUnload -RegKeyPath $HiveMountSpec.regKeyPath -LeafName $HiveMountSpec.leafName
        if ($result -is [hashtable] -or $result -is [System.Collections.IDictionary]) {
            if ($result.ContainsKey('ExitCode')) { $unloadExit = [int]$result.ExitCode }
            if ($result.ContainsKey('Output')) { $unloadOutput = @($result.Output) }
        }
        else {
            if ($result.PSObject.Properties['ExitCode']) { $unloadExit = [int]$result.ExitCode }
            if ($result.PSObject.Properties['Output']) { $unloadOutput = @($result.Output) }
        }
    }
    else {
        $raw = & reg.exe unload $HiveMountSpec.regKeyPath 2>&1
        $unloadExit = $LASTEXITCODE
        $unloadOutput = @($raw | ForEach-Object { "$_" })
    }

    if ($null -eq $unloadExit -or [int]$unloadExit -ne 0) {
        throw ("RecoveryRequired: reg.exe unload failed for owned hive '{0}' with exit code {1}. Output: {2}" -f `
                $HiveMountSpec.leafName, $unloadExit, ($unloadOutput -join ' '))
    }

    $stillPresent = Test-XboxOSRegistryHiveMountPresent -LeafName $HiveMountSpec.leafName -PresenceTester $PresenceTester
    if ($stillPresent) {
        throw ("RecoveryRequired: owned registry hive '{0}' still present after unload exit code 0." -f $HiveMountSpec.leafName)
    }

    $HiveMountSpec.unloadVerified = $true
    $HiveMountSpec.loadedByThisRun = $false
    return [pscustomobject]@{
        verified       = $true
        alreadyAbsent  = $false
        leafName       = $HiveMountSpec.leafName
        unloadExitCode = [int]$unloadExit
        unloadOutput   = $unloadOutput
    }
}

function Get-XboxOSMountedImageHiveMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MountDir,
        [scriptblock]$HiveReader = $null,
        [string]$RunId = '',
        [string]$OwnershipSeed = '',
        [scriptblock]$RegLoad = $null,
        [scriptblock]$RegUnload = $null,
        [scriptblock]$PresenceTester = $null,
        [scriptblock]$CurrentVersionReader = $null
    )

    if ($HiveReader) {
        $result = & $HiveReader -MountDir $MountDir
        if ($null -eq $result) {
            throw 'HiveReader returned no mounted-image metadata.'
        }
        $injectedMount = $null
        if ($result.PSObject.Properties['hiveMount']) { $injectedMount = $result.hiveMount }
        return [pscustomobject]@{
            buildNumber              = $(if ($result.PSObject.Properties['buildNumber']) { [string]$result.buildNumber } else { $null })
            displayVersion           = $(if ($result.PSObject.Properties['displayVersion']) { [string]$result.displayVersion } else { $null })
            editionId                = $(if ($result.PSObject.Properties['editionId']) { [string]$result.editionId } else { $null })
            productName              = $(if ($result.PSObject.Properties['productName']) { [string]$result.productName } else { $null })
            architecture             = $(if ($result.PSObject.Properties['architecture']) { [string]$result.architecture } else { $null })
            metadataSource           = 'injected-hive-reader'
            hiveMount                = $injectedMount
            hiveCleanupVerified      = $true
            hiveCleanupNotApplicable = $true
        }
    }

    $hive = Join-Path $MountDir 'Windows\System32\config\SOFTWARE'
    $harnessedRegistry = [bool]($RegLoad -or $RegUnload -or $PresenceTester -or $CurrentVersionReader)
    if (-not $harnessedRegistry -and -not (Test-Path -LiteralPath $hive)) {
        throw "Mounted SOFTWARE hive not found under mount dir: $hive"
    }

    $mountSpec = New-XboxOSOwnedRegistryHiveMountSpec -RunId $RunId -OwnershipSeed $OwnershipSeed
    $ownedToken = [string]$mountSpec.ownershipToken

    if (Test-XboxOSRegistryHiveMountPresent -LeafName $mountSpec.leafName -PresenceTester $PresenceTester) {
        throw ("Refusing to overwrite preexisting registry hive mount '{0}'." -f $mountSpec.leafName)
    }

    $queryError = $null
    $cleanupError = $null
    $metadata = $null
    $loadExit = $null
    $loadOutput = @()

    try {
        Assert-XboxOSOwnedRegistryHiveMount -HiveMountSpec $mountSpec -ExpectedOwnershipToken $ownedToken

        if ($RegLoad) {
            $loadResult = & $RegLoad -RegKeyPath $mountSpec.regKeyPath -HiveFile $hive -LeafName $mountSpec.leafName
            if ($loadResult -is [hashtable] -or $loadResult -is [System.Collections.IDictionary]) {
                if ($loadResult.ContainsKey('ExitCode')) { $loadExit = [int]$loadResult.ExitCode }
                if ($loadResult.ContainsKey('Output')) { $loadOutput = @($loadResult.Output) }
            }
            else {
                if ($loadResult.PSObject.Properties['ExitCode']) { $loadExit = [int]$loadResult.ExitCode }
                if ($loadResult.PSObject.Properties['Output']) { $loadOutput = @($loadResult.Output) }
            }
        }
        else {
            $rawLoad = & reg.exe load $mountSpec.regKeyPath $hive 2>&1
            $loadExit = $LASTEXITCODE
            $loadOutput = @($rawLoad | ForEach-Object { "$_" })
        }

        if ($null -eq $loadExit -or [int]$loadExit -ne 0) {
            throw ("reg.exe load failed for owned hive '{0}' with exit code {1}: {2}" -f `
                    $mountSpec.leafName, $loadExit, ($loadOutput -join ' '))
        }
        $mountSpec.loadedByThisRun = $true

        if (-not (Test-XboxOSRegistryHiveMountPresent -LeafName $mountSpec.leafName -PresenceTester $PresenceTester)) {
            throw ("Registry hive load reported success but mount '{0}' is not present." -f $mountSpec.leafName)
        }

        $cv = $null
        if ($CurrentVersionReader) {
            $cv = & $CurrentVersionReader -LeafName $mountSpec.leafName -PsProviderPath $mountSpec.psProviderPath
        }
        else {
            $cv = Get-ItemProperty -Path ("{0}\Microsoft\Windows NT\CurrentVersion" -f $mountSpec.psProviderPath) -ErrorAction Stop
        }
        if ($null -eq $cv) {
            throw 'Mounted hive CurrentVersion query returned no data.'
        }

        $build = $null
        if ($cv.PSObject.Properties['CurrentBuild']) { $build = [string]$cv.CurrentBuild }
        if ([string]::IsNullOrWhiteSpace($build)) {
            throw 'Mounted hive CurrentBuild is missing.'
        }
        if (($cv.PSObject.Properties['UBR'] -and ($cv.UBR -or $cv.UBR -eq 0))) {
            $build = '{0}.{1}' -f $build, $cv.UBR
        }
        $display = $null
        if ($cv.PSObject.Properties['DisplayVersion']) { $display = [string]$cv.DisplayVersion }
        if ([string]::IsNullOrWhiteSpace($display)) {
            throw 'Mounted hive DisplayVersion is missing.'
        }

        $metadata = [pscustomobject]@{
            buildNumber              = $build
            displayVersion           = $display
            editionId                = $(if ($cv.PSObject.Properties['EditionID']) { [string]$cv.EditionID } else { $null })
            productName              = $(if ($cv.PSObject.Properties['ProductName']) { [string]$cv.ProductName } else { $null })
            architecture             = $null
            metadataSource           = 'mounted-software-hive'
            hiveMount                = $mountSpec
            hiveCleanupVerified      = $false
            hiveCleanupNotApplicable = $false
            loadExitCode             = [int]$loadExit
            loadOutput               = $loadOutput
        }
    }
    catch {
        $queryError = $_
    }
    finally {
        if ([bool]$mountSpec.loadedByThisRun) {
            try {
                $unload = Invoke-XboxOSOwnedRegistryHiveUnload `
                    -HiveMountSpec $mountSpec `
                    -ExpectedOwnershipToken $ownedToken `
                    -RegUnload $RegUnload `
                    -PresenceTester $PresenceTester
                if ($metadata) {
                    $metadata.hiveCleanupVerified = [bool]$unload.verified
                    $metadata | Add-Member -NotePropertyName unloadExitCode -NotePropertyValue $unload.unloadExitCode -Force
                    $metadata | Add-Member -NotePropertyName unloadOutput -NotePropertyValue $unload.unloadOutput -Force
                }
            }
            catch {
                $cleanupError = $_
                $mountSpec.unloadVerified = $false
                if ($metadata) {
                    $metadata.hiveCleanupVerified = $false
                }
            }
        }
        elseif ($metadata -and -not $mountSpec.loadedByThisRun) {
            # Load never succeeded; treat hive cleanup as verified absent.
            $metadata.hiveCleanupVerified = $true
            $mountSpec.unloadVerified = $true
        }
    }

    if ($cleanupError) {
        throw ("RecoveryRequired: registry hive cleanup failed for '{0}': {1}. Workspace evidence must be preserved; WIM cleanup must not report success while this hive may remain loaded." -f `
                $mountSpec.leafName, $cleanupError.Exception.Message)
    }
    if ($queryError) {
        throw $queryError
    }
    if ($null -eq $metadata) {
        throw 'Mounted-image hive metadata could not be collected.'
    }
    if (-not [bool]$metadata.hiveCleanupVerified) {
        throw ("RecoveryRequired: registry hive '{0}' cleanup was not independently verified." -f $mountSpec.leafName)
    }
    return $metadata
}

function Confirm-XboxOSOwnedMountCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Adapter,
        [Parameter(Mandatory)][string]$OwnedMountDir,
        [AllowEmptyCollection()][object[]]$BaselineMounts = @()
    )

    $probe = $Adapter.InvokeOperation('GetMountedImageInfo')
    $finalMounts = @(ConvertFrom-XboxOSMountedImageInfoOutput -Output @($probe.Output))
    $ownedCanonical = Get-XboxOSCanonicalPath -Path $OwnedMountDir
    $stillOwned = @(
        $finalMounts | Where-Object {
            $_.MountDir -and (
                [string]::Equals(
                    (Get-XboxOSCanonicalPath -Path $_.MountDir),
                    $ownedCanonical,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            )
        }
    )
    if ($stillOwned.Count -gt 0) {
        throw ("RecoveryRequired: owned mount still present after Unmount-Discard: {0}" -f $OwnedMountDir)
    }

    foreach ($baseline in @($BaselineMounts)) {
        if (-not $baseline -or -not $baseline.MountDir) { continue }
        $basePath = Get-XboxOSCanonicalPath -Path $baseline.MountDir
        if ([string]::Equals($basePath, $ownedCanonical, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $stillThere = @(
            $finalMounts | Where-Object {
                $_.MountDir -and (
                    [string]::Equals(
                        (Get-XboxOSCanonicalPath -Path $_.MountDir),
                        $basePath,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                )
            }
        )
        if ($stillThere.Count -lt 1) {
            throw ("RecoveryRequired: unrelated baseline mount missing after cleanup: {0}" -f $baseline.MountDir)
        }
    }

    return [pscustomobject]@{
        verified     = $true
        command      = $probe
        finalMounts  = $finalMounts
        ownedMountDir = $OwnedMountDir
    }
}

function Set-XboxOSPreflightCleanupStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Preflight,
        [Parameter(Mandatory)][ValidateSet('NotStarted', 'NotRequired', 'Succeeded', 'Recovered', 'Failed')]
        [string]$Status
    )

    # Failed is sticky — success/recovered cannot overwrite a prior cleanup failure.
    if ($Preflight.cleanupStatus -eq 'Failed' -and $Status -ne 'Failed') {
        return
    }
    if ($Status -eq 'Succeeded') {
        if (-not [bool]$Preflight.cleanupVerified) {
            return
        }
        # Registry hive must be verified absent before WIM cleanup may be marked successful.
        if ($Preflight.PSObject.Properties['registryHiveCleanupVerified'] -and
            $Preflight.PSObject.Properties['registryHiveCleanupNotApplicable'] -and
            -not [bool]$Preflight.registryHiveCleanupNotApplicable -and
            -not [bool]$Preflight.registryHiveCleanupVerified) {
            return
        }
    }
    $Preflight.cleanupStatus = $Status
}

function Assert-XboxOSInventoryCompletenessForPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Inventory,
        [object]$BaselineInventory = $null
    )

    if ($Inventory.verificationStatus -ne 'Authoritative') {
        throw ("Fresh inventory verificationStatus must be Authoritative; was '{0}'." -f $Inventory.verificationStatus)
    }
    if (-not $Inventory.sourceImage) {
        throw 'Incomplete inventory: sourceImage metadata is missing.'
    }
    if (-not [bool]$Inventory.sourceImage.PSObject.Properties['verified'] -or -not [bool]$Inventory.sourceImage.verified) {
        throw 'Incomplete inventory: sourceImage metadata was not independently verified.'
    }
    foreach ($field in @('editionName', 'buildNumber', 'displayVersion', 'isoSha256')) {
        if (-not $Inventory.sourceImage.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$Inventory.sourceImage.$field)) {
            throw ("Incomplete inventory: verified sourceImage.{0} is missing." -f $field)
        }
    }

    $packages = @($Inventory.packages)
    $appx = @($Inventory.appxPackages)
    $features = @($Inventory.features)
    $pkgCount = $packages.Count
    $appxCount = $appx.Count
    $featCount = $features.Count
    if ($pkgCount -lt 1) { throw 'Incomplete inventory: no DISM packages captured.' }
    if ($appxCount -lt 1) { throw 'Incomplete inventory: no provisioned AppX packages captured.' }
    if ($featCount -lt 1) { throw 'Incomplete inventory: no optional features captured.' }

    $pkgIds = @(
        foreach ($p in $packages) {
            $id = $null
            if ($p -is [string]) { $id = $p }
            elseif ($p.PSObject.Properties['Identity']) { $id = [string]$p.Identity }
            elseif ($p.PSObject.Properties['PackageName']) { $id = [string]$p.PackageName }
            if ([string]::IsNullOrWhiteSpace($id)) { throw 'Incomplete inventory: package entry missing identity.' }
            $id
        }
    )
    if (@($pkgIds | Group-Object | Where-Object Count -gt 1).Count -gt 0) {
        throw 'Incomplete inventory: duplicate package identities detected.'
    }

    $appxIds = @($appx | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($appxIds.Count -ne $appxCount) { throw 'Incomplete inventory: blank AppX identities detected.' }
    if (@($appxIds | Group-Object | Where-Object Count -gt 1).Count -gt 0) {
        throw 'Incomplete inventory: duplicate AppX identities detected.'
    }

    foreach ($feature in $features) {
        if (-not $feature.PSObject.Properties['Name'] -or [string]::IsNullOrWhiteSpace([string]$feature.Name)) {
            throw 'Incomplete inventory: feature entry missing Name.'
        }
        if (-not $feature.PSObject.Properties['State'] -or [string]::IsNullOrWhiteSpace([string]$feature.State)) {
            throw 'Incomplete inventory: feature entry missing State.'
        }
    }
    $featNames = @($features | ForEach-Object { [string]$_.Name })
    if (@($featNames | Group-Object | Where-Object Count -gt 1).Count -gt 0) {
        throw 'Incomplete inventory: duplicate feature names detected.'
    }

    if ($null -ne $Inventory.advertisedPackageCount -and [int]$Inventory.advertisedPackageCount -ne $pkgCount) {
        throw 'Contradictory package inventory counts.'
    }
    if ($null -ne $Inventory.advertisedAppxCount -and [int]$Inventory.advertisedAppxCount -ne $appxCount) {
        throw 'Contradictory AppX inventory counts.'
    }
    if ($null -ne $Inventory.advertisedFeatureCount -and [int]$Inventory.advertisedFeatureCount -ne $featCount) {
        throw 'Contradictory feature inventory counts.'
    }

    if ($BaselineInventory -and $BaselineInventory.verificationStatus -eq 'Authoritative') {
        $basePkg = @($BaselineInventory.packages).Count
        $baseAppx = @($BaselineInventory.appxPackages).Count
        $baseFeat = @($BaselineInventory.features).Count
        if ($basePkg -gt 0 -and $pkgCount -lt [math]::Ceiling($basePkg * 0.5)) {
            throw ("Observed package count {0} is far below Milestone 1 baseline {1}; inventory appears incomplete." -f $pkgCount, $basePkg)
        }
        if ($baseAppx -gt 0 -and $appxCount -lt [math]::Ceiling($baseAppx * 0.5)) {
            throw ("Observed AppX count {0} is far below Milestone 1 baseline {1}; inventory appears incomplete." -f $appxCount, $baseAppx)
        }
        if ($baseFeat -gt 0 -and $featCount -lt [math]::Ceiling($baseFeat * 0.5)) {
            throw ("Observed feature count {0} is far below Milestone 1 baseline {1}; inventory appears incomplete." -f $featCount, $baseFeat)
        }
    }
}

function Resolve-XboxOSReadOnlyDismArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ $script:XboxOSReadOnlyDismOperations.Keys -contains $_ })]
        [string]$Operation,

        [hashtable]$Parameters = @{}
    )

    $spec = $script:XboxOSReadOnlyDismOperations[$Operation]
    $argumentList = foreach ($part in @($spec.Template)) {
        $resolved = [string]$part
        foreach ($key in @($Parameters.Keys)) {
            $token = '{' + [string]$key + '}'
            $resolved = $resolved.Replace($token, [string]$Parameters[$key])
        }
        if ($resolved -match '\{[A-Za-z]+\}') {
            throw "Unresolved DISM template parameter in operation '${Operation}': ${resolved}"
        }
        $resolved
    }

    $scan = Test-XboxOSDismArgumentListAllowed -ArgumentList @($argumentList)
    if (-not $scan.Allowed) {
        throw ("Allowlist build produced prohibited arguments for '{0}': {1}" -f $Operation, $scan.Reason)
    }

    return [pscustomobject]@{
        Operation   = $Operation
        Class       = [string]$spec.Class
        ArgumentList = @($argumentList)
        AdapterVersion = Get-XboxOSReadOnlyDismAdapterVersion
    }
}

function Assert-XboxOSReadOnlyDismOperationAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Operation,
        [hashtable]$Parameters = @{}
    )

    if ($script:XboxOSReadOnlyDismOperations.Keys -notcontains $Operation) {
        throw ("DISM operation '{0}' is not in the readonly-dism-v1 allowlist." -f $Operation)
    }
    $built = Resolve-XboxOSReadOnlyDismArguments -Operation $Operation -Parameters $Parameters
    return $built
}

function New-XboxOSMockReadOnlyDismAdapter {
    [CmdletBinding()]
    param(
        [ValidateSet('Success', 'ExportInterrupted', 'MountFailed', 'UnmountFailed', 'CorruptWim', 'VersionProbeFailed')]
        [string]$FailureMode = 'Success',

        [string]$FixtureRoot = ''
    )

    if (-not $FixtureRoot) {
        $FixtureRoot = Join-Path (Get-XboxOSRepoRoot) 'tests\Fixtures'
    }

    $ctx = [pscustomobject]@{
        Kind                     = 'mock-readonly-dism'
        FailureMode              = $FailureMode
        FixtureRoot              = $FixtureRoot
        Commands                 = [System.Collections.ArrayList]@()
        MountOwned               = $false
        MountDir                 = $null
        SourceIsoModified        = $false
        ModifyingCommandsInvoked = $false
        RealDismExecutionEnabled = $false
    }

    $adapter = New-Object psobject
    Add-Member -InputObject $adapter -NotePropertyName Ctx -NotePropertyValue $ctx
    Add-Member -InputObject $adapter -MemberType ScriptMethod -Name InvokeOperation -Value {
        param(
            [string]$Operation,
            $Parameters = $null
        )
        if ($null -eq $Parameters) { $Parameters = @{} }
        elseif ($Parameters -isnot [hashtable]) { $Parameters = [hashtable]$Parameters }
        $built = Assert-XboxOSReadOnlyDismOperationAllowed -Operation $Operation -Parameters $Parameters
        $null = $this.Ctx.Commands.Add([pscustomobject]@{
                utc        = [datetime]::UtcNow
                operation  = $Operation
                class      = $built.Class
                arguments  = $built.ArgumentList
                exitCode   = 0
            })

        if ($this.Ctx.FailureMode -eq 'VersionProbeFailed' -and $Operation -eq 'GetDismVersion') {
            throw 'Simulated DISM version probe failure'
        }
        if ($this.Ctx.FailureMode -eq 'ExportInterrupted' -and $Operation -eq 'ExportImage') {
            throw 'Simulated disposable WIM export interrupted'
        }
        if ($this.Ctx.FailureMode -eq 'MountFailed' -and $Operation -eq 'MountImageReadOnly') {
            throw 'Simulated read-only mount failure'
        }
        if ($this.Ctx.FailureMode -eq 'CorruptWim' -and $Operation -eq 'GetExportedImageInfo') {
            throw 'Simulated corrupt disposable WIM'
        }
        if ($this.Ctx.FailureMode -eq 'UnmountFailed' -and $Operation -eq 'UnmountDiscard') {
            throw 'Simulated unmount discard failure'
        }

        $output = @('Mock DISM OK', "Operation=$Operation")
        switch ($Operation) {
            'GetDismVersion' {
                $output = @('Deployment Image Servicing and Management tool', 'Version: 10.0.26100.1')
            }
            'GetImageInfo' {
                $output = @(
                    'Index : 1',
                    'Name : Windows 11 Home',
                    'Architecture : x64',
                    'Index : 6',
                    'Name : Windows 11 Pro',
                    'Description : Windows 11 Pro',
                    'Architecture : x64',
                    "Version : 10.0.$($script:XboxOSExpectedBuildNumber)"
                )
            }
            'GetExportedImageInfo' {
                $output = @(
                    'Index : 1',
                    'Name : Windows 11 Pro',
                    'Architecture : x64',
                    "Version : 10.0.$($script:XboxOSExpectedBuildNumber)"
                )
            }
            'MountImageReadOnly' {
                $this.Ctx.MountOwned = $true
                $this.Ctx.MountDir = [string]$Parameters.MountDir
                $output = @('Mounting image', 'The operation completed successfully.')
            }
            'GetPackages' {
                $path = Join-Path $this.Ctx.FixtureRoot 'dism-get-packages-26300.9457.txt'
                if (Test-Path -LiteralPath $path) { $output = @(Get-Content -LiteralPath $path) }
            }
            'GetProvisionedAppxPackages' {
                $path = Join-Path $this.Ctx.FixtureRoot 'dism-get-appx-26300.9457.txt'
                if (Test-Path -LiteralPath $path) { $output = @(Get-Content -LiteralPath $path) }
            }
            'GetFeatures' {
                $path = Join-Path $this.Ctx.FixtureRoot 'dism-get-features-26300.9457.txt'
                if (Test-Path -LiteralPath $path) { $output = @(Get-Content -LiteralPath $path) }
            }
            'GetMountedImageInfo' {
                if ($this.Ctx.MountOwned) {
                    $output = @("Mount Dir : $($this.Ctx.MountDir)", 'Status : Ok', 'Read Only : Yes')
                }
                else {
                    $output = @('No mounted images found.')
                }
            }
            'UnmountDiscard' {
                $this.Ctx.MountOwned = $false
                $this.Ctx.MountDir = $null
                $output = @('Unmounting image', 'The operation completed successfully.')
            }
            'ExportImage' {
                $dest = [string]$Parameters.DestinationImageFile
                if ($dest) {
                    New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force -ErrorAction SilentlyContinue | Out-Null
                    Set-Content -LiteralPath $dest -Value 'MOCK-DISPOSABLE-WIM' -Encoding ascii
                }
                $output = @('Exporting image', 'The operation completed successfully.')
            }
        }

        $this.Ctx.ModifyingCommandsInvoked = $false
        $this.Ctx.RealDismExecutionEnabled = $false
        $this.Ctx.SourceIsoModified = $false
        return [pscustomobject]@{
            ExitCode                 = 0
            Output                   = $output
            Operation                = $Operation
            Class                    = $built.Class
            ArgumentList             = $built.ArgumentList
            ModifyingCommandsInvoked = $false
            RealDismExecutionEnabled = $false
        }
    }
    return $adapter
}

function Test-XboxOSSourceImagePrerequisites {
    [CmdletBinding()]
    param(
        [string]$IsoPath = 'C:\XboxOS\Sources\Windows11_Client_x64_en-us_26300_9457.iso',
        [string]$ExpectedSha256 = '',
        [string]$WorkRoot = 'C:\XboxOS\Work',
        [string]$LogsRoot = 'C:\XboxOS\Logs',
        [long]$MinimumFreeBytes = 20GB,
        [switch]$RequireAdministrator,
        [switch]$RequireIsoPresent,
        [object[]]$ExistingMounts = @(),
        [scriptblock]$HashProvider = $null
    )

    if (-not $ExpectedSha256) { $ExpectedSha256 = Get-XboxOSExpectedSourceIsoSha256 }
    $errors = New-Object System.Collections.Generic.List[string]
    $repoRoot = Get-XboxOSRepoRoot

    try { $null = Assert-XboxOSServicingPathSafety -Path $WorkRoot -RepoRoot $repoRoot -Purpose 'disposable work root' }
    catch { $errors.Add([string]$_.Exception.Message) | Out-Null }
    try { $null = Assert-XboxOSServicingPathSafety -Path $LogsRoot -RepoRoot $repoRoot -Purpose 'preflight logs' }
    catch { $errors.Add([string]$_.Exception.Message) | Out-Null }

    if ($WorkRoot -match '(?i)OneDrive' -or $LogsRoot -match '(?i)OneDrive') {
        $errors.Add('Work/Logs paths must not be under OneDrive.') | Out-Null
    }
    if ($IsoPath -match '(?i)OneDrive') {
        $errors.Add('Source ISO path must not be under OneDrive.') | Out-Null
    }
    if (Test-XboxOSPathContainsTraversal -Path $IsoPath) {
        $errors.Add("Source ISO path contains traversal segments: $IsoPath") | Out-Null
    }

    if ($RequireAdministrator -and -not (Test-XboxOSAdministrator)) {
        $errors.Add('Administrator elevation is required for live read-only preflight.') | Out-Null
    }

    $isoPresent = Test-Path -LiteralPath $IsoPath
    $actualSha = $null
    if ($RequireIsoPresent -and -not $isoPresent) {
        $errors.Add("Source ISO not found: $IsoPath") | Out-Null
    }
    elseif ($isoPresent -and $RequireIsoPresent) {
        $actualSha = Get-XboxOSSourceIsoSha256ForPreflight -IsoPath $IsoPath -HashProvider $HashProvider
        if (-not [string]::Equals($actualSha, [string]$ExpectedSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            $errors.Add("Source ISO SHA256 mismatch. expected=${ExpectedSha256} actual=${actualSha}") | Out-Null
        }
    }

    $drive = [System.IO.Path]::GetPathRoot($WorkRoot)
    if ($drive -and (Test-Path -LiteralPath $drive)) {
        $free = (Get-PSDrive -Name $drive.TrimEnd('\').TrimEnd(':')).Free
        if ($null -ne $free -and [long]$free -lt $MinimumFreeBytes) {
            $errors.Add(("Insufficient free space on {0}: {1} bytes < {2}" -f $drive, $free, $MinimumFreeBytes)) | Out-Null
        }
    }

    $unrelated = @($ExistingMounts | Where-Object { $_ -and $_.MountDir -and $_.MountDir -notlike ($WorkRoot.TrimEnd('\') + '\*') })
    if ($unrelated.Count -gt 0) {
        $errors.Add(('Existing unrelated DISM mounts detected: {0}' -f (($unrelated | ForEach-Object { $_.MountDir }) -join '; '))) | Out-Null
    }

    return [pscustomobject]@{
        imageIntegritySchemaVersion = $script:XboxOSImageIntegritySchemaVersion
        valid                       = ($errors.Count -eq 0)
        errors                      = $errors.ToArray()
        isoPath                     = $IsoPath
        isoPresent                  = $isoPresent
        expectedSha256              = $ExpectedSha256
        actualSha256                = $actualSha
        workRoot                    = $WorkRoot
        logsRoot                    = $LogsRoot
        failClosed                  = ($errors.Count -gt 0)
    }
}

function New-XboxOSDisposableWorkspace {
    [CmdletBinding()]
    param(
        [string]$WorkRoot = 'C:\XboxOS\Work',
        [string]$OwnerId = ''
    )

    $repoRoot = Get-XboxOSRepoRoot
    $null = Assert-XboxOSServicingPathSafety -Path $WorkRoot -RepoRoot $repoRoot -Purpose 'disposable workspace'
    if (-not $OwnerId) { $OwnerId = 'owner-{0}' -f [guid]::NewGuid().ToString('N') }

    $stamp = [datetime]::UtcNow.ToString('yyyyMMddHHmmssfff')
    $workspacePath = Join-Path $WorkRoot ("preflight-{0}" -f $stamp)
    $mountDir = Join-Path $workspacePath 'mount'
    $wimPath = Join-Path $workspacePath 'install-pro-disposable.wim'

    return [pscustomobject]@{
        workspaceSchemaVersion = $script:XboxOSDisposableWorkspaceSchemaVersion
        ownerId                = $OwnerId
        workRoot               = $WorkRoot
        workspacePath          = $workspacePath
        mountDir               = $mountDir
        disposableWimPath      = $wimPath
        createdUtc             = [datetime]::UtcNow
        ownershipToken         = Get-XboxOSUtf8Sha256Hex -Text ("{0}|{1}|{2}" -f $OwnerId, $workspacePath, $wimPath)
        sourceIsoProtected     = $true
    }
}

function Test-XboxOSPathContainsTraversal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return [bool]($Path -match '(^|[\\/])\.\.([\\/]|$)')
}

function Test-XboxOSPathIsReparsePoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    $item = Get-Item -LiteralPath $Path -Force
    return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function Assert-XboxOSPathOwnedAndSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CandidatePath,
        [Parameter(Mandatory)][string]$WorkspaceRoot
    )

    if (Test-XboxOSPathContainsTraversal -Path $CandidatePath) {
        throw "Refusing path with traversal segments: $CandidatePath"
    }
    $full = Get-XboxOSCanonicalPath -Path $CandidatePath
    $root = Get-XboxOSCanonicalPath -Path $WorkspaceRoot
    if (-not (Test-XboxOSPathEqualsOrUnder -Path $full -ParentPath $root)) {
        throw "Refusing path outside owned workspace. path=$full workspace=$root"
    }
    if (Test-XboxOSPathIsReparsePoint -Path $full) {
        throw "Refusing reparse point (symlink/junction) path: $full"
    }
    # Walk parents within workspace for reparse redirection.
    $cursor = $full
    while ($cursor -and (Test-XboxOSPathEqualsOrUnder -Path $cursor -ParentPath $root)) {
        if (($cursor -ne $root) -and (Test-Path -LiteralPath $cursor) -and (Test-XboxOSPathIsReparsePoint -Path $cursor)) {
            throw "Refusing reparse point in owned path chain: $cursor"
        }
        $parent = Split-Path -Parent $cursor
        if (-not $parent -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Assert-XboxOSDisposableWorkspaceOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Workspace,
        [Parameter(Mandatory)][string]$OwnershipToken,
        [string]$CandidateMountDir = ''
    )

    $expected = Get-XboxOSUtf8Sha256Hex -Text ("{0}|{1}|{2}" -f $Workspace.ownerId, $Workspace.workspacePath, $Workspace.disposableWimPath)
    if ($OwnershipToken -ne $expected -or $OwnershipToken -ne $Workspace.ownershipToken) {
        throw 'Disposable workspace ownership token mismatch.'
    }
    if ($CandidateMountDir) {
        Assert-XboxOSPathOwnedAndSafe -CandidatePath $CandidateMountDir -WorkspaceRoot $Workspace.workspacePath
    }
}

function ConvertFrom-XboxOSMountedImageInfoOutput {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Output = @()
    )

    # Avoid [string[]] binding coercing a single string into a char[].
    $lines = New-Object System.Collections.ArrayList
    if ($Output -is [string]) {
        foreach ($part in @($Output -split '\r?\n')) { $null = $lines.Add([string]$part) }
    }
    else {
        foreach ($item in @($Output)) {
            if ($null -eq $item) { continue }
            $null = $lines.Add([string]$item)
        }
    }

    $mounts = New-Object System.Collections.ArrayList
    $current = $null
    foreach ($text in @($lines)) {
        if ($text -match '^\s*Mount Dir\s*:\s*(.+?)\s*$') {
            if ($null -ne $current) {
                $null = $mounts.Add([pscustomobject]@{
                        MountDir  = [string]$current.MountDir
                        Status    = $current.Status
                        ReadOnly  = $current.ReadOnly
                        ImageFile = $current.ImageFile
                    })
            }
            $current = [pscustomobject]@{
                MountDir  = $Matches[1].Trim()
                Status    = $null
                ReadOnly  = $null
                ImageFile = $null
            }
        }
        elseif ($null -ne $current -and $text -match '^\s*Status\s*:\s*(.+?)\s*$') {
            $current.Status = $Matches[1].Trim()
        }
        elseif ($null -ne $current -and $text -match '^\s*Read Only\s*:\s*(.+?)\s*$') {
            $current.ReadOnly = $Matches[1].Trim()
        }
        elseif ($null -ne $current -and $text -match '^\s*Image File\s*:\s*(.+?)\s*$') {
            $current.ImageFile = $Matches[1].Trim()
        }
    }
    if ($null -ne $current) {
        $null = $mounts.Add($current)
    }
    return @($mounts.ToArray())
}

function Invoke-XboxOSNativeDismCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DismPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgumentList,
        [scriptblock]$Runner = $null
    )

    if ([string]::IsNullOrWhiteSpace($DismPath)) {
        throw 'DismPath is required for native DISM invocation.'
    }
    $scan = Test-XboxOSDismArgumentListAllowed -ArgumentList @($ArgumentList)
    if (-not $scan.Allowed) {
        throw ("Native DISM invocation rejected: {0}" -f $scan.Reason)
    }

    $display = "$DismPath $($ArgumentList -join ' ')"
    if ($Runner) {
        $result = & $Runner -DismPath $DismPath -ArgumentList @($ArgumentList)
        $exitCode = 0
        $output = @()
        if ($result -is [hashtable] -or $result -is [System.Collections.IDictionary]) {
            if ($result.ContainsKey('ExitCode')) { $exitCode = [int]$result.ExitCode }
            if ($result.ContainsKey('Output')) { $output = @($result.Output) }
        }
        else {
            if ($result.PSObject.Properties['ExitCode']) { $exitCode = [int]$result.ExitCode }
            if ($result.PSObject.Properties['Output']) { $output = @($result.Output) }
        }
        if ($exitCode -ne 0) {
            throw ("Injected DISM runner failed with exit code {0}. Command: {1}" -f $exitCode, $display)
        }
        return [pscustomobject]@{
            ExitCode     = $exitCode
            Output       = @($output)
            Command      = $display
            InvokedNative = $true
            UsedRunner   = $true
        }
    }

    if (-not (Test-Path -LiteralPath $DismPath)) {
        throw "DISM executable not found: $DismPath"
    }
    $output = & $DismPath @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE
    $text = @($output | ForEach-Object { "$_" })
    if ($null -eq $exitCode) {
        throw "DISM did not return an exit code. Command: $display"
    }
    if ([int]$exitCode -ne 0) {
        throw ("DISM failed with exit code {0}. Command: {1}`n{2}" -f $exitCode, $display, ($text -join "`n"))
    }
    return [pscustomobject]@{
        ExitCode      = [int]$exitCode
        Output        = $text
        Command       = $display
        InvokedNative = $true
        UsedRunner    = $false
    }
}

function New-XboxOSRecordingDismRunner {
    [CmdletBinding()]
    param(
        [hashtable]$Responses = @{},
        [string]$FixtureRoot = '',
        [switch]$AutoFixtureResponses
    )

    if (-not $FixtureRoot) {
        $FixtureRoot = Join-Path (Get-XboxOSRepoRoot) 'tests\Fixtures'
    }

    $state = [hashtable]@{
        Calls       = [System.Collections.ArrayList]@()
        Responses   = $Responses
        FixtureRoot = $FixtureRoot
        MountDir    = $null
        MountOwned  = $false
        AutoFixture = [bool]$AutoFixtureResponses
    }

    $runner = {
        param(
            [string]$DismPath,
            [string[]]$ArgumentList
        )
        $null = $state.Calls.Add([pscustomobject]@{
                DismPath     = $DismPath
                ArgumentList = @($ArgumentList)
            })
        $key = ($ArgumentList -join ' ')
        foreach ($pattern in @($state.Responses.Keys)) {
            if ($key -like $pattern -or $key -eq $pattern) {
                return $state.Responses[$pattern]
            }
        }

        if ($state.AutoFixture) {
            if ($key -match '/Export-Image' -and $key -match '/DestinationImageFile:(?<dest>[^\s]+)') {
                $dest = $Matches['dest']
                New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force -ErrorAction SilentlyContinue | Out-Null
                Set-Content -LiteralPath $dest -Value 'MOCK-DISPOSABLE-WIM' -Encoding ascii
                return @{ ExitCode = 0; Output = @('Exporting image', 'The operation completed successfully.') }
            }
            if ($key -match '/Mount-Image' -and $key -match '/MountDir:(?<md>[^\s]+)') {
                $state.MountDir = $Matches['md']
                $state.MountOwned = $true
                return @{ ExitCode = 0; Output = @('Mounting image', 'The operation completed successfully.') }
            }
            if ($key -match '/Unmount-Image') {
                $state.MountOwned = $false
                $state.MountDir = $null
                return @{ ExitCode = 0; Output = @('Unmounting image', 'The operation completed successfully.') }
            }
            if ($key -match '/Get-MountedImageInfo') {
                if ($state.MountOwned -and $state.MountDir) {
                    return @{
                        ExitCode = 0
                        Output   = @(
                            "Mount Dir : $($state.MountDir)"
                            'Status : Ok'
                            'Read Only : Yes'
                            "Image File : disposable.wim"
                        )
                    }
                }
                return @{ ExitCode = 0; Output = @('No mounted images found.') }
            }
            if ($key -match '/\?' -or $key -eq '/English /?') {
                return @{ ExitCode = 0; Output = @('Deployment Image Servicing and Management tool', 'Version: 10.0.26100.1') }
            }
            if ($key -match '/Get-ImageInfo') {
                if ($key -match 'install-pro-disposable\.wim') {
                    return @{
                        ExitCode = 0
                        Output   = @(
                            'Index : 1'
                            'Name : Windows 11 Pro'
                            'Architecture : x64'
                            "Version : 10.0.$($script:XboxOSExpectedBuildNumber)"
                        )
                    }
                }
                return @{
                    ExitCode = 0
                    Output   = @(
                        'Index : 1'
                        'Name : Windows 11 Home'
                        'Architecture : x64'
                        'Index : 6'
                        'Name : Windows 11 Pro'
                        'Description : Windows 11 Pro'
                        'Architecture : x64'
                        "Version : 10.0.$($script:XboxOSExpectedBuildNumber)"
                    )
                }
            }
            if ($key -match '/Get-Packages') {
                $path = Join-Path $state.FixtureRoot 'dism-get-packages-26300.9457.txt'
                return @{ ExitCode = 0; Output = @(Get-Content -LiteralPath $path) }
            }
            if ($key -match '/Get-ProvisionedAppxPackages') {
                $path = Join-Path $state.FixtureRoot 'dism-get-appx-26300.9457.txt'
                return @{ ExitCode = 0; Output = @(Get-Content -LiteralPath $path) }
            }
            if ($key -match '/Get-Features') {
                $path = Join-Path $state.FixtureRoot 'dism-get-features-26300.9457.txt'
                return @{ ExitCode = 0; Output = @(Get-Content -LiteralPath $path) }
            }
        }

        return @{
            ExitCode = 0
            Output   = @('Recording runner default OK', "Args=$key")
        }
    }.GetNewClosure()

    return [pscustomobject]@{
        Runner = $runner
        State  = $state
        Calls  = $state.Calls
    }
}

function New-XboxOSRealReadOnlyDismAdapter {
    [CmdletBinding()]
    param(
        [string]$DismPath = '',
        [scriptblock]$NativeRunner = $null
    )

    if (-not $DismPath) {
        $DismPath = Find-XboxOSDism
    }
    if (-not $DismPath -and -not $NativeRunner) {
        throw 'DISM was not found and no NativeRunner was supplied.'
    }
    if (-not $DismPath) {
        $DismPath = 'C:\Windows\System32\dism.exe'
    }

    $ctx = [pscustomobject]@{
        Kind                              = 'real-readonly-dism'
        DismPath                          = $DismPath
        NativeRunner                      = $NativeRunner
        Commands                          = [System.Collections.ArrayList]@()
        MountOwned                        = $false
        MountDir                          = $null
        SourceIsoModified                 = $false
        ModifyingCommandsInvoked          = $false
        RealDismExecutionEnabled          = $false
        RealReadOnlyInspectionOccurred    = $false
        DisposableExportOccurred          = $false
        ReadOnlyMountOccurred             = $false
        ReadOnlyMountAttempted            = $false
        DisposableExportAttempted         = $false
    }

    $adapter = New-Object psobject
    Add-Member -InputObject $adapter -NotePropertyName Ctx -NotePropertyValue $ctx
    Add-Member -InputObject $adapter -MemberType ScriptMethod -Name InvokeOperation -Value {
        param(
            [string]$Operation,
            $Parameters = $null
        )
        if ($null -eq $Parameters) { $Parameters = @{} }
        elseif ($Parameters -isnot [hashtable]) { $Parameters = [hashtable]$Parameters }
        $built = Assert-XboxOSReadOnlyDismOperationAllowed -Operation $Operation -Parameters $Parameters
        if ($Operation -eq 'ExportImage') { $this.Ctx.DisposableExportAttempted = $true }
        if ($Operation -eq 'MountImageReadOnly') {
            $this.Ctx.ReadOnlyMountAttempted = $true
            # Ownership assumed for cleanup as soon as mount is attempted with allowlisted args.
            $this.Ctx.MountOwned = $true
            $this.Ctx.MountDir = [string]$Parameters.MountDir
        }

        try {
            $native = Invoke-XboxOSNativeDismCommand `
                -DismPath $this.Ctx.DismPath `
                -ArgumentList @($built.ArgumentList) `
                -Runner $this.Ctx.NativeRunner
        }
        catch {
            $exitCode = -1
            if ($_.Exception.Message -match 'exit code\s+(\d+)') {
                $exitCode = [int]$Matches[1]
            }
            $null = $this.Ctx.Commands.Add([pscustomobject]@{
                    utc        = [datetime]::UtcNow
                    operation  = $Operation
                    class      = $built.Class
                    arguments  = $built.ArgumentList
                    exitCode   = $exitCode
                    command    = "$($this.Ctx.DismPath) $($built.ArgumentList -join ' ')"
                    failed     = $true
                })
            throw
        }

        $null = $this.Ctx.Commands.Add([pscustomobject]@{
                utc        = [datetime]::UtcNow
                operation  = $Operation
                class      = $built.Class
                arguments  = $built.ArgumentList
                exitCode   = $native.ExitCode
                command    = $native.Command
                failed     = $false
            })

        if ([int]$native.ExitCode -ne 0) {
            throw ("Allowlisted DISM operation '{0}' returned nonzero exit code {1}." -f $Operation, $native.ExitCode)
        }

        switch ($Operation) {
            'ExportImage' { $this.Ctx.DisposableExportOccurred = $true }
            'MountImageReadOnly' {
                # Confirmed occurrence is set by the lifecycle after Get-MountedImageInfo.
                $this.Ctx.MountOwned = $true
                $this.Ctx.MountDir = [string]$Parameters.MountDir
            }
            'UnmountDiscard' {
                $this.Ctx.MountOwned = $false
                $this.Ctx.MountDir = $null
            }
            default {
                if ($built.Class -eq 'PureInspection') {
                    $this.Ctx.RealReadOnlyInspectionOccurred = $true
                }
            }
        }

        $this.Ctx.ModifyingCommandsInvoked = $false
        $this.Ctx.RealDismExecutionEnabled = $false
        $this.Ctx.SourceIsoModified = $false

        return [pscustomobject]@{
            ExitCode                       = [int]$native.ExitCode
            Output                         = @($native.Output)
            Operation                      = $Operation
            Class                          = $built.Class
            ArgumentList                   = $built.ArgumentList
            Command                        = $native.Command
            ModifyingCommandsInvoked       = $false
            RealDismExecutionEnabled       = $false
            RealReadOnlyInspectionOccurred = [bool]$this.Ctx.RealReadOnlyInspectionOccurred
            DisposableExportOccurred       = [bool]$this.Ctx.DisposableExportOccurred
            ReadOnlyMountOccurred          = [bool]$this.Ctx.ReadOnlyMountOccurred
            ReadOnlyMountAttempted         = [bool]$this.Ctx.ReadOnlyMountAttempted
        }
    }
    return $adapter
}

function Mount-XboxOSSourceIsoForReadOnlyPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [scriptblock]$MountRunner = $null
    )

    if ($MountRunner) {
        return & $MountRunner -IsoPath $IsoPath
    }

    $diskImage = Mount-DiskImage -ImagePath $IsoPath -StorageType ISO -PassThru
    $isoDrive = ($diskImage | Get-Volume).DriveLetter
    if (-not $isoDrive) {
        throw 'ISO mounted but no drive letter was assigned.'
    }
    $isoRoot = "${isoDrive}:\"
    $sourceWim = Join-Path $isoRoot 'sources\install.wim'
    $sourceEsd = Join-Path $isoRoot 'sources\install.esd'
    $sourceImage = $null
    if (Test-Path -LiteralPath $sourceWim) { $sourceImage = $sourceWim }
    elseif (Test-Path -LiteralPath $sourceEsd) { $sourceImage = $sourceEsd }
    else { throw 'Neither install.wim nor install.esd found on ISO.' }

    return [pscustomobject]@{
        IsoPath         = $IsoPath
        DriveLetter     = [string]$isoDrive
        IsoRoot         = $isoRoot
        SourceImageFile = $sourceImage
        DiskImage       = $diskImage
    }
}

function Dismount-XboxOSSourceIsoForReadOnlyPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [scriptblock]$DismountRunner = $null
    )

    if ($DismountRunner) {
        $null = & $DismountRunner -IsoPath $IsoPath
        return
    }
    Dismount-DiskImage -ImagePath $IsoPath | Out-Null
}

function Get-XboxOSDependencyCategoryEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Inventory,
        [Parameter(Mandatory)][object]$CompatibilityManifest
    )

    $protected = @(Get-XboxOSProtectedAppxPatterns -CompatibilityManifest $CompatibilityManifest)
    $appx = @($Inventory.appxPackages | ForEach-Object { [string]$_ })

    $categories = @(
        [ordered]@{ id = 'XboxInfrastructure'; patterns = @('*Xbox*', '*GamingApp*'); required = $true }
        [ordered]@{ id = 'GamingServices'; patterns = @('*GamingServices*', '*XboxGameCallableUI*'); required = $true }
        [ordered]@{ id = 'MicrosoftStore'; patterns = @('*WindowsStore*', '*StorePurchaseApp*', '*SecHealthUI*'); required = $true }
        [ordered]@{ id = 'XboxIdentity'; patterns = @('*XboxIdentityProvider*', '*Xbox.TCUI*'); required = $true }
        [ordered]@{ id = 'GameBar'; patterns = @('*XboxGameOverlay*', '*GameBar*'); required = $true }
        [ordered]@{ id = 'Servicing'; patterns = @(); featureHints = @('NetFx3*', 'Microsoft-Windows-Subsystem-Linux'); required = $true }
        [ordered]@{ id = 'GraphicsAudio'; patterns = @(); featureHints = @(); required = $false }
        [ordered]@{ id = 'MediaPlayback'; patterns = @('*ZuneMusic*', '*ZuneVideo*', '*YourPhone*'); required = $false }
        [ordered]@{ id = 'ControllerSupport'; patterns = @('*XboxSpeechToTextOverlay*', '*Xbox.TCUI*'); required = $false }
        [ordered]@{ id = 'NetworkingSecurity'; patterns = @('*SecHealthUI*'); featureHints = @('SMB1Protocol*'); required = $true }
    )

    $rows = foreach ($cat in $categories) {
        $hits = @()
        foreach ($pattern in @($cat.patterns)) {
            $hits += @($appx | Where-Object { $_ -like $pattern })
        }
        $protectedHits = @($hits | Where-Object { Test-XboxOSPackageProtected -PackageName $_ -ProtectedPatterns $protected })
        $outcome = if ($hits.Count -eq 0 -and $cat.required) {
            'MissingEvidence'
        }
        elseif ($hits.Count -eq 0) {
            'Unknown'
        }
        elseif ($protectedHits.Count -gt 0 -or $cat.required) {
            'Verified'
        }
        else {
            'Unknown'
        }

        [pscustomobject]@{
            category     = [string]$cat.id
            outcome      = $outcome
            evidenceCount = $hits.Count
            protectedHits = $protectedHits.Count
            provenance   = 'inventory+compatibility.protectedAppxPatterns'
            samples      = @($hits | Select-Object -First 3)
            note         = 'Absence from protected patterns alone never proves removal safety.'
        }
    }

    $aggregate = if (@($rows | Where-Object outcome -eq 'MissingEvidence').Count -gt 0) {
        'MissingEvidence'
    }
    elseif (@($rows | Where-Object outcome -eq 'Unknown').Count -gt 0) {
        'Unknown'
    }
    else {
        'Verified'
    }

    return [pscustomobject]@{
        dependencySchemaVersion = 'dependency-v1'
        aggregateOutcome        = $aggregate
        failClosed              = ($aggregate -ne 'Verified')
        approvalCannotOverride  = $true
        categories              = @($rows)
        realDismExecutionEnabled = $false
    }
}

function New-XboxOSApprovalSigningPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ApprovalBindingDocument,
        [Parameter(Mandatory)][string]$Nonce
    )

    $doc = [ordered]@{
        approvalAuthSchemaVersion = $script:XboxOSApprovalAuthSchemaVersion
        nonce                     = $Nonce
        binding                   = $ApprovalBindingDocument
    }
    return ConvertTo-XboxOSCanonicalJson -Value $doc
}

function New-XboxOSApprovalSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CanonicalPayload,
        [Parameter(Mandatory)][string]$PrivateKeyPemPath
    )

    if (-not (Test-Path -LiteralPath $PrivateKeyPemPath)) {
        throw "Private key PEM not found: $PrivateKeyPemPath"
    }
    $pem = Get-Content -LiteralPath $PrivateKeyPemPath -Raw
    $rsa = [System.Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportFromPem($pem)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($CanonicalPayload)
        $sig = $rsa.SignData($bytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        return [Convert]::ToBase64String($sig)
    }
    finally {
        $rsa.Dispose()
    }
}

function Test-XboxOSApprovalSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CanonicalPayload,
        [Parameter(Mandatory)][string]$SignatureBase64,
        [Parameter(Mandatory)][string]$PublicKeyPemPath
    )

    if (-not (Test-Path -LiteralPath $PublicKeyPemPath)) {
        throw "Public key PEM not found: $PublicKeyPemPath"
    }
    $pem = Get-Content -LiteralPath $PublicKeyPemPath -Raw
    $rsa = [System.Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportFromPem($pem)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($CanonicalPayload)
        $sig = [Convert]::FromBase64String($SignatureBase64)
        $ok = $rsa.VerifyData($bytes, $sig, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        return [pscustomobject]@{
            approvalAuthSchemaVersion = $script:XboxOSApprovalAuthSchemaVersion
            signatureValid            = [bool]$ok
            grantsRealDismExecution   = $false
            realDismExecutionEnabled  = $false
            executionAuthorized       = $false
            note                      = 'Signature validity never authorizes real DISM mutation.'
        }
    }
    finally {
        $rsa.Dispose()
    }
}

function New-XboxOSDisposableImagePreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object]$CompatibilityManifest,
        [object]$BaselineInventory = $null,
        [object]$Adapter = $null,
        [ValidateSet('Simulation', 'LiveReadOnly')]
        [string]$Mode = 'Simulation',
        [string]$IsoPath = 'C:\XboxOS\Sources\Windows11_Client_x64_en-us_26300_9457.iso',
        [string]$WorkRoot = 'C:\XboxOS\Work',
        [string]$LogsRoot = 'C:\XboxOS\Logs'
    )

    if (-not $Adapter) {
        $Adapter = New-XboxOSMockReadOnlyDismAdapter
    }

    return [pscustomobject]@{
        preflightId                = ('preflight-{0}' -f [datetime]::UtcNow.ToString('yyyyMMddHHmmssfff'))
        preflightEngineVersion     = Get-XboxOSPreflightEngineVersion
        mode                       = $Mode
        plan                       = $Plan
        baselineInventory          = $BaselineInventory
        compatibilityManifest      = $CompatibilityManifest
        adapter                    = $Adapter
        isoPath                    = $IsoPath
        workRoot                   = $WorkRoot
        logsRoot                   = $LogsRoot
        workspace                  = $null
        prerequisites              = $null
        sourceImage                = $null
        freshInventory             = $null
        driftResult                = $null
        dependencyResult           = $null
        operationDependencyResult  = $null
        recomputedPlan             = $null
        preflightDecision          = 'NotEvaluated'
        transactionState           = 'Created'
        audit                      = [System.Collections.ArrayList]@()
        blockers                   = [System.Collections.ArrayList]@()
        commands                   = [System.Collections.ArrayList]@()
        mountOwned                      = $false
        cleanupStatus                   = 'NotStarted'
        modifyingCommandsInvoked        = $false
        realDismExecutionEnabled        = $false
        executionAuthorized             = $false
        sourceIsoProtected              = $true
        liveReadOnlyAuthorized          = $false
        realReadOnlyInspectionOccurred  = $false
        disposableExportOccurred        = $false
        readOnlyMountOccurred           = $false
        readOnlyMountAttempted          = $false
        disposableExportAttempted       = $false
        disposableWimSha256             = $null
        postIsoSha256                   = $null
        postIsoIntegrityVerified        = $false
        sourceImageFileFromIso          = $null
        expectedSourceImage             = $null
        inventoryMetadataVerified         = $false
        cleanupVerified                   = $false
        registryHiveMount                 = $null
        registryHiveCleanupVerified       = $false
        registryHiveCleanupNotApplicable  = $false
        finalMountInventory               = @()
        baselineMountInventory            = @()
    }
}

function Invoke-XboxOSDisposableImagePreflightSimulate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Preflight,
        [switch]$SkipWorkspaceFiles
    )

    if ($Preflight.mode -ne 'Simulation') {
        throw 'Invoke-XboxOSDisposableImagePreflightSimulate requires Mode=Simulation.'
    }

    $adapter = $Preflight.adapter
    $null = $Preflight.audit.Add((New-XboxOSAuditEvent -Type 'PreflightStart' -Message 'Simulation preflight started'))

    $Preflight.prerequisites = Test-XboxOSSourceImagePrerequisites `
        -IsoPath $Preflight.isoPath `
        -WorkRoot $Preflight.workRoot `
        -LogsRoot $Preflight.logsRoot `
        -RequireIsoPresent:$false `
        -RequireAdministrator:$false `
        -ExistingMounts @() `
        -MinimumFreeBytes 1KB

    if ($null -eq $Preflight.prerequisites -or -not [bool]$Preflight.prerequisites.valid) {
        foreach ($e in @($Preflight.prerequisites.errors)) { $null = $Preflight.blockers.Add($e) }
        $Preflight.transactionState = 'Failed'
        $Preflight.cleanupStatus = 'NotRequired'
        return $Preflight
    }

    $Preflight.transactionState = 'SourceVerified'
    $ver = $adapter.InvokeOperation('GetDismVersion')
    $null = $Preflight.commands.Add($ver)

    $img = $adapter.InvokeOperation('GetImageInfo', @{ ImageFile = $Preflight.isoPath })
    $null = $Preflight.commands.Add($img)
    $images = @(ConvertFrom-XboxOSDismImageInfoOutput -Output @($img.Output))
    $resolved = Resolve-XboxOSExactImageIndex -Images $images -ExactName $script:XboxOSExpectedEditionName
    $Preflight.sourceImage = [pscustomobject]@{
        editionName    = [string]$resolved.Name
        sourceIndex    = [int]$resolved.Index
        buildNumber    = $script:XboxOSExpectedBuildNumber
        displayVersion = $script:XboxOSExpectedDisplayVersion
        isoSha256      = Get-XboxOSExpectedSourceIsoSha256
        isoPath        = $Preflight.isoPath
    }
    $Preflight.transactionState = 'WorkspacePrepared'

    $Preflight.workspace = New-XboxOSDisposableWorkspace -WorkRoot $Preflight.workRoot
    if (-not $SkipWorkspaceFiles) {
        $null = New-Item -ItemType Directory -Path $Preflight.workspace.workspacePath -Force
        $null = New-Item -ItemType Directory -Path $Preflight.workspace.mountDir -Force
    }

    try {
        $export = $adapter.InvokeOperation('ExportImage', @{
                SourceImageFile      = $Preflight.isoPath
                SourceIndex          = [string]$Preflight.sourceImage.sourceIndex
                DestinationImageFile = $Preflight.workspace.disposableWimPath
            })
        $null = $Preflight.commands.Add($export)
        $Preflight.transactionState = 'DisposableWimExported'

        $expInfo = $adapter.InvokeOperation('GetExportedImageInfo', @{ ImageFile = $Preflight.workspace.disposableWimPath })
        $null = $Preflight.commands.Add($expInfo)

        $mount = $adapter.InvokeOperation('MountImageReadOnly', @{
                ImageFile = $Preflight.workspace.disposableWimPath
                Index     = '1'
                MountDir  = $Preflight.workspace.mountDir
            })
        $null = $Preflight.commands.Add($mount)
        $Preflight.mountOwned = $true
        $Preflight.transactionState = 'ReadOnlyMounted'

        $pkg = $adapter.InvokeOperation('GetPackages', @{ MountDir = $Preflight.workspace.mountDir })
        $appx = $adapter.InvokeOperation('GetProvisionedAppxPackages', @{ MountDir = $Preflight.workspace.mountDir })
        $feat = $adapter.InvokeOperation('GetFeatures', @{ MountDir = $Preflight.workspace.mountDir })
        $null = $Preflight.commands.Add($pkg)
        $null = $Preflight.commands.Add($appx)
        $null = $Preflight.commands.Add($feat)

        $appxNames = @(ConvertFrom-XboxOSDismProvisionedAppxListOutput -Output @($appx.Output) | ForEach-Object { $_.PackageName })
        $features = @(ConvertFrom-XboxOSDismFeatureListOutput -Output @($feat.Output))
        $packages = @(ConvertFrom-XboxOSDismPackageListOutput -Output @($pkg.Output))

        $Preflight.freshInventory = New-XboxOSInventorySnapshot `
            -AppxAvailability Available `
            -FeatureAvailability Available `
            -AppxPackages $appxNames `
            -Features $features `
            -Packages $packages `
            -Source 'mock-readonly-adapter' `
            -VerificationStatus Authoritative `
            -SourceImage $Preflight.sourceImage `
            -AdvertisedAppxCount $appxNames.Count `
            -AdvertisedFeatureCount $features.Count `
            -AdvertisedPackageCount $packages.Count

        $Preflight.transactionState = 'InventoryCaptured'

        $Preflight.driftResult = Test-XboxOSInventoryDrift `
            -Plan $Preflight.plan `
            -FreshInventory $Preflight.freshInventory `
            -CompatibilityManifest $Preflight.compatibilityManifest

        if ($Preflight.freshInventory.inventoryFingerprint -ne $Preflight.plan.inventoryFingerprint) {
            $Preflight.recomputedPlan = New-XboxOSServicingPlan `
                -Inventory $Preflight.freshInventory `
                -RemoveAppsManifest (Import-XboxOSManifest -Path (Join-Path (Get-XboxOSRepoRoot) 'config\remove-apps.json')) `
                -DisableFeaturesManifest (Import-XboxOSManifest -Path (Join-Path (Get-XboxOSRepoRoot) 'config\disable-features.json')) `
                -CompatibilityManifest $Preflight.compatibilityManifest
            $null = $Preflight.blockers.Add('Inventory fingerprint differs from plan; recomputed plan hash recorded; prior approvals are invalid.')
        }

        $Preflight.dependencyResult = Get-XboxOSDependencyCategoryEvidence `
            -Inventory $Preflight.freshInventory `
            -CompatibilityManifest $Preflight.compatibilityManifest

        $depOps = Test-XboxOSDependencySafety -Plan $Preflight.plan -DependencyEvidence @()
        $Preflight.operationDependencyResult = $depOps
        if ($depOps.failClosed) {
            $null = $Preflight.blockers.Add(('Eligible operation dependencies remain {0}; approval cannot override.' -f $depOps.aggregateOutcome))
        }
        if ($Preflight.dependencyResult.failClosed) {
            $null = $Preflight.blockers.Add(('Dependency categories: {0}' -f $Preflight.dependencyResult.aggregateOutcome))
        }
        if ($Preflight.driftResult.failClosed) {
            $null = $Preflight.blockers.Add(('Drift: {0}' -f $Preflight.driftResult.result))
        }

        $Preflight.transactionState = 'DriftEvaluated'

        $null = Assert-XboxOSDisposableWorkspaceOwnership -Workspace $Preflight.workspace -OwnershipToken $Preflight.workspace.ownershipToken -CandidateMountDir $Preflight.workspace.mountDir
        $unmount = $adapter.InvokeOperation('UnmountDiscard', @{ MountDir = $Preflight.workspace.mountDir })
        $null = $Preflight.commands.Add($unmount)
        $Preflight.mountOwned = $false
        $Preflight.transactionState = 'ReadOnlyUnmounted'
        $Preflight.cleanupStatus = 'Succeeded'
        $Preflight.transactionState = 'Completed'
    }
    catch {
        $null = $Preflight.blockers.Add([string]$_.Exception.Message)
        $Preflight.transactionState = 'RecoveryRequired'
        try {
            if ($Preflight.workspace -and $Preflight.mountOwned) {
                $null = Assert-XboxOSDisposableWorkspaceOwnership -Workspace $Preflight.workspace -OwnershipToken $Preflight.workspace.ownershipToken -CandidateMountDir $Preflight.workspace.mountDir
                $null = $adapter.InvokeOperation('UnmountDiscard', @{ MountDir = $Preflight.workspace.mountDir })
                $Preflight.mountOwned = $false
                $Preflight.cleanupStatus = 'Recovered'
                $Preflight.transactionState = 'Aborted'
            }
            else {
                $Preflight.cleanupStatus = 'NotRequired'
                $Preflight.transactionState = 'Failed'
            }
        }
        catch {
            $null = $Preflight.blockers.Add(('Cleanup failure: {0}' -f $_.Exception.Message))
            $Preflight.cleanupStatus = 'Failed'
            $Preflight.transactionState = 'Failed'
        }
    }

    $Preflight.modifyingCommandsInvoked = $false
    $Preflight.realDismExecutionEnabled = $false
    $Preflight.executionAuthorized = $false
    $Preflight.sourceIsoProtected = -not [bool]$adapter.Ctx.SourceIsoModified
    Assert-XboxOSExecutionSafetyInvariants -Transaction ([pscustomobject]@{
            modifyingCommandsInvoked = $Preflight.modifyingCommandsInvoked
            executionAuthorized      = $Preflight.executionAuthorized
            realDismExecutionEnabled = $Preflight.realDismExecutionEnabled
        })

    $lifecycleOk = (
        $Preflight.transactionState -eq 'Completed' -and
        $Preflight.cleanupStatus -eq 'Succeeded' -and
        -not $Preflight.mountOwned
    )
    if (-not $lifecycleOk) {
        $Preflight.preflightDecision = 'Failed'
    }
    elseif (@($Preflight.blockers).Count -gt 0) {
        $Preflight.preflightDecision = 'Blocked'
    }
    else {
        $Preflight.preflightDecision = 'ReadyForReview'
    }

    $null = $Preflight.audit.Add((New-XboxOSAuditEvent -Type 'PreflightEnd' -Message ("state={0} decision={1}" -f $Preflight.transactionState, $Preflight.preflightDecision)))
    , $Preflight
}

function Assert-XboxOSLiveReadOnlyPreflightAuthorization {
    [CmdletBinding()]
    param(
        [switch]$ConfirmLiveReadOnlyPreflight,
        [switch]$AllowLiveReadOnlyPreflight,
        [switch]$IUnderstandTemporaryHostState,
        [switch]$AllowCiBypassForUnitTests
    )

    if ((Test-XboxOSContinuousIntegrationEnvironment) -and -not $AllowCiBypassForUnitTests) {
        throw 'Live read-only preflight cannot run in CI (GITHUB_ACTIONS/CI/TF_BUILD).'
    }
    if (-not $ConfirmLiveReadOnlyPreflight) {
        throw 'Live read-only preflight requires -ConfirmLiveReadOnlyPreflight.'
    }
    if (-not $AllowLiveReadOnlyPreflight) {
        throw 'Live read-only preflight requires -AllowLiveReadOnlyPreflight (explicit operator authorization).'
    }
    if (-not $IUnderstandTemporaryHostState) {
        throw 'Live read-only preflight requires -IUnderstandTemporaryHostState acknowledging temporary files, disposable WIM export, and host DISM mount state changes.'
    }
}

function Get-XboxOSSourceIsoSha256ForPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [scriptblock]$HashProvider = $null
    )

    if ($HashProvider) {
        $result = & $HashProvider -IsoPath $IsoPath
        if ($result -is [string]) { return $result.ToUpperInvariant() }
        if ($null -ne $result -and $result -is [System.Management.Automation.PSObject] -and
            ($result.PSObject.Properties.Name -contains 'Hash')) {
            return ([string]$result.Hash).ToUpperInvariant()
        }
        if ($null -ne $result -and ($result -is [hashtable] -or $result -is [System.Collections.IDictionary]) -and $result.ContainsKey('Hash')) {
            return ([string]$result.Hash).ToUpperInvariant()
        }
        throw 'HashProvider must return a SHA256 string or an object with .Hash.'
    }
    $hashInfo = Get-XboxOSFileHash -Path $IsoPath
    return ([string]$hashInfo.Hash).ToUpperInvariant()
}

function Invoke-XboxOSDisposableImagePreflightLiveReadOnly {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Preflight,
        [switch]$ConfirmLiveReadOnlyPreflight,
        [switch]$AllowLiveReadOnlyPreflight,
        [switch]$IUnderstandTemporaryHostState,
        [switch]$AllowCiBypassForUnitTests,
        [scriptblock]$IsoMountRunner = $null,
        [scriptblock]$IsoDismountRunner = $null,
        [scriptblock]$HashProvider = $null,
        [scriptblock]$HiveReader = $null,
        [scriptblock]$RegLoad = $null,
        [scriptblock]$RegUnload = $null,
        [scriptblock]$PresenceTester = $null,
        [scriptblock]$CurrentVersionReader = $null,
        [long]$MinimumFreeBytes = 20GB,
        [switch]$SkipWorkspaceFiles
    )

    if ($Preflight.mode -ne 'LiveReadOnly') {
        throw 'Invoke-XboxOSDisposableImagePreflightLiveReadOnly requires Mode=LiveReadOnly.'
    }

    $null = Assert-XboxOSLiveReadOnlyPreflightAuthorization `
        -ConfirmLiveReadOnlyPreflight:$ConfirmLiveReadOnlyPreflight `
        -AllowLiveReadOnlyPreflight:$AllowLiveReadOnlyPreflight `
        -IUnderstandTemporaryHostState:$IUnderstandTemporaryHostState `
        -AllowCiBypassForUnitTests:$AllowCiBypassForUnitTests

    $Preflight.liveReadOnlyAuthorized = $true
    $adapter = $Preflight.adapter
    if (-not $adapter -or -not $adapter.Ctx -or $adapter.Ctx.Kind -ne 'real-readonly-dism') {
        throw 'Live read-only preflight requires New-XboxOSRealReadOnlyDismAdapter (kind=real-readonly-dism).'
    }
    if ([bool]$adapter.Ctx.NativeRunner -and -not $HiveReader -and -not ($RegLoad -or $CurrentVersionReader -or $PresenceTester)) {
        throw 'Harnessed live read-only runs require -HiveReader or injected registry operations so observed metadata is not substituted from expected values.'
    }

    $null = $Preflight.audit.Add((New-XboxOSAuditEvent -Type 'PreflightStart' -Message 'Live read-only preflight started'))

    $isoMounted = $false
    $isoMountInfo = $null
    $expectedIdentity = Get-XboxOSExpectedSourceImageIdentity
    $expectedSha = ([string]$expectedIdentity.isoSha256).ToUpperInvariant()
    $Preflight.expectedSourceImage = $expectedIdentity
    $Preflight.cleanupVerified = $false
    $Preflight.inventoryMetadataVerified = $false
    $Preflight.registryHiveCleanupVerified = $false
    $Preflight.registryHiveCleanupNotApplicable = $false
    $Preflight.registryHiveMount = $null

    # Discard accidental pipeline output from nested asserts/Add calls.
    $null = $(
    try {
        $existingMounts = @()
        try {
            $mountedProbe = $adapter.InvokeOperation('GetMountedImageInfo')
            $null = $Preflight.commands.Add($mountedProbe)
            $existingMounts = @(ConvertFrom-XboxOSMountedImageInfoOutput -Output @($mountedProbe.Output))
            $Preflight.baselineMountInventory = @($existingMounts)
        }
        catch {
            $null = $Preflight.blockers.Add(('Mounted-image probe failed: {0}' -f $_.Exception.Message))
            throw
        }

        $requireAdmin = -not [bool]$adapter.Ctx.NativeRunner
        $Preflight.prerequisites = Test-XboxOSSourceImagePrerequisites `
            -IsoPath $Preflight.isoPath `
            -WorkRoot $Preflight.workRoot `
            -LogsRoot $Preflight.logsRoot `
            -RequireIsoPresent `
            -RequireAdministrator:$requireAdmin `
            -ExistingMounts $existingMounts `
            -MinimumFreeBytes $MinimumFreeBytes `
            -HashProvider $HashProvider

        if ($null -eq $Preflight.prerequisites -or -not [bool]$Preflight.prerequisites.valid) {
            foreach ($e in @($Preflight.prerequisites.errors)) { $null = $Preflight.blockers.Add($e) }
            $Preflight.transactionState = 'Failed'
            $null = Set-XboxOSPreflightCleanupStatus -Preflight $Preflight -Status NotRequired
            throw 'Live read-only prerequisites failed.'
        }

        $actualIsoSha = if ($Preflight.prerequisites.actualSha256) {
            ([string]$Preflight.prerequisites.actualSha256).ToUpperInvariant()
        }
        else {
            Get-XboxOSSourceIsoSha256ForPreflight -IsoPath $Preflight.isoPath -HashProvider $HashProvider
        }
        if (-not [string]::Equals($actualIsoSha, $expectedSha, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ("Source ISO SHA256 mismatch before lifecycle. expected={0} actual={1}" -f $expectedSha, $actualIsoSha)
        }

        $Preflight.transactionState = 'SourceVerified'
        $ver = $adapter.InvokeOperation('GetDismVersion')
        $null = $Preflight.commands.Add($ver)

        $isoMountInfo = Mount-XboxOSSourceIsoForReadOnlyPreflight -IsoPath $Preflight.isoPath -MountRunner $IsoMountRunner
        $isoMounted = $true
        $Preflight.sourceImageFileFromIso = [string]$isoMountInfo.SourceImageFile
        $null = $Preflight.audit.Add((New-XboxOSAuditEvent -Type 'IsoMounted' -Message ("sourceImage={0}" -f $isoMountInfo.SourceImageFile)))

        $img = $adapter.InvokeOperation('GetImageInfo', @{ ImageFile = $isoMountInfo.SourceImageFile })
        $null = $Preflight.commands.Add($img)
        $images = @(ConvertFrom-XboxOSDismImageInfoOutput -Output @($img.Output))
        $resolved = Resolve-XboxOSExactImageIndex -Images $images -ExactName $expectedIdentity.editionName

        $Preflight.workspace = New-XboxOSDisposableWorkspace -WorkRoot $Preflight.workRoot
        if (-not $SkipWorkspaceFiles) {
            $null = New-Item -ItemType Directory -Path $Preflight.workspace.workspacePath -Force
            $null = New-Item -ItemType Directory -Path $Preflight.workspace.mountDir -Force
        }
        $null = Assert-XboxOSPathOwnedAndSafe -CandidatePath $Preflight.workspace.mountDir -WorkspaceRoot $Preflight.workspace.workspacePath
        $null = Assert-XboxOSPathOwnedAndSafe -CandidatePath $Preflight.workspace.disposableWimPath -WorkspaceRoot $Preflight.workspace.workspacePath
        $Preflight.transactionState = 'WorkspacePrepared'

        $export = $adapter.InvokeOperation('ExportImage', @{
                SourceImageFile      = $isoMountInfo.SourceImageFile
                SourceIndex          = [string]$resolved.Index
                DestinationImageFile = $Preflight.workspace.disposableWimPath
            })
        $null = $Preflight.commands.Add($export)
        $Preflight.disposableExportAttempted = $true
        if ([int]$export.ExitCode -ne 0) {
            throw ("Disposable WIM export failed with exit code {0}." -f $export.ExitCode)
        }
        if (-not (Test-Path -LiteralPath $Preflight.workspace.disposableWimPath)) {
            throw 'Disposable WIM export reported success but destination file is missing.'
        }
        $Preflight.disposableExportOccurred = $true
        $Preflight.transactionState = 'DisposableWimExported'

        Dismount-XboxOSSourceIsoForReadOnlyPreflight -IsoPath $Preflight.isoPath -DismountRunner $IsoDismountRunner
        $isoMounted = $false
        $null = $Preflight.audit.Add((New-XboxOSAuditEvent -Type 'IsoDismounted' -Message 'Source ISO dismounted after export; original ISO unmodified.'))

        $expInfo = $adapter.InvokeOperation('GetExportedImageInfo', @{ ImageFile = $Preflight.workspace.disposableWimPath })
        $null = $Preflight.commands.Add($expInfo)
        $exportMeta = @(ConvertFrom-XboxOSDismImageInfoOutput -Output @($expInfo.Output))
        if ($exportMeta.Count -ne 1) {
            throw ("Expected a single-index exported WIM, found {0} indexes." -f $exportMeta.Count)
        }
        if ([int]$exportMeta[0].Index -ne 1) {
            throw ("Expected exported image index 1, found {0}." -f $exportMeta[0].Index)
        }
        if (-not [string]::Equals([string]$exportMeta[0].Name.Trim(), [string]$expectedIdentity.editionName, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ("Exported image name '{0}' does not exactly match '{1}'." -f $exportMeta[0].Name, $expectedIdentity.editionName)
        }

        $exportVersionBuild = ConvertTo-XboxOSNormalizedBuildNumber -VersionText $exportMeta[0].Version
        $architecture = $null
        if ($exportMeta[0].PSObject.Properties['Architecture']) { $architecture = [string]$exportMeta[0].Architecture }

        if ((Test-Path -LiteralPath $Preflight.workspace.disposableWimPath) -and -not $adapter.Ctx.NativeRunner) {
            $Preflight.disposableWimSha256 = (Get-XboxOSFileHash -Path $Preflight.workspace.disposableWimPath).Hash
        }
        elseif (Test-Path -LiteralPath $Preflight.workspace.disposableWimPath) {
            $Preflight.disposableWimSha256 = Get-XboxOSUtf8Sha256Hex -Text ((Get-Content -LiteralPath $Preflight.workspace.disposableWimPath -Raw -ErrorAction SilentlyContinue))
        }
        if ([string]::IsNullOrWhiteSpace([string]$Preflight.disposableWimSha256)) {
            throw 'Exported disposable WIM identity hash could not be established.'
        }

        $Preflight.readOnlyMountAttempted = $true
        $mount = $adapter.InvokeOperation('MountImageReadOnly', @{
                ImageFile = $Preflight.workspace.disposableWimPath
                Index     = '1'
                MountDir  = $Preflight.workspace.mountDir
            })
        $null = $Preflight.commands.Add($mount)
        $Preflight.mountOwned = $true
        $Preflight.transactionState = 'ReadOnlyMounted'

        $ownedMountProbe = $adapter.InvokeOperation('GetMountedImageInfo')
        $null = $Preflight.commands.Add($ownedMountProbe)
        $ownedMounts = @(ConvertFrom-XboxOSMountedImageInfoOutput -Output @($ownedMountProbe.Output))
        $ownedHit = @(
            $ownedMounts | Where-Object {
                $_.MountDir -and (
                    [string]::Equals(
                        (Get-XboxOSCanonicalPath -Path $_.MountDir),
                        (Get-XboxOSCanonicalPath -Path $Preflight.workspace.mountDir),
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                )
            }
        )
        if ($ownedHit.Count -lt 1) {
            throw 'Owned read-only mount not present in Get-MountedImageInfo after mount (uncertain mount outcome).'
        }
        $Preflight.readOnlyMountOccurred = $true
        if ($adapter.Ctx) { $adapter.Ctx.ReadOnlyMountOccurred = $true }

        try {
            $hiveMeta = Get-XboxOSMountedImageHiveMetadata `
                -MountDir $Preflight.workspace.mountDir `
                -HiveReader $HiveReader `
                -RunId $Preflight.preflightId `
                -OwnershipSeed ("{0}|{1}" -f $Preflight.preflightId, $Preflight.workspace.ownershipToken) `
                -RegLoad $RegLoad `
                -RegUnload $RegUnload `
                -PresenceTester $PresenceTester `
                -CurrentVersionReader $CurrentVersionReader
        }
        catch {
            $Preflight.registryHiveCleanupVerified = $false
            if ($_.Exception.Message -match 'registry hive cleanup failed|still present after unload|cleanup was not independently verified') {
                $null = Set-XboxOSPreflightCleanupStatus -Preflight $Preflight -Status Failed
            }
            throw
        }
        if ($hiveMeta.PSObject.Properties['hiveMount']) {
            $Preflight.registryHiveMount = $hiveMeta.hiveMount
        }
        $Preflight.registryHiveCleanupVerified = [bool]$hiveMeta.hiveCleanupVerified
        $Preflight.registryHiveCleanupNotApplicable = [bool]$hiveMeta.hiveCleanupNotApplicable
        if (-not $Preflight.registryHiveCleanupVerified -and -not $Preflight.registryHiveCleanupNotApplicable) {
            $null = Set-XboxOSPreflightCleanupStatus -Preflight $Preflight -Status Failed
            throw 'RecoveryRequired: registry hive cleanup was not verified; refusing to continue toward WIM cleanup success.'
        }
        if ([string]::IsNullOrWhiteSpace([string]$hiveMeta.buildNumber) -or [string]::IsNullOrWhiteSpace([string]$hiveMeta.displayVersion)) {
            throw 'Mounted-image hive metadata incomplete (buildNumber/displayVersion required).'
        }
        if ($exportVersionBuild -and -not [string]::Equals($exportVersionBuild, [string]$hiveMeta.buildNumber, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ("Exported WIM Version build '{0}' contradicts mounted hive build '{1}'." -f $exportVersionBuild, $hiveMeta.buildNumber)
        }
        if (-not $architecture -and $hiveMeta.architecture) { $architecture = [string]$hiveMeta.architecture }

        $observedSource = [pscustomobject]@{
            editionName         = [string]$exportMeta[0].Name.Trim()
            sourceIndex         = [int]$resolved.Index
            exportedIndex       = 1
            buildNumber         = [string]$hiveMeta.buildNumber
            displayVersion      = [string]$hiveMeta.displayVersion
            architecture        = $architecture
            editionId           = $hiveMeta.editionId
            productName         = $hiveMeta.productName
            isoSha256           = $actualIsoSha
            isoPath             = $Preflight.isoPath
            sourceImageFile     = [string]$isoMountInfo.SourceImageFile
            disposableWimPath   = $Preflight.workspace.disposableWimPath
            disposableWimSha256 = [string]$Preflight.disposableWimSha256
            imageVersionText    = $(if ($exportMeta[0].Version) { [string]$exportMeta[0].Version } else { $null })
            metadataSource      = ('{0}+dism-imageinfo' -f $hiveMeta.metadataSource)
            verified            = $false
        }
        $null = Assert-XboxOSObservedSourceImageIdentity -Observed $observedSource -Expected $expectedIdentity
        $observedSource.verified = $true
        $Preflight.sourceImage = $observedSource
        $Preflight.inventoryMetadataVerified = $true

        $pkg = $adapter.InvokeOperation('GetPackages', @{ MountDir = $Preflight.workspace.mountDir })
        $appx = $adapter.InvokeOperation('GetProvisionedAppxPackages', @{ MountDir = $Preflight.workspace.mountDir })
        $feat = $adapter.InvokeOperation('GetFeatures', @{ MountDir = $Preflight.workspace.mountDir })
        $null = $Preflight.commands.Add($pkg)
        $null = $Preflight.commands.Add($appx)
        $null = $Preflight.commands.Add($feat)
        if ([int]$pkg.ExitCode -ne 0 -or [int]$appx.ExitCode -ne 0 -or [int]$feat.ExitCode -ne 0) {
            throw 'Inventory enumeration returned a nonzero DISM exit code.'
        }
        $Preflight.realReadOnlyInspectionOccurred = $true

        $appxNames = @(ConvertFrom-XboxOSDismProvisionedAppxListOutput -Output @($appx.Output) | ForEach-Object { $_.PackageName })
        $features = @(ConvertFrom-XboxOSDismFeatureListOutput -Output @($feat.Output))
        $packages = @(ConvertFrom-XboxOSDismPackageListOutput -Output @($pkg.Output))
        if ($appxNames.Count -lt 1 -or $features.Count -lt 1 -or $packages.Count -lt 1) {
            throw 'Inventory parsing produced incomplete package/AppX/feature sets.'
        }

        $Preflight.freshInventory = New-XboxOSInventorySnapshot `
            -AppxAvailability Available `
            -FeatureAvailability Available `
            -AppxPackages $appxNames `
            -Features $features `
            -Packages $packages `
            -Source 'live-readonly-adapter' `
            -VerificationStatus Authoritative `
            -SourceImage $Preflight.sourceImage `
            -AdvertisedAppxCount $appxNames.Count `
            -AdvertisedFeatureCount $features.Count `
            -AdvertisedPackageCount $packages.Count

        $null = Assert-XboxOSInventoryCompletenessForPreflight -Inventory $Preflight.freshInventory -BaselineInventory $Preflight.baselineInventory
        $Preflight.transactionState = 'InventoryCaptured'

        $Preflight.driftResult = Test-XboxOSInventoryDrift `
            -Plan $Preflight.plan `
            -FreshInventory $Preflight.freshInventory `
            -CompatibilityManifest $Preflight.compatibilityManifest

        if ($Preflight.freshInventory.inventoryFingerprint -ne $Preflight.plan.inventoryFingerprint) {
            $Preflight.recomputedPlan = New-XboxOSServicingPlan `
                -Inventory $Preflight.freshInventory `
                -RemoveAppsManifest (Import-XboxOSManifest -Path (Join-Path (Get-XboxOSRepoRoot) 'config\remove-apps.json')) `
                -DisableFeaturesManifest (Import-XboxOSManifest -Path (Join-Path (Get-XboxOSRepoRoot) 'config\disable-features.json')) `
                -CompatibilityManifest $Preflight.compatibilityManifest
            $null = $Preflight.blockers.Add('Inventory fingerprint differs from plan; recomputed plan hash recorded; prior approvals are invalid.')
        }

        $Preflight.dependencyResult = Get-XboxOSDependencyCategoryEvidence `
            -Inventory $Preflight.freshInventory `
            -CompatibilityManifest $Preflight.compatibilityManifest
        $depOps = Test-XboxOSDependencySafety -Plan $Preflight.plan -DependencyEvidence @()
        $Preflight.operationDependencyResult = $depOps
        if ($depOps.failClosed) {
            $null = $Preflight.blockers.Add(('Eligible operation dependencies remain {0}; approval cannot override.' -f $depOps.aggregateOutcome))
        }
        if ($Preflight.dependencyResult.failClosed) {
            $null = $Preflight.blockers.Add(('Dependency categories: {0}' -f $Preflight.dependencyResult.aggregateOutcome))
        }
        if ($Preflight.driftResult.failClosed) {
            $null = $Preflight.blockers.Add(('Drift: {0}' -f $Preflight.driftResult.result))
        }
        $Preflight.transactionState = 'DriftEvaluated'

        $null = Assert-XboxOSDisposableWorkspaceOwnership -Workspace $Preflight.workspace -OwnershipToken $Preflight.workspace.ownershipToken -CandidateMountDir $Preflight.workspace.mountDir
        $unmount = $adapter.InvokeOperation('UnmountDiscard', @{ MountDir = $Preflight.workspace.mountDir })
        $null = $Preflight.commands.Add($unmount)
        if ([int]$unmount.ExitCode -ne 0) {
            throw ("Unmount-Discard failed with exit code {0}." -f $unmount.ExitCode)
        }

        $cleanupConfirm = Confirm-XboxOSOwnedMountCleanup `
            -Adapter $adapter `
            -OwnedMountDir $Preflight.workspace.mountDir `
            -BaselineMounts $Preflight.baselineMountInventory
        $null = $Preflight.commands.Add($cleanupConfirm.command)
        $Preflight.finalMountInventory = @($cleanupConfirm.finalMounts)
        if (-not [bool]$Preflight.registryHiveCleanupVerified -and -not [bool]$Preflight.registryHiveCleanupNotApplicable) {
            $null = Set-XboxOSPreflightCleanupStatus -Preflight $Preflight -Status Failed
            throw 'RecoveryRequired: refusing WIM cleanup success while registry hive cleanup remains unverified.'
        }
        $Preflight.cleanupVerified = $true
        $Preflight.mountOwned = $false
        $Preflight.transactionState = 'ReadOnlyUnmounted'
        $null = Set-XboxOSPreflightCleanupStatus -Preflight $Preflight -Status Succeeded
        if ($Preflight.cleanupStatus -ne 'Succeeded') {
            throw 'Cleanup confirmation completed but cleanup status could not be marked Succeeded (registry hive or mount verification incomplete).'
        }
        $Preflight.transactionState = 'Completed'
    }
    catch {
        $null = $Preflight.blockers.Add([string]$_.Exception.Message)
        if ($Preflight.transactionState -ne 'Failed') {
            $Preflight.transactionState = 'RecoveryRequired'
        }
        try {
            if ($Preflight.workspace -and ($Preflight.mountOwned -or [bool]$adapter.Ctx.MountOwned -or [bool]$Preflight.readOnlyMountAttempted)) {
                $null = Assert-XboxOSDisposableWorkspaceOwnership -Workspace $Preflight.workspace -OwnershipToken $Preflight.workspace.ownershipToken -CandidateMountDir $Preflight.workspace.mountDir
                $null = $adapter.InvokeOperation('UnmountDiscard', @{ MountDir = $Preflight.workspace.mountDir })
                try {
                    $cleanupConfirm = Confirm-XboxOSOwnedMountCleanup `
                        -Adapter $adapter `
                        -OwnedMountDir $Preflight.workspace.mountDir `
                        -BaselineMounts $Preflight.baselineMountInventory
                    $null = $Preflight.commands.Add($cleanupConfirm.command)
                    $Preflight.finalMountInventory = @($cleanupConfirm.finalMounts)
                    $Preflight.mountOwned = $false
                    $registryHiveBlocking = (
                        -not [bool]$Preflight.registryHiveCleanupNotApplicable -and
                        -not [bool]$Preflight.registryHiveCleanupVerified
                    )
                    if ($registryHiveBlocking) {
                        # WIM mount may be gone, but registry hive cleanup failure forbids overall cleanup success.
                        $Preflight.cleanupVerified = $false
                        $null = Set-XboxOSPreflightCleanupStatus -Preflight $Preflight -Status Failed
                        $Preflight.transactionState = 'Failed'
                        $null = $Preflight.blockers.Add('RecoveryRequired: disposable WIM mount was discarded, but registry hive cleanup remains unverified; evidence preserved.')
                    }
                    else {
                        $Preflight.cleanupVerified = $true
                        $null = Set-XboxOSPreflightCleanupStatus -Preflight $Preflight -Status Recovered
                        $Preflight.transactionState = 'Aborted'
                    }
                }
                catch {
                    $null = $Preflight.blockers.Add(('Cleanup confirmation failure: {0}' -f $_.Exception.Message))
                    $Preflight.cleanupVerified = $false
                    $null = Set-XboxOSPreflightCleanupStatus -Preflight $Preflight -Status Failed
                    $Preflight.transactionState = 'Failed'
                    $null = $Preflight.blockers.Add('RecoveryRequired: owned mount cleanup could not be independently confirmed; workspace and logs preserved.')
                }
            }
            elseif ($Preflight.cleanupStatus -eq 'NotStarted' -or $Preflight.cleanupStatus -eq 'NotRequired') {
                $null = Set-XboxOSPreflightCleanupStatus -Preflight $Preflight -Status NotRequired
                if ($Preflight.transactionState -eq 'RecoveryRequired') {
                    $Preflight.transactionState = 'Failed'
                }
            }
        }
        catch {
            $null = $Preflight.blockers.Add(('Cleanup failure: {0}' -f $_.Exception.Message))
            $Preflight.cleanupVerified = $false
            $null = Set-XboxOSPreflightCleanupStatus -Preflight $Preflight -Status Failed
            $Preflight.transactionState = 'Failed'
            $null = $Preflight.blockers.Add('RecoveryRequired: cleanup failed; workspace and logs preserved for manual investigation.')
        }
    }
    finally {
        if ($isoMounted) {
            try {
                Dismount-XboxOSSourceIsoForReadOnlyPreflight -IsoPath $Preflight.isoPath -DismountRunner $IsoDismountRunner
                $isoMounted = $false
            }
            catch {
                $null = $Preflight.blockers.Add(('ISO dismount failure: {0}' -f $_.Exception.Message))
                $null = Set-XboxOSPreflightCleanupStatus -Preflight $Preflight -Status Failed
                $Preflight.transactionState = 'Failed'
            }
        }

        try {
            if (Test-Path -LiteralPath $Preflight.isoPath) {
                $Preflight.postIsoSha256 = Get-XboxOSSourceIsoSha256ForPreflight -IsoPath $Preflight.isoPath -HashProvider $HashProvider
                $Preflight.postIsoIntegrityVerified = [string]::Equals(
                    $Preflight.postIsoSha256,
                    $expectedSha,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
                if (-not $Preflight.postIsoIntegrityVerified) {
                    $null = $Preflight.blockers.Add(("Post-run ISO SHA256 mismatch. expected=${expectedSha} actual=$($Preflight.postIsoSha256)"))
                    $Preflight.sourceIsoProtected = $false
                    if ($Preflight.transactionState -eq 'Completed') {
                        $Preflight.transactionState = 'Failed'
                    }
                    $null = Set-XboxOSPreflightCleanupStatus -Preflight $Preflight -Status Failed
                }
                else {
                    $Preflight.sourceIsoProtected = $true
                }
            }
            else {
                $Preflight.postIsoIntegrityVerified = $false
                $null = $Preflight.blockers.Add('Post-run ISO integrity check failed: ISO path not accessible.')
                if ($Preflight.transactionState -eq 'Completed') {
                    $Preflight.transactionState = 'Failed'
                }
            }
        }
        catch {
            $Preflight.postIsoIntegrityVerified = $false
            $null = $Preflight.blockers.Add(('Post-run ISO integrity check failed: {0}' -f $_.Exception.Message))
            if ($Preflight.transactionState -eq 'Completed') {
                $Preflight.transactionState = 'Failed'
            }
        }
    }

    if ($adapter.Ctx) {
        $Preflight.realReadOnlyInspectionOccurred = [bool]$adapter.Ctx.RealReadOnlyInspectionOccurred -or [bool]$Preflight.realReadOnlyInspectionOccurred
        $Preflight.disposableExportOccurred = [bool]$adapter.Ctx.DisposableExportOccurred -and [bool]$Preflight.disposableExportOccurred
        $Preflight.readOnlyMountOccurred = [bool]$Preflight.readOnlyMountOccurred
        $Preflight.readOnlyMountAttempted = [bool]$adapter.Ctx.ReadOnlyMountAttempted -or [bool]$Preflight.readOnlyMountAttempted
        $Preflight.disposableExportAttempted = [bool]$adapter.Ctx.DisposableExportAttempted -or [bool]$Preflight.disposableExportAttempted
        $Preflight.mountOwned = [bool]$adapter.Ctx.MountOwned -or [bool]$Preflight.mountOwned
    }

    $Preflight.modifyingCommandsInvoked = $false
    $Preflight.realDismExecutionEnabled = $false
    $Preflight.executionAuthorized = $false
    $null = Assert-XboxOSExecutionSafetyInvariants -Transaction ([pscustomobject]@{
            modifyingCommandsInvoked = $Preflight.modifyingCommandsInvoked
            executionAuthorized      = $Preflight.executionAuthorized
            realDismExecutionEnabled = $Preflight.realDismExecutionEnabled
        })

    $registryHiveOk = (
        [bool]$Preflight.registryHiveCleanupNotApplicable -or
        [bool]$Preflight.registryHiveCleanupVerified
    )
    $lifecycleOk = (
        $Preflight.transactionState -eq 'Completed' -and
        $Preflight.cleanupStatus -eq 'Succeeded' -and
        [bool]$Preflight.cleanupVerified -and
        $registryHiveOk -and
        -not $Preflight.mountOwned -and
        [bool]$Preflight.postIsoIntegrityVerified -and
        [bool]$Preflight.inventoryMetadataVerified -and
        $null -ne $Preflight.freshInventory -and
        $Preflight.freshInventory.verificationStatus -eq 'Authoritative'
    )
    if (-not $lifecycleOk) {
        if ($Preflight.cleanupStatus -eq 'Failed' -or $Preflight.mountOwned -or -not $Preflight.cleanupVerified) {
            if ($Preflight.mountOwned -or ($Preflight.cleanupStatus -eq 'Failed')) {
                $Preflight.transactionState = 'Failed'
            }
            if ($Preflight.mountOwned) {
                $null = $Preflight.blockers.Add('RecoveryRequired: owned mount still held; workspace and logs preserved for manual investigation.')
            }
        }
        $Preflight.preflightDecision = 'Failed'
    }
    elseif (@($Preflight.blockers).Count -gt 0) {
        $Preflight.preflightDecision = 'Blocked'
    }
    else {
        $Preflight.preflightDecision = 'ReadyForReview'
    }

    $null = $Preflight.audit.Add((New-XboxOSAuditEvent -Type 'PreflightEnd' -Message ("state={0} decision={1}" -f $Preflight.transactionState, $Preflight.preflightDecision)))
    ) # end pipeline-discard subexpression

    return $Preflight
}

function Save-XboxOSDisposableImagePreflightReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Preflight,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$Stem = 'XboxOS11-disposable-preflight'
    )

    if ($OutputDirectory -match '(?i)OneDrive') {
        throw "Refusing to write preflight reports under OneDrive: $OutputDirectory"
    }
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

    if ($Preflight.mode -eq 'LiveReadOnly' -and $Stem -notmatch '(?i)live') {
        $Stem = $Stem + '-live-readonly'
    }

    if ($Preflight.cleanupStatus -eq 'Failed' -or $Preflight.mountOwned -or ($Preflight.mode -eq 'LiveReadOnly' -and -not [bool]$Preflight.cleanupVerified)) {
        $null = $Preflight.blockers.Add('Cleanup incomplete, unverified, or mount ownership still held; cannot report unconditional success.')
    }
    if ($Preflight.mode -eq 'LiveReadOnly' -and -not [bool]$Preflight.inventoryMetadataVerified) {
        $null = $Preflight.blockers.Add('Inventory/source metadata verification incomplete; cannot report success.')
    }

    $lifecycleOk = (
        $Preflight.transactionState -eq 'Completed' -and
        $Preflight.cleanupStatus -eq 'Succeeded' -and
        -not $Preflight.mountOwned -and
        -not $Preflight.modifyingCommandsInvoked -and
        -not $Preflight.realDismExecutionEnabled -and
        -not $Preflight.executionAuthorized
    )
    if ($Preflight.mode -eq 'LiveReadOnly') {
        $registryHiveOk = (
            [bool]$Preflight.registryHiveCleanupNotApplicable -or
            [bool]$Preflight.registryHiveCleanupVerified
        )
        $lifecycleOk = (
            $lifecycleOk -and
            [bool]$Preflight.postIsoIntegrityVerified -and
            [bool]$Preflight.cleanupVerified -and
            $registryHiveOk -and
            [bool]$Preflight.inventoryMetadataVerified -and
            $null -ne $Preflight.freshInventory -and
            $Preflight.freshInventory.verificationStatus -eq 'Authoritative'
        )
    }
    $decision = if (-not $lifecycleOk) {
        'Failed'
    }
    elseif (@($Preflight.blockers).Count -gt 0) {
        'Blocked'
    }
    else {
        'ReadyForReview'
    }
    $Preflight.preflightDecision = $decision
    $success = [bool]($lifecycleOk -and $decision -eq 'ReadyForReview')

    $reportType = if ($Preflight.mode -eq 'LiveReadOnly') {
        'disposable-image-preflight-live-readonly'
    }
    else {
        'disposable-image-preflight'
    }

    $report = [ordered]@{
        reportType                      = $reportType
        reportNamespace                 = $(if ($Preflight.mode -eq 'LiveReadOnly') { 'm4-live-readonly' } else { 'm4-simulation' })
        generatedUtc                    = [datetime]::UtcNow
        preflightEngineVersion          = $Preflight.preflightEngineVersion
        mode                            = $Preflight.mode
        preflightId                     = $Preflight.preflightId
        runId                           = $Preflight.preflightId
        transactionState                = $Preflight.transactionState
        preflightDecision               = $decision
        lifecycleCompleted              = [bool]$lifecycleOk
        success                         = [bool]$success
        sourceImage                     = $Preflight.sourceImage
        expectedSourceImage             = $Preflight.expectedSourceImage
        expectedIsoSha256               = Get-XboxOSExpectedSourceIsoSha256
        postIsoSha256                   = $Preflight.postIsoSha256
        postIsoIntegrityVerified        = [bool]$Preflight.postIsoIntegrityVerified
        disposableWimSha256             = $Preflight.disposableWimSha256
        inventoryMetadataVerified         = [bool]$Preflight.inventoryMetadataVerified
        cleanupVerified                   = [bool]$Preflight.cleanupVerified
        registryHiveMount                 = $Preflight.registryHiveMount
        registryHiveCleanupVerified       = [bool]$Preflight.registryHiveCleanupVerified
        registryHiveCleanupNotApplicable  = [bool]$Preflight.registryHiveCleanupNotApplicable
        finalMountInventory               = @($Preflight.finalMountInventory)
        prerequisites                   = $Preflight.prerequisites
        workspace                       = $(if ($Preflight.workspace) {
                [pscustomobject]@{
                    path           = $Preflight.workspace.workspacePath
                    disposableWim  = $Preflight.workspace.disposableWimPath
                    ownershipToken = $Preflight.workspace.ownershipToken
                    ownerId        = $Preflight.workspace.ownerId
                }
            } else { $null })
        inventoryFingerprint            = $(if ($Preflight.freshInventory) { $Preflight.freshInventory.inventoryFingerprint } else { $null })
        inventoryTotals                 = $(if ($Preflight.freshInventory) {
                [pscustomobject]@{
                    appx     = @($Preflight.freshInventory.appxPackages).Count
                    features = @($Preflight.freshInventory.features).Count
                    packages = @($Preflight.freshInventory.packages).Count
                }
            } else { $null })
        driftResult                     = $Preflight.driftResult
        dependencyResult                = $Preflight.dependencyResult
        planContentHash                 = $Preflight.plan.contentHash
        recomputedPlanContentHash       = $(if ($Preflight.recomputedPlan) { $Preflight.recomputedPlan.contentHash } else { $null })
        blockers                        = @($Preflight.blockers | ForEach-Object { [string]$_ })
        commands                        = @($Preflight.commands | ForEach-Object {
                [pscustomobject]@{
                    operation  = $_.Operation
                    class      = $_.Class
                    exitCode   = $_.ExitCode
                    arguments  = @($_.ArgumentList)
                    command    = $(if ($_.PSObject.Properties['Command']) { $_.Command } else { $null })
                    failed     = $(if ($_.PSObject.Properties['failed']) { [bool]$_.failed } else { $false })
                }
            })
        mountOwned                      = [bool]$Preflight.mountOwned
        cleanupStatus                   = [string]$Preflight.cleanupStatus
        modifyingCommandsInvoked        = $false
        realDismExecutionEnabled        = $false
        executionAuthorized             = $false
        liveReadOnlyAuthorized          = [bool]$Preflight.liveReadOnlyAuthorized
        realReadOnlyInspectionOccurred  = [bool]$Preflight.realReadOnlyInspectionOccurred
        disposableExportOccurred        = [bool]$Preflight.disposableExportOccurred
        disposableExportAttempted       = [bool]$Preflight.disposableExportAttempted
        readOnlyMountOccurred           = [bool]$Preflight.readOnlyMountOccurred
        readOnlyMountAttempted          = [bool]$Preflight.readOnlyMountAttempted
        sourceIsoProtected              = [bool]$Preflight.sourceIsoProtected
        notes                           = @(
            'Milestone 4 disposable-image preflight report.'
            'Simulation mode uses mocks/fixtures; live read-only uses allowlisted real adapter after explicit operator authorization.'
            'Observed source metadata is collected independently from the mounted disposable image; expected identity is recorded separately.'
            'Success never authorizes writable DISM servicing (realDismExecutionEnabled/modifyingCommandsInvoked/executionAuthorized remain false).'
            'Test RSA approval keys are development fixtures only and are never production-trusted.'
        )
    }

    $jsonPath = Join-Path $OutputDirectory ($Stem + '.json')
    $mdPath = Join-Path $OutputDirectory ($Stem + '.md')
    ([pscustomobject]$report | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $md = New-Object System.Collections.Generic.List[string]
    $null = $md.Add('# XboxOS11 Disposable Image Preflight (Milestone 4)')
    $null = $md.Add('')
    $null = $md.Add(('- Report namespace: **{0}**' -f $report.reportNamespace))
    $null = $md.Add(('- Mode: **{0}**' -f $report.mode))
    $null = $md.Add(('- Run ID: `{0}`' -f $report.runId))
    $null = $md.Add(('- State: **{0}**' -f $report.transactionState))
    $null = $md.Add(('- Success: **{0}**' -f $report.success))
    $null = $md.Add(('- Plan content hash: `{0}`' -f $report.planContentHash))
    $null = $md.Add(('- Recomputed plan hash: `{0}`' -f $(if ($report.recomputedPlanContentHash) { $report.recomputedPlanContentHash } else { 'n/a' })))
    $null = $md.Add(('- Drift: **{0}**' -f $(if ($report.driftResult) { $report.driftResult.result } else { 'n/a' })))
    $null = $md.Add(('- Dependencies: **{0}**' -f $(if ($report.dependencyResult) { $report.dependencyResult.aggregateOutcome } else { 'n/a' })))
    $null = $md.Add(('- Cleanup: **{0}**' -f $report.cleanupStatus))
    $null = $md.Add(('- Cleanup verified: **{0}**' -f $report.cleanupVerified))
    $null = $md.Add(('- Registry hive cleanup verified: **{0}**' -f $report.registryHiveCleanupVerified))
    if ($report.registryHiveMount -and $report.registryHiveMount.PSObject.Properties['leafName']) {
        $null = $md.Add(('- Registry hive mount: `{0}`' -f $report.registryHiveMount.leafName))
    }
    $null = $md.Add(('- Mount owned: **{0}**' -f $report.mountOwned))
    $null = $md.Add(('- Inventory metadata verified: **{0}**' -f $report.inventoryMetadataVerified))
    $null = $md.Add(('- Modifying commands invoked: **{0}**' -f $report.modifyingCommandsInvoked))
    $null = $md.Add(('- Real DISM execution enabled: **{0}**' -f $report.realDismExecutionEnabled))
    $null = $md.Add(('- Execution authorized: **{0}**' -f $report.executionAuthorized))
    $null = $md.Add(('- Live read-only authorized: **{0}**' -f $report.liveReadOnlyAuthorized))
    $null = $md.Add(('- Real read-only inspection occurred: **{0}**' -f $report.realReadOnlyInspectionOccurred))
    $null = $md.Add(('- Disposable export occurred: **{0}**' -f $report.disposableExportOccurred))
    $null = $md.Add(('- Read-only mount occurred: **{0}**' -f $report.readOnlyMountOccurred))
    $null = $md.Add(('- Source ISO protected: **{0}**' -f $report.sourceIsoProtected))
    $null = $md.Add(('- Post-ISO integrity verified: **{0}**' -f $report.postIsoIntegrityVerified))
    if ($report.expectedSourceImage) {
        $null = $md.Add(('- Expected identity: `{0}` / `{1}` / `{2}`' -f $report.expectedSourceImage.editionName, $report.expectedSourceImage.buildNumber, $report.expectedSourceImage.displayVersion))
    }
    if ($report.sourceImage -and $report.sourceImage.PSObject.Properties['buildNumber']) {
        $null = $md.Add(('- Observed identity: `{0}` / `{1}` / `{2}`' -f $report.sourceImage.editionName, $report.sourceImage.buildNumber, $report.sourceImage.displayVersion))
    }
    $null = $md.Add('')
    $null = $md.Add('## Blockers')
    $null = $md.Add('')
    if (@($report.blockers).Count -eq 0) { $null = $md.Add('_None_') }
    else { foreach ($b in @($report.blockers)) { $null = $md.Add(('- {0}' -f $b)) } }

    ($md -join [Environment]::NewLine) + [Environment]::NewLine | Set-Content -LiteralPath $mdPath -Encoding UTF8

    return [pscustomobject]@{ Json = $jsonPath; Markdown = $mdPath; Report = [pscustomobject]$report }
}

