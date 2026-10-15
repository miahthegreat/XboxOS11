# Milestone 2 servicing plan engine (plan-only; no modifying DISM).
# Dotted into XboxOS.Build.psm1.

$script:XboxOSServicingPlanEngineVersion = '2.1.0'
$script:XboxOSPlanHashSchemaVersion = 'plan-hash-v1'
$script:XboxOSInventorySchemaVersion = '2.0'
$script:XboxOSSupportedInventorySchemaVersions = @('2.0')

function Get-XboxOSServicingPlanEngineVersion {
    [CmdletBinding()]
    param()
    return $script:XboxOSServicingPlanEngineVersion
}

function Get-XboxOSPlanHashSchemaVersion {
    [CmdletBinding()]
    param()
    return $script:XboxOSPlanHashSchemaVersion
}

function Get-XboxOSUtf8Sha256Hex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }
    return ([System.BitConverter]::ToString($hash) -replace '-', '')
}

function ConvertTo-XboxOSCanonicalJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) {
        return 'null'
    }
    if ($Value -is [bool]) {
        if ($Value) { return 'true' } else { return 'false' }
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return "$Value"
    }
    if ($Value -is [string]) {
        return (($Value | ConvertTo-Json -Compress))
    }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [ordered]) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($key in @($Value.Keys)) {
            $parts.Add(('"{0}":{1}' -f ($key -replace '\\', '\\\\' -replace '"', '\"'), (ConvertTo-XboxOSCanonicalJson -Value $Value[$key]))) | Out-Null
        }
        return '{' + ($parts -join ',') + '}'
    }
    # PSCustomObject / ordered-like
    if ($Value -is [pscustomobject] -or $Value.PSObject.TypeNames -contains 'System.Management.Automation.PSCustomObject') {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($prop in @($Value.PSObject.Properties)) {
            $parts.Add(('"{0}":{1}' -f ($prop.Name -replace '\\', '\\\\' -replace '"', '\"'), (ConvertTo-XboxOSCanonicalJson -Value $prop.Value))) | Out-Null
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = New-Object System.Collections.Generic.List[string]
        foreach ($item in @($Value)) {
            $items.Add((ConvertTo-XboxOSCanonicalJson -Value $item)) | Out-Null
        }
        return '[' + ($items -join ',') + ']'
    }
    return (($Value | ConvertTo-Json -Compress -Depth 20))
}

function Get-XboxOSManifestContentFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Manifest
    )

    $canonical = ConvertTo-XboxOSCanonicalJson -Value $Manifest
    return Get-XboxOSUtf8Sha256Hex -Text $canonical
}

function Get-XboxOSInventoryFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Inventory
    )

    $appx = @($Inventory.appxPackages | ForEach-Object { [string]$_ } | Sort-Object)
    $features = @(
        $Inventory.features | ForEach-Object {
            [ordered]@{
                name  = [string]$_.Name
                state = $(if ($null -ne $_.State) { [string]$_.State } else { '' })
            }
        } | Sort-Object { $_.name }
    )
    $doc = [ordered]@{
        appxPackages = $appx
        features     = @($features)
    }
    return Get-XboxOSUtf8Sha256Hex -Text (ConvertTo-XboxOSCanonicalJson -Value $doc)
}

function Assert-XboxOSInventorySnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Inventory
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $appx = @($Inventory.appxPackages)
    $features = @($Inventory.features)

    $dupAppx = @($appx | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($dupAppx.Count -gt 0) {
        $errors.Add(('Duplicate AppX identities: {0}' -f ($dupAppx -join '; '))) | Out-Null
    }

    $dupFeat = @($features | ForEach-Object { [string]$_.Name } | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($dupFeat.Count -gt 0) {
        $errors.Add(('Duplicate feature identities: {0}' -f ($dupFeat -join '; '))) | Out-Null
    }

    if ($Inventory.appxAvailability -eq 'Available') {
        if ($appx.Count -eq 0) {
            $errors.Add('AppxAvailability=Available but no AppX identities were provided.') | Out-Null
        }
        foreach ($name in $appx) {
            if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains('*') -or $name.Contains('?')) {
                $errors.Add("AppX identity is missing or not exact: '$name'") | Out-Null
            }
        }
    }

    if ($Inventory.featureAvailability -eq 'Available') {
        if ($features.Count -eq 0) {
            $errors.Add('FeatureAvailability=Available but no feature records were provided.') | Out-Null
        }
        foreach ($feature in $features) {
            if ([string]::IsNullOrWhiteSpace([string]$feature.Name)) {
                $errors.Add('Feature record is missing Name.') | Out-Null
            }
            if ([string]::IsNullOrWhiteSpace([string]$feature.State)) {
                $errors.Add(("Feature '{0}' is missing State." -f $feature.Name)) | Out-Null
            }
        }
    }

    if ($Inventory.PSObject.Properties['advertisedAppxCount'] -and $null -ne $Inventory.advertisedAppxCount) {
        if ([int]$Inventory.advertisedAppxCount -ne $appx.Count -and -not [bool]$Inventory.legacyNestedCountIgnored) {
            $errors.Add(("Advertised AppX count {0} does not match parsed count {1}." -f $Inventory.advertisedAppxCount, $appx.Count)) | Out-Null
        }
    }
    if ($Inventory.PSObject.Properties['advertisedFeatureCount'] -and $null -ne $Inventory.advertisedFeatureCount) {
        if ([int]$Inventory.advertisedFeatureCount -ne $features.Count -and -not [bool]$Inventory.legacyNestedCountIgnored) {
            $errors.Add(("Advertised feature count {0} does not match parsed count {1}." -f $Inventory.advertisedFeatureCount, $features.Count)) | Out-Null
        }
    }

    return [pscustomobject]@{
        Valid  = ($errors.Count -eq 0)
        Errors = $errors.ToArray()
    }
}

function New-XboxOSInventorySnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Unknown', 'Empty', 'Available')]
        [string]$AppxAvailability,

        [Parameter(Mandatory)]
        [ValidateSet('Unknown', 'Empty', 'Available')]
        [string]$FeatureAvailability,

        [AllowEmptyCollection()]
        [string[]]$AppxPackages = @(),

        [AllowEmptyCollection()]
        [object[]]$Features = @(),

        [AllowEmptyCollection()]
        [object[]]$Packages = @(),

        [string]$Source = 'inline',

        $CapturedUtc = $null,

        [AllowEmptyCollection()]
        [string[]]$Notes = @(),

        [ValidateSet('Authoritative', 'Unverified', 'Blocked')]
        [string]$VerificationStatus = 'Unverified',

        [AllowEmptyCollection()]
        [string[]]$VerificationErrors = @(),

        [object]$SourceImage = $null,

        [nullable[int]]$AdvertisedAppxCount = $null,

        [nullable[int]]$AdvertisedFeatureCount = $null,

        [nullable[int]]$AdvertisedPackageCount = $null,

        [switch]$LegacyNestedCountIgnored,

        [string]$InventorySchemaVersion = ''
    )

    if (-not $InventorySchemaVersion) {
        $InventorySchemaVersion = $script:XboxOSInventorySchemaVersion
    }
    if ($script:XboxOSSupportedInventorySchemaVersions -notcontains $InventorySchemaVersion) {
        throw ("Unsupported inventory schema version '{0}'. Supported: {1}" -f $InventorySchemaVersion, ($script:XboxOSSupportedInventorySchemaVersions -join ', '))
    }

    if ($AppxAvailability -eq 'Available' -and @($AppxPackages).Count -eq 0) {
        throw 'AppxAvailability=Available requires at least one AppX package identity, or use Empty.'
    }
    if ($FeatureAvailability -eq 'Available' -and @($Features).Count -eq 0) {
        throw 'FeatureAvailability=Available requires at least one feature record, or use Empty.'
    }

    $normalizedFeatures = @(
        foreach ($feature in @($Features)) {
            if ($null -eq $feature) { continue }
            if ($feature -is [string]) {
                [pscustomobject]@{ Name = [string]$feature; State = $null }
            }
            else {
                [pscustomobject]@{
                    Name  = [string]$feature.Name
                    State = $(if ($feature.PSObject.Properties['State']) { [string]$feature.State } else { $null })
                }
            }
        }
    )

    $snapshot = [pscustomobject]@{
        inventorySchemaVersion     = $InventorySchemaVersion
        source                     = $Source
        capturedUtc                = $CapturedUtc
        appxAvailability           = $AppxAvailability
        featureAvailability        = $FeatureAvailability
        appxPackages               = [string[]]@($AppxPackages | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        features                   = $normalizedFeatures
        packages                   = @($Packages)
        notes                      = @($Notes)
        verificationStatus         = $VerificationStatus
        verificationErrors         = @($VerificationErrors)
        sourceImage                = $SourceImage
        advertisedAppxCount        = $AdvertisedAppxCount
        advertisedFeatureCount     = $AdvertisedFeatureCount
        advertisedPackageCount     = $AdvertisedPackageCount
        legacyNestedCountIgnored   = [bool]$LegacyNestedCountIgnored
        inventoryFingerprint       = $null
    }

    $assert = Assert-XboxOSInventorySnapshot -Inventory $snapshot
    if (-not $assert.Valid) {
        $snapshot.verificationStatus = 'Blocked'
        $snapshot.verificationErrors = @($snapshot.verificationErrors + $assert.Errors | Select-Object -Unique)
        $snapshot.appxAvailability = 'Unknown'
        $snapshot.featureAvailability = 'Unknown'
        $snapshot.notes = @($snapshot.notes + 'Inventory blocked by Assert-XboxOSInventorySnapshot; treated as Unknown for planning.')
    }

    if ($snapshot.verificationStatus -eq 'Authoritative' -and ($snapshot.appxAvailability -eq 'Unknown' -or $snapshot.featureAvailability -eq 'Unknown')) {
        $snapshot.verificationStatus = 'Blocked'
        $snapshot.verificationErrors = @($snapshot.verificationErrors + 'Authoritative inventory cannot have Unknown availability.')
    }

    $snapshot.inventoryFingerprint = Get-XboxOSInventoryFingerprint -Inventory $snapshot
    return $snapshot
}

function Import-XboxOSInventoryFromCompatReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Compat report not found: $Path"
    }

    $report = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $notes = New-Object System.Collections.Generic.List[string]
    $verificationErrors = New-Object System.Collections.Generic.List[string]
    $legacyNestedCountIgnored = $false

    if (-not ($report.PSObject.Properties['success']) -or -not [bool]$report.success) {
        $verificationErrors.Add('Source compatibility report success is not True.') | Out-Null
    }

    $requiredSteps = @('Get-Packages', 'Get-ProvisionedAppxPackages', 'Get-Features')
    $commands = @()
    if ($report.PSObject.Properties['commands'] -and $report.commands) {
        $commands = @($report.commands)
    }
    else {
        $verificationErrors.Add('Compat report is missing commands[] required for inventory reconstruction.') | Out-Null
    }

    foreach ($step in $requiredSteps) {
        $cmd = @($commands | Where-Object { $_.Step -eq $step } | Select-Object -First 1)
        if ($cmd.Count -ne 1) {
            $verificationErrors.Add("Missing required DISM command transcript step '$step'.") | Out-Null
            continue
        }
        if ([int]$cmd[0].ExitCode -ne 0) {
            $verificationErrors.Add(("DISM step '{0}' exit code {1} is nonzero." -f $step, $cmd[0].ExitCode)) | Out-Null
        }
        if (-not $cmd[0].Output -or @($cmd[0].Output).Count -lt 5) {
            $verificationErrors.Add("DISM step '$step' output is missing or truncated.") | Out-Null
        }
    }

    $appxCmd = @($commands | Where-Object { $_.Step -eq 'Get-ProvisionedAppxPackages' } | Select-Object -First 1)
    $featCmd = @($commands | Where-Object { $_.Step -eq 'Get-Features' } | Select-Object -First 1)
    $pkgCmd = @($commands | Where-Object { $_.Step -eq 'Get-Packages' } | Select-Object -First 1)

    $appxNames = @()
    $features = @()
    $packages = @()

    if ($appxCmd.Count -eq 1 -and [int]$appxCmd[0].ExitCode -eq 0) {
        $appxNames = [string[]]@(
            ConvertFrom-XboxOSDismProvisionedAppxListOutput -Output @($appxCmd[0].Output) |
                ForEach-Object { $_.PackageName }
        )
        $notes.Add('AppX inventory reconstructed exclusively from Get-ProvisionedAppxPackages transcript.') | Out-Null
    }
    if ($featCmd.Count -eq 1 -and [int]$featCmd[0].ExitCode -eq 0) {
        $features = @(ConvertFrom-XboxOSDismFeatureListOutput -Output @($featCmd[0].Output))
        $notes.Add('Feature inventory reconstructed exclusively from Get-Features transcript.') | Out-Null
    }
    if ($pkgCmd.Count -eq 1 -and [int]$pkgCmd[0].ExitCode -eq 0) {
        $packages = @(ConvertFrom-XboxOSDismPackageListOutput -Output @($pkgCmd[0].Output))
        $notes.Add('Package inventory reconstructed exclusively from Get-Packages transcript.') | Out-Null
    }

    $advertisedAppx = $null
    $advertisedFeat = $null
    $advertisedPkg = $null
    if ($report.PSObject.Properties['appxCount']) { $advertisedAppx = [int]$report.appxCount }
    if ($report.PSObject.Properties['featureCount']) { $advertisedFeat = [int]$report.featureCount }
    if ($report.PSObject.Properties['packageCount']) { $advertisedPkg = [int]$report.packageCount }

    # Milestone 1 early reports nested samples so counts collapsed to 1; ignore those advertised totals when transcripts are complete.
    if (($advertisedAppx -eq 1 -or $advertisedFeat -eq 1 -or $advertisedPkg -eq 1) -and
        $appxNames.Count -gt 1 -and $features.Count -gt 1 -and $packages.Count -gt 1) {
        $legacyNestedCountIgnored = $true
        $notes.Add('Ignored legacy nested sample counts (=1) because command transcripts produced complete inventories.') | Out-Null
        $advertisedAppx = $appxNames.Count
        $advertisedFeat = $features.Count
        $advertisedPkg = $packages.Count
    }
    else {
        if ($null -ne $advertisedAppx -and $advertisedAppx -ne $appxNames.Count) {
            $verificationErrors.Add(("Advertised appxCount {0} != parsed {1}." -f $advertisedAppx, $appxNames.Count)) | Out-Null
        }
        if ($null -ne $advertisedFeat -and $advertisedFeat -ne $features.Count) {
            $verificationErrors.Add(("Advertised featureCount {0} != parsed {1}." -f $advertisedFeat, $features.Count)) | Out-Null
        }
        if ($null -ne $advertisedPkg -and $advertisedPkg -ne $packages.Count) {
            $verificationErrors.Add(("Advertised packageCount {0} != parsed {1}." -f $advertisedPkg, $packages.Count)) | Out-Null
        }
    }

    $sourceImage = [ordered]@{
        editionName    = $(if ($report.PSObject.Properties['sourceIndexName']) { [string]$report.sourceIndexName } else { $null })
        sourceIndex    = $(if ($report.PSObject.Properties['sourceIndex']) { [int]$report.sourceIndex } else { $null })
        buildNumber    = $(if ($report.PSObject.Properties['buildNumber']) { [string]$report.buildNumber } else { $null })
        displayVersion = $(if ($report.PSObject.Properties['displayVersion']) { [string]$report.displayVersion } else { $null })
        isoSha256      = $(if ($report.PSObject.Properties['isoSha256Before']) { [string]$report.isoSha256Before } else { $null })
        expectedEditionName = $(if ($report.PSObject.Properties['expectedEditionName']) { [string]$report.expectedEditionName } else { 'Windows 11 Pro' })
    }

    if ([string]::IsNullOrWhiteSpace([string]$sourceImage.editionName)) {
        $verificationErrors.Add('Source image edition name is missing from compat report.') | Out-Null
    }
    elseif ($sourceImage.expectedEditionName -and -not [string]::Equals([string]$sourceImage.editionName, [string]$sourceImage.expectedEditionName, [StringComparison]::OrdinalIgnoreCase)) {
        $verificationErrors.Add(("Source edition '{0}' does not match expected '{1}'." -f $sourceImage.editionName, $sourceImage.expectedEditionName)) | Out-Null
    }

    $appxAvailability = if ($appxNames.Count -gt 0) { 'Available' } else { 'Unknown' }
    $featureAvailability = if ($features.Count -gt 0) { 'Available' } else { 'Unknown' }
    if ($appxAvailability -eq 'Unknown') { $verificationErrors.Add('AppX inventory could not be reconstructed from a successful transcript.') | Out-Null }
    if ($featureAvailability -eq 'Unknown') { $verificationErrors.Add('Feature inventory could not be reconstructed from a successful transcript.') | Out-Null }

    $verificationStatus = if ($verificationErrors.Count -eq 0 -and $appxAvailability -eq 'Available' -and $featureAvailability -eq 'Available') {
        'Authoritative'
    }
    elseif ($appxNames.Count -gt 0 -or $features.Count -gt 0) {
        'Unverified'
    }
    else {
        'Blocked'
    }

    if ($verificationStatus -ne 'Authoritative') {
        $notes.Add('Inventory is not Authoritative; planning will fail closed (Blocked / NotEvaluated).') | Out-Null
        $appxAvailability = 'Unknown'
        $featureAvailability = 'Unknown'
    }

    $captured = $null
    if ($report.PSObject.Properties['generatedUtc'] -and $report.generatedUtc) {
        try { $captured = [datetime]$report.generatedUtc } catch { $captured = $null }
    }

    return New-XboxOSInventorySnapshot `
        -AppxAvailability $appxAvailability `
        -FeatureAvailability $featureAvailability `
        -AppxPackages $appxNames `
        -Features $features `
        -Packages $packages `
        -Source $Path `
        -CapturedUtc $captured `
        -Notes $notes.ToArray() `
        -VerificationStatus $verificationStatus `
        -VerificationErrors $verificationErrors.ToArray() `
        -SourceImage ([pscustomobject]$sourceImage) `
        -AdvertisedAppxCount $advertisedAppx `
        -AdvertisedFeatureCount $advertisedFeat `
        -AdvertisedPackageCount $advertisedPkg `
        -LegacyNestedCountIgnored:$legacyNestedCountIgnored
}

function Get-XboxOSCanonicalPlanPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$PlanDocument
    )

    return ConvertTo-XboxOSCanonicalJson -Value $PlanDocument
}

function Get-XboxOSPlanContentHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CanonicalPayload
    )

    return Get-XboxOSUtf8Sha256Hex -Text $CanonicalPayload
}

function New-XboxOSCanonicalPlanDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Inventory,
        [Parameter(Mandatory)][hashtable]$ManifestFingerprints,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Operations,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Errors,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Warnings,
        [Parameter(Mandatory)][string]$ApprovalGate
    )

    $ops = @(
        $Operations | Sort-Object executionOrder, operationId | ForEach-Object {
            [ordered]@{
                operationId             = [string]$_.operationId
                operationType           = [string]$_.operationType
                targetKind              = [string]$_.targetKind
                targetIdentity          = $(if ($null -ne $_.targetIdentity) { [string]$_.targetIdentity } else { '' })
                manifestSource          = [string]$_.manifestSource
                manifestRuleId          = [string]$_.manifestRuleId
                matchPattern            = $(if ($null -ne $_.matchPattern) { [string]$_.matchPattern } else { '' })
                currentState            = $(if ($null -ne $_.currentState) { [string]$_.currentState } else { '' })
                proposedAction          = [string]$_.proposedAction
                status                  = [string]$_.status
                risk                    = [string]$_.risk
                protectionEvaluation    = [string]$_.protectionEvaluation
                dependencies            = @($_.dependencies | ForEach-Object { [string]$_ } | Sort-Object)
                executionOrder          = [int]$_.executionOrder
                expectedOutcome         = [string]$_.expectedOutcome
                skipOrRejectionReason   = [string]$_.skipOrRejectionReason
                approvalRequired        = [bool]$_.approvalRequired
                dependencyCompleteness  = [string]$_.dependencyCompleteness
            }
        }
    )

    $sourceImage = [ordered]@{
        editionName    = ''
        sourceIndex    = $null
        buildNumber    = ''
        displayVersion = ''
        isoSha256      = ''
    }
    if ($Inventory.sourceImage) {
        foreach ($key in @('editionName', 'sourceIndex', 'buildNumber', 'displayVersion', 'isoSha256')) {
            if ($Inventory.sourceImage.PSObject.Properties[$key] -and $null -ne $Inventory.sourceImage.$key) {
                $sourceImage[$key] = $Inventory.sourceImage.$key
            }
        }
    }

    return [ordered]@{
        hashSchemaVersion        = Get-XboxOSPlanHashSchemaVersion
        engineVersion            = Get-XboxOSServicingPlanEngineVersion
        sourceImage              = $sourceImage
        inventoryFingerprint     = [string]$Inventory.inventoryFingerprint
        inventoryVerification    = [string]$Inventory.verificationStatus
        manifestFingerprints     = [ordered]@{
            removeApps       = [string]$ManifestFingerprints.removeApps
            disableFeatures  = [string]$ManifestFingerprints.disableFeatures
            compatibility    = [string]$ManifestFingerprints.compatibility
        }
        operations               = $ops
        errors                   = @($Errors | ForEach-Object { [string]$_ } | Sort-Object)
        executionRelevantWarnings = @($Warnings | ForEach-Object { [string]$_ } | Sort-Object)
        approvalGate             = [string]$ApprovalGate
        executionAuthorized      = $false
        modifyingCommandsInvoked = $false
    }
}

function New-XboxOSServicingOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$OperationType,
        [Parameter(Mandatory)][string]$TargetKind,
        [string]$TargetIdentity,
        [Parameter(Mandatory)][string]$ManifestSource,
        [Parameter(Mandatory)][string]$ManifestRuleId,
        [string]$MatchPattern,
        [string]$CurrentState,
        [Parameter(Mandatory)][string]$ProposedAction,
        [Parameter(Mandatory)][ValidateSet('Eligible', 'AlreadySatisfied', 'Absent', 'Protected', 'Ambiguous', 'Conflicting', 'Blocked', 'NotEvaluated')]
        [string]$Status,
        [string]$ProtectionEvaluation = '',
        [AllowEmptyCollection()][string[]]$Dependencies = @(),
        [Parameter(Mandatory)][int]$ExecutionOrder,
        [Parameter(Mandatory)][ValidateSet('Low', 'Medium', 'High', 'Critical')]
        [string]$Risk,
        [string]$ExpectedOutcome = '',
        [string]$SkipOrRejectionReason = '',
        [bool]$ApprovalRequired = $false,
        [ValidateSet('NotApplicable', 'Unverified', 'Established')]
        [string]$DependencyCompleteness = 'NotApplicable'
    )

    if ($Status -eq 'Eligible' -and $DependencyCompleteness -eq 'Established') {
        throw 'Eligible operations cannot claim Established dependency completeness.'
    }
    if ($Status -eq 'Eligible' -and $DependencyCompleteness -eq 'NotApplicable') {
        $DependencyCompleteness = 'Unverified'
    }

    return [pscustomobject]@{
        operationId            = $OperationId
        operationType          = $OperationType
        targetKind             = $TargetKind
        targetIdentity         = $TargetIdentity
        manifestSource         = $ManifestSource
        manifestRuleId         = $ManifestRuleId
        matchPattern           = $MatchPattern
        currentState           = $CurrentState
        proposedAction         = $ProposedAction
        status                 = $Status
        protectionEvaluation   = $ProtectionEvaluation
        dependencies           = @($Dependencies)
        executionOrder         = $ExecutionOrder
        risk                   = $Risk
        expectedOutcome        = $ExpectedOutcome
        skipOrRejectionReason  = $SkipOrRejectionReason
        approvalRequired       = $ApprovalRequired
        dependencyCompleteness = $DependencyCompleteness
    }
}

function New-XboxOSServicingPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Inventory,

        [Parameter(Mandatory)]
        [object]$RemoveAppsManifest,

        [Parameter(Mandatory)]
        [object]$DisableFeaturesManifest,

        [Parameter(Mandatory)]
        [object]$CompatibilityManifest,

        [switch]$IncludeDisabledManifestCandidates
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $operations = New-Object System.Collections.Generic.List[object]

    $manifestFingerprints = @{
        removeApps      = Get-XboxOSManifestContentFingerprint -Manifest $RemoveAppsManifest
        disableFeatures = Get-XboxOSManifestContentFingerprint -Manifest $DisableFeaturesManifest
        compatibility   = Get-XboxOSManifestContentFingerprint -Manifest $CompatibilityManifest
    }

    if (-not $Inventory.PSObject.Properties['verificationStatus'] -or [string]::IsNullOrWhiteSpace([string]$Inventory.verificationStatus)) {
        $errors.Add('Inventory is missing verificationStatus; fail closed.') | Out-Null
        $Inventory = New-XboxOSInventorySnapshot -AppxAvailability Unknown -FeatureAvailability Unknown -Source 'invalid-inventory' -VerificationStatus Blocked -VerificationErrors @('Missing verificationStatus')
    }
    elseif ($Inventory.verificationStatus -ne 'Authoritative') {
        foreach ($ve in @($Inventory.verificationErrors)) { $errors.Add("Inventory verification: $ve") | Out-Null }
        $errors.Add(("Inventory verificationStatus '{0}' is not Authoritative; planning fails closed." -f $Inventory.verificationStatus)) | Out-Null
    }

    $protectedAppx = @(Get-XboxOSProtectedAppxPatterns -CompatibilityManifest $CompatibilityManifest)
    $neverDisable = @()
    if ($DisableFeaturesManifest.PSObject.Properties['neverDisable'] -and $DisableFeaturesManifest.neverDisable) {
        $neverDisable = @($DisableFeaturesManifest.neverDisable | ForEach-Object { [string]$_ })
    }
    $protectedFeaturePatterns = @()
    if ($CompatibilityManifest.PSObject.Properties['protectedFeatureNamePatterns'] -and $CompatibilityManifest.protectedFeatureNamePatterns) {
        $protectedFeaturePatterns = @($CompatibilityManifest.protectedFeatureNamePatterns | ForEach-Object { [string]$_ })
    }

    $overlap = Assert-XboxOSDisableFeaturesManifestConsistency -Configuration $DisableFeaturesManifest
    if (-not $overlap.Valid) {
        foreach ($err in @($overlap.Errors)) {
            $errors.Add($err) | Out-Null
            $operations.Add((New-XboxOSServicingOperation `
                    -OperationId 'manifest:disable-features:consistency' `
                    -OperationType 'DisableOptionalFeature' `
                    -TargetKind 'Feature' `
                    -TargetIdentity $null `
                    -ManifestSource 'disable-features.json' `
                    -ManifestRuleId 'ManifestConsistency' `
                    -MatchPattern $null `
                    -CurrentState 'n/a' `
                    -ProposedAction 'RejectManifest' `
                    -Status 'Conflicting' `
                    -ProtectionEvaluation 'neverDisable overlap' `
                    -Dependencies @('Manifest must be corrected before any feature planning.') `
                    -ExecutionOrder 0 `
                    -Risk 'Critical' `
                    -ExpectedOutcome 'No feature disables may be approved.' `
                    -SkipOrRejectionReason $err `
                    -ApprovalRequired:$false)) | Out-Null
        }
    }

    $appxState = [string]$Inventory.appxAvailability
    $featureState = [string]$Inventory.featureAvailability
    $inventoryAuthoritative = ($Inventory.verificationStatus -eq 'Authoritative')
    $appxCanEvaluate = $inventoryAuthoritative -and ($appxState -in @('Empty', 'Available'))
    $featureCanEvaluate = $inventoryAuthoritative -and ($featureState -in @('Empty', 'Available'))

    if (-not $appxCanEvaluate) {
        $errors.Add('AppX inventory is not authoritative/complete; fail closed.') | Out-Null
    }
    if (-not $featureCanEvaluate) {
        $errors.Add('Feature inventory is not authoritative/complete; fail closed.') | Out-Null
    }

    $appxOrder = 100
    foreach ($candidate in @($RemoveAppsManifest.candidates)) {
        $enabled = $true
        if ($candidate.PSObject.Properties['enabled']) { $enabled = [bool]$candidate.enabled }
        if (-not $enabled -and -not $IncludeDisabledManifestCandidates) { continue }

        $patterns = @($candidate.patterns | ForEach-Object { [string]$_ })
        $ruleId = [string]$candidate.id

        if (-not $appxCanEvaluate) {
            $operations.Add((New-XboxOSServicingOperation `
                    -OperationId ("appx:{0}:not-evaluated" -f $ruleId) `
                    -OperationType 'RemoveProvisionedAppx' `
                    -TargetKind 'AppX' `
                    -TargetIdentity $null `
                    -ManifestSource 'remove-apps.json' `
                    -ManifestRuleId $ruleId `
                    -MatchPattern ($patterns -join ';') `
                    -CurrentState $appxState `
                    -ProposedAction 'RemoveProvisionedAppx' `
                    -Status 'NotEvaluated' `
                    -ProtectionEvaluation 'Not evaluated due to unknown inventory' `
                    -Dependencies @('Exact AppX inventory required; Milestone 1 matrix Eligible is not sufficient.') `
                    -ExecutionOrder ($appxOrder++) `
                    -Risk 'Critical' `
                    -ExpectedOutcome 'No removal scheduled.' `
                    -SkipOrRejectionReason 'AppX inventory Unknown/incomplete.' `
                    -ApprovalRequired:$false)) | Out-Null
            continue
        }

        foreach ($pattern in $patterns) {
            if (-not $enabled) {
                # Still resolve identities for reporting when explicitly included; never mark Eligible.
            }

            $matchError = $null
            $matched = @()
            try {
                $matched = @(Resolve-XboxOSPackageMatches -Patterns @($pattern) -AvailablePackages @($Inventory.appxPackages) -RejectAmbiguous)
            }
            catch {
                $matchError = $_.Exception.Message
            }

            if ($matchError) {
                $operations.Add((New-XboxOSServicingOperation `
                        -OperationId ("appx:{0}:ambiguous:{1}" -f $ruleId, ($pattern -replace '[^\w\.\-]+', '_')) `
                        -OperationType 'RemoveProvisionedAppx' `
                        -TargetKind 'AppX' `
                        -TargetIdentity $null `
                        -ManifestSource 'remove-apps.json' `
                        -ManifestRuleId $ruleId `
                        -MatchPattern $pattern `
                        -CurrentState 'ambiguous' `
                        -ProposedAction 'RemoveProvisionedAppx' `
                        -Status 'Ambiguous' `
                        -ProtectionEvaluation 'Rejected before protection evaluation' `
                        -Dependencies @('Exact single identity required for AppX operations.') `
                        -ExecutionOrder ($appxOrder++) `
                        -Risk 'Critical' `
                        -ExpectedOutcome 'No removal scheduled.' `
                        -SkipOrRejectionReason $matchError `
                        -ApprovalRequired:$false)) | Out-Null
                $errors.Add($matchError) | Out-Null
                continue
            }

            if ($matched.Count -eq 0) {
                $operations.Add((New-XboxOSServicingOperation `
                        -OperationId ("appx:{0}:absent:{1}" -f $ruleId, ($pattern -replace '[^\w\.\-]+', '_')) `
                        -OperationType 'RemoveProvisionedAppx' `
                        -TargetKind 'AppX' `
                        -TargetIdentity $null `
                        -ManifestSource 'remove-apps.json' `
                        -ManifestRuleId $ruleId `
                        -MatchPattern $pattern `
                        -CurrentState 'Absent' `
                        -ProposedAction 'RemoveProvisionedAppx' `
                        -Status 'Absent' `
                        -ProtectionEvaluation 'n/a' `
                        -Dependencies @() `
                        -ExecutionOrder ($appxOrder++) `
                        -Risk 'Low' `
                        -ExpectedOutcome 'No change; package not provisioned.' `
                        -SkipOrRejectionReason 'No provisioned AppX identity matched the pattern.' `
                        -ApprovalRequired:$false)) | Out-Null
                continue
            }

            foreach ($identity in $matched) {
                if ([string]::IsNullOrWhiteSpace($identity) -or $identity.Contains('*') -or $identity.Contains('?')) {
                    $operations.Add((New-XboxOSServicingOperation `
                            -OperationId ("appx:{0}:blocked-nonexact" -f $ruleId) `
                            -OperationType 'RemoveProvisionedAppx' `
                            -TargetKind 'AppX' `
                            -TargetIdentity $identity `
                            -ManifestSource 'remove-apps.json' `
                            -ManifestRuleId $ruleId `
                            -MatchPattern $pattern `
                            -CurrentState 'invalid-identity' `
                            -ProposedAction 'RemoveProvisionedAppx' `
                            -Status 'Blocked' `
                            -ProtectionEvaluation 'Exact PackageName required' `
                            -Dependencies @() `
                            -ExecutionOrder ($appxOrder++) `
                            -Risk 'Critical' `
                            -ExpectedOutcome 'No removal scheduled.' `
                            -SkipOrRejectionReason 'Resolved identity is not an exact PackageName.' `
                            -ApprovalRequired:$false)) | Out-Null
                    $errors.Add("Non-exact AppX identity for candidate '$ruleId': $identity") | Out-Null
                    continue
                }

                $isProtected = Test-XboxOSPackageProtected -PackageName $identity -ProtectedPatterns $protectedAppx
                if ($isProtected) {
                    $operations.Add((New-XboxOSServicingOperation `
                            -OperationId ("appx:{0}:{1}" -f $ruleId, $identity) `
                            -OperationType 'RemoveProvisionedAppx' `
                            -TargetKind 'AppX' `
                            -TargetIdentity $identity `
                            -ManifestSource 'remove-apps.json' `
                            -ManifestRuleId $ruleId `
                            -MatchPattern $pattern `
                            -CurrentState 'Present' `
                            -ProposedAction 'RemoveProvisionedAppx' `
                            -Status 'Protected' `
                            -ProtectionEvaluation 'Protected by compatibility.json patterns (Store/Xbox/gaming/runtime).' `
                            -Dependencies @('Protected-component priority overrides remove-apps candidates.') `
                            -ExecutionOrder ($appxOrder++) `
                            -Risk 'Critical' `
                            -ExpectedOutcome 'Package retained.' `
                            -SkipOrRejectionReason 'Protected gaming/platform dependency.' `
                            -ApprovalRequired:$false)) | Out-Null
                    continue
                }

                if (-not $enabled) {
                    $operations.Add((New-XboxOSServicingOperation `
                            -OperationId ("appx:{0}:{1}" -f $ruleId, $identity) `
                            -OperationType 'RemoveProvisionedAppx' `
                            -TargetKind 'AppX' `
                            -TargetIdentity $identity `
                            -ManifestSource 'remove-apps.json' `
                            -ManifestRuleId $ruleId `
                            -MatchPattern $pattern `
                            -CurrentState 'Present' `
                            -ProposedAction 'None' `
                            -Status 'Blocked' `
                            -ProtectionEvaluation 'Unprotected but candidate disabled in manifest' `
                            -Dependencies @() `
                            -ExecutionOrder ($appxOrder++) `
                            -Risk 'Low' `
                            -ExpectedOutcome 'Candidate ignored.' `
                            -SkipOrRejectionReason 'Candidate disabled in remove-apps manifest.' `
                            -ApprovalRequired:$false)) | Out-Null
                    continue
                }

                $depNote = 'Dependency completeness Unverified; presence alone does not establish Store/Xbox/runtime safety.'
                $operations.Add((New-XboxOSServicingOperation `
                        -OperationId ("appx:{0}:{1}" -f $ruleId, $identity) `
                        -OperationType 'RemoveProvisionedAppx' `
                        -TargetKind 'AppX' `
                        -TargetIdentity $identity `
                        -ManifestSource 'remove-apps.json' `
                        -ManifestRuleId $ruleId `
                        -MatchPattern $pattern `
                        -CurrentState 'Present' `
                        -ProposedAction 'RemoveProvisionedAppx' `
                        -Status 'Eligible' `
                        -ProtectionEvaluation 'Not matched by protectedAppxPatterns.' `
                        -Dependencies @($depNote) `
                        -ExecutionOrder ($appxOrder++) `
                        -Risk 'High' `
                        -ExpectedOutcome 'Provisioned AppX removed from disposable WIM only after separate future executor verification.' `
                        -SkipOrRejectionReason '' `
                        -ApprovalRequired:$true `
                        -DependencyCompleteness Unverified)) | Out-Null
                $warnings.Add("Eligible AppX removal planned for exact identity '$identity' (candidate '$ruleId'); PendingOperatorApproval is not execution permission.") | Out-Null
            }
        }
    }

    $featureNames = @($Inventory.features | ForEach-Object { [string]$_.Name })
    $featureOrder = 200
    foreach ($candidate in @($DisableFeaturesManifest.candidates)) {
        $enabled = $true
        if ($candidate.PSObject.Properties['enabled']) { $enabled = [bool]$candidate.enabled }
        if (-not $enabled -and -not $IncludeDisabledManifestCandidates) { continue }

        $ruleId = [string]$candidate.id
        foreach ($requested in @($candidate.featureNames)) {
            $name = [string]$requested
            if (-not $featureCanEvaluate) {
                $operations.Add((New-XboxOSServicingOperation `
                        -OperationId ("feature:{0}:{1}:not-evaluated" -f $ruleId, $name) `
                        -OperationType 'DisableOptionalFeature' `
                        -TargetKind 'Feature' `
                        -TargetIdentity $name `
                        -ManifestSource 'disable-features.json' `
                        -ManifestRuleId $ruleId `
                        -MatchPattern $name `
                        -CurrentState $featureState `
                        -ProposedAction 'DisableOptionalFeature' `
                        -Status 'NotEvaluated' `
                        -ProtectionEvaluation 'Not evaluated due to unknown inventory' `
                        -Dependencies @('Feature inventory required.') `
                        -ExecutionOrder ($featureOrder++) `
                        -Risk 'Critical' `
                        -ExpectedOutcome 'No disable scheduled.' `
                        -SkipOrRejectionReason 'Feature inventory Unknown/incomplete.' `
                        -ApprovalRequired:$false)) | Out-Null
                continue
            }

            $resolved = @(Resolve-XboxOSFeatureMatches -FeatureNames @($name) -AvailableFeatures $featureNames)
            $item = $resolved[0]
            $state = $null
            if ($item.Resolved) {
                $hit = @($Inventory.features | Where-Object { $_.Name -eq $item.Resolved } | Select-Object -First 1)
                if ($hit.Count -eq 1) { $state = [string]$hit[0].State }
            }

            if ($item.Status -ne 'Exact') {
                $operations.Add((New-XboxOSServicingOperation `
                        -OperationId ("feature:{0}:{1}" -f $ruleId, $name) `
                        -OperationType 'DisableOptionalFeature' `
                        -TargetKind 'Feature' `
                        -TargetIdentity $name `
                        -ManifestSource 'disable-features.json' `
                        -ManifestRuleId $ruleId `
                        -MatchPattern $name `
                        -CurrentState 'Absent' `
                        -ProposedAction 'DisableOptionalFeature' `
                        -Status 'Absent' `
                        -ProtectionEvaluation 'n/a' `
                        -Dependencies @() `
                        -ExecutionOrder ($featureOrder++) `
                        -Risk 'Low' `
                        -ExpectedOutcome 'No change; feature not present.' `
                        -SkipOrRejectionReason 'Feature not present in known inventory.' `
                        -ApprovalRequired:$false)) | Out-Null
                continue
            }

            $identity = [string]$item.Resolved
            $isNever = Test-XboxOSFeatureProtected -FeatureName $identity -NeverDisable $neverDisable
            $isCompatProtected = $false
            foreach ($pattern in $protectedFeaturePatterns) {
                if ($identity -like $pattern) { $isCompatProtected = $true; break }
            }

            if ($isNever -or $isCompatProtected) {
                $status = if ($enabled) { 'Conflicting' } else { 'Protected' }
                if ($status -eq 'Conflicting') {
                    $errors.Add("Enabled disable candidate '$ruleId' targets protected feature '$identity'.") | Out-Null
                }
                $operations.Add((New-XboxOSServicingOperation `
                        -OperationId ("feature:{0}:{1}" -f $ruleId, $identity) `
                        -OperationType 'DisableOptionalFeature' `
                        -TargetKind 'Feature' `
                        -TargetIdentity $identity `
                        -ManifestSource 'disable-features.json' `
                        -ManifestRuleId $ruleId `
                        -MatchPattern $name `
                        -CurrentState $state `
                        -ProposedAction 'DisableOptionalFeature' `
                        -Status $status `
                        -ProtectionEvaluation 'Protected by neverDisable and/or compatibility protectedFeatureNamePatterns.' `
                        -Dependencies @('Protected-component priority overrides disable candidates.') `
                        -ExecutionOrder ($featureOrder++) `
                        -Risk 'Critical' `
                        -ExpectedOutcome 'Feature retained.' `
                        -SkipOrRejectionReason 'Protected / neverDisable policy.' `
                        -ApprovalRequired:$false)) | Out-Null
                continue
            }

            if (-not $enabled) {
                $operations.Add((New-XboxOSServicingOperation `
                        -OperationId ("feature:{0}:{1}" -f $ruleId, $identity) `
                        -OperationType 'DisableOptionalFeature' `
                        -TargetKind 'Feature' `
                        -TargetIdentity $identity `
                        -ManifestSource 'disable-features.json' `
                        -ManifestRuleId $ruleId `
                        -MatchPattern $name `
                        -CurrentState $state `
                        -ProposedAction 'None' `
                        -Status 'Blocked' `
                        -ProtectionEvaluation 'Manifest candidate disabled' `
                        -Dependencies @() `
                        -ExecutionOrder ($featureOrder++) `
                        -Risk 'Low' `
                        -ExpectedOutcome 'Candidate ignored.' `
                        -SkipOrRejectionReason 'Candidate disabled in disable-features manifest.' `
                        -ApprovalRequired:$false)) | Out-Null
                continue
            }

            if (Test-XboxOSFeatureStateDisabled -State $state) {
                $operations.Add((New-XboxOSServicingOperation `
                        -OperationId ("feature:{0}:{1}" -f $ruleId, $identity) `
                        -OperationType 'DisableOptionalFeature' `
                        -TargetKind 'Feature' `
                        -TargetIdentity $identity `
                        -ManifestSource 'disable-features.json' `
                        -ManifestRuleId $ruleId `
                        -MatchPattern $name `
                        -CurrentState $state `
                        -ProposedAction 'DisableOptionalFeature' `
                        -Status 'AlreadySatisfied' `
                        -ProtectionEvaluation 'Unprotected' `
                        -Dependencies @() `
                        -ExecutionOrder ($featureOrder++) `
                        -Risk 'Low' `
                        -ExpectedOutcome 'No-op; already disabled.' `
                        -SkipOrRejectionReason 'Feature already disabled (including Disabled with Payload Removed).' `
                        -ApprovalRequired:$false)) | Out-Null
                continue
            }

            if ($state -eq 'Enabled') {
                $operations.Add((New-XboxOSServicingOperation `
                        -OperationId ("feature:{0}:{1}" -f $ruleId, $identity) `
                        -OperationType 'DisableOptionalFeature' `
                        -TargetKind 'Feature' `
                        -TargetIdentity $identity `
                        -ManifestSource 'disable-features.json' `
                        -ManifestRuleId $ruleId `
                        -MatchPattern $name `
                        -CurrentState $state `
                        -ProposedAction 'DisableOptionalFeature' `
                        -Status 'Eligible' `
                        -ProtectionEvaluation 'Unprotected; currently Enabled.' `
                        -Dependencies @('Feature dependency graph not fully modeled; dependencyCompleteness=Unverified.') `
                        -ExecutionOrder ($featureOrder++) `
                        -Risk 'Medium' `
                        -ExpectedOutcome 'Feature disabled with payload retained (removePayload=false) only after separate future executor verification.' `
                        -SkipOrRejectionReason '' `
                        -ApprovalRequired:$true `
                        -DependencyCompleteness Unverified)) | Out-Null
                $warnings.Add("Eligible feature disable planned for '$identity' (candidate '$ruleId'); PendingOperatorApproval is not execution permission.") | Out-Null
                continue
            }

            $operations.Add((New-XboxOSServicingOperation `
                    -OperationId ("feature:{0}:{1}" -f $ruleId, $identity) `
                    -OperationType 'DisableOptionalFeature' `
                    -TargetKind 'Feature' `
                    -TargetIdentity $identity `
                    -ManifestSource 'disable-features.json' `
                    -ManifestRuleId $ruleId `
                    -MatchPattern $name `
                    -CurrentState $(if ($state) { $state } else { '(unspecified)' }) `
                    -ProposedAction 'DisableOptionalFeature' `
                    -Status 'Blocked' `
                    -ProtectionEvaluation 'Unprotected but non-actionable state' `
                    -Dependencies @('State must be understood before disable.') `
                    -ExecutionOrder ($featureOrder++) `
                    -Risk 'High' `
                    -ExpectedOutcome 'No disable scheduled without state review.' `
                    -SkipOrRejectionReason ("Feature state '{0}' is not an actionable Enabled state." -f $(if ($state) { $state } else { '(unspecified)' })) `
                    -ApprovalRequired:$false)) | Out-Null
        }
    }

    # Duplicate / contradictory target detection
    $byTarget = @($operations | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.targetIdentity) } | Group-Object targetIdentity)
    foreach ($group in $byTarget) {
        $statuses = @($group.Group | ForEach-Object { $_.status } | Select-Object -Unique)
        $actions = @($group.Group | ForEach-Object { $_.proposedAction } | Select-Object -Unique)
        $eligibleCount = @($group.Group | Where-Object status -eq 'Eligible').Count
        $contradiction = (
            $actions.Count -gt 1 -or
            ($statuses -contains 'Eligible' -and ($statuses -contains 'Protected' -or $statuses -contains 'Conflicting')) -or
            $eligibleCount -gt 1
        )
        if ($contradiction) {
            $msg = "Duplicate or contradictory operations for target '$($group.Name)': actions=$($actions -join ','), statuses=$($statuses -join ','), eligibleCount=$eligibleCount"
            $errors.Add($msg) | Out-Null
            $operations.Add((New-XboxOSServicingOperation `
                    -OperationId ("conflict:target:{0}" -f ($group.Name -replace '[^\w\.\-]+', '_')) `
                    -OperationType 'RemoveProvisionedAppx' `
                    -TargetKind 'AppX' `
                    -TargetIdentity $group.Name `
                    -ManifestSource 'plan-engine' `
                    -ManifestRuleId 'DuplicateDetection' `
                    -MatchPattern $group.Name `
                    -CurrentState 'conflict' `
                    -ProposedAction 'RejectPlan' `
                    -Status 'Conflicting' `
                    -ProtectionEvaluation 'Duplicate/contradictory detection' `
                    -Dependencies @() `
                    -ExecutionOrder 10 `
                    -Risk 'Critical' `
                    -ExpectedOutcome 'Plan blocked for this target.' `
                    -SkipOrRejectionReason $msg `
                    -ApprovalRequired:$false)) | Out-Null
        }
    }

    $ordered = @($operations | Sort-Object executionOrder, operationId)
    $summary = [ordered]@{
        Eligible         = @($ordered | Where-Object status -eq 'Eligible').Count
        AlreadySatisfied = @($ordered | Where-Object status -eq 'AlreadySatisfied').Count
        Absent           = @($ordered | Where-Object status -eq 'Absent').Count
        Protected        = @($ordered | Where-Object status -eq 'Protected').Count
        Ambiguous        = @($ordered | Where-Object status -eq 'Ambiguous').Count
        Conflicting      = @($ordered | Where-Object status -eq 'Conflicting').Count
        Blocked          = @($ordered | Where-Object status -eq 'Blocked').Count
        NotEvaluated     = @($ordered | Where-Object status -eq 'NotEvaluated').Count
        Total            = $ordered.Count
    }

    $hasBlocking = (
        $summary.Ambiguous -gt 0 -or
        $summary.Conflicting -gt 0 -or
        $summary.NotEvaluated -gt 0 -or
        $errors.Count -gt 0 -or
        -not $appxCanEvaluate -or
        -not $featureCanEvaluate -or
        -not $inventoryAuthoritative
    )
    $hasEligible = $summary.Eligible -gt 0
    $approvalGate = if ($hasBlocking) {
        'Blocked'
    }
    elseif ($hasEligible) {
        'PendingOperatorApproval'
    }
    else {
        'NoActionableChanges'
    }

    # Eligible cannot survive a blocked gate.
    if ($hasBlocking -and $hasEligible) {
        $errors.Add('Eligible operations were suppressed because the plan is Blocked (fail closed).') | Out-Null
        foreach ($op in $ordered) {
            if ($op.status -eq 'Eligible') {
                $op.status = 'Blocked'
                $op.approvalRequired = $false
                $op.skipOrRejectionReason = 'Plan blocked; Eligible cannot remain executable metadata.'
                $op.proposedAction = 'None'
            }
        }
        $ordered = @($operations | Sort-Object executionOrder, operationId)
        $summary = [ordered]@{
            Eligible         = @($ordered | Where-Object status -eq 'Eligible').Count
            AlreadySatisfied = @($ordered | Where-Object status -eq 'AlreadySatisfied').Count
            Absent           = @($ordered | Where-Object status -eq 'Absent').Count
            Protected        = @($ordered | Where-Object status -eq 'Protected').Count
            Ambiguous        = @($ordered | Where-Object status -eq 'Ambiguous').Count
            Conflicting      = @($ordered | Where-Object status -eq 'Conflicting').Count
            Blocked          = @($ordered | Where-Object status -eq 'Blocked').Count
            NotEvaluated     = @($ordered | Where-Object status -eq 'NotEvaluated').Count
            Total            = $ordered.Count
        }
        $hasEligible = $false
        $approvalGate = 'Blocked'
    }

    $errorList = @($errors | ForEach-Object { [string]$_ })
    $warningList = @($warnings | ForEach-Object { [string]$_ })
    $canonicalDocument = New-XboxOSCanonicalPlanDocument `
        -Inventory $Inventory `
        -ManifestFingerprints $manifestFingerprints `
        -Operations @($ordered) `
        -Errors $errorList `
        -Warnings $warningList `
        -ApprovalGate $approvalGate
    $canonical = Get-XboxOSCanonicalPlanPayload -PlanDocument $canonicalDocument
    $contentHash = Get-XboxOSPlanContentHash -CanonicalPayload $canonical
    $generatedUtc = [datetime]::UtcNow
    $planId = 'plan-{0}-{1}' -f $generatedUtc.ToString('yyyyMMddHHmmssfff'), $contentHash.Substring(0, 12).ToLowerInvariant()

    return [pscustomobject]@{
        planId                     = $planId
        engineVersion              = Get-XboxOSServicingPlanEngineVersion
        hashSchemaVersion          = Get-XboxOSPlanHashSchemaVersion
        generatedUtc               = $generatedUtc
        dryRun                     = $true
        modifyingCommandsInvoked   = $false
        executionAuthorized        = $false
        inventorySource            = [string]$Inventory.source
        inventoryFingerprint       = [string]$Inventory.inventoryFingerprint
        inventoryVerification      = [string]$Inventory.verificationStatus
        inventoryAvailability      = [pscustomobject]@{
            appx     = $appxState
            features = $featureState
        }
        sourceImage                = $Inventory.sourceImage
        manifestFingerprints       = [pscustomobject]$manifestFingerprints
        approvalGate               = $approvalGate
        approvalSemantics          = [pscustomobject]@{
            eligibleMeansApproved              = $false
            pendingOperatorApprovalIsExecutable = $false
            planEngineExecutesOperations       = $false
            approvalReusableAcrossDrift        = $false
            futureExecutorMustReverify         = @(
                'approval record for this contentHash'
                'source image identity'
                'inventory fingerprint'
                'manifest fingerprints'
                'protected-component evaluation'
                'plan contentHash recomputation'
            )
        }
        summary                    = [pscustomobject]$summary
        operations                 = $ordered
        warnings                   = @($warnings)
        errors                     = @($errors)
        contentHash                = $contentHash
        canonicalPlanDocument      = $canonicalDocument
        contractsDoc               = 'docs/m2-servicing-plan-contracts.md'
        recoveryDoc                = 'docs/m2-operation-ordering-and-recovery.md'
        hashDoc                    = 'docs/m2-canonical-plan-hash.md'
        notes                      = @(
            'Plan generation never invokes modifying DISM commands.'
            'Eligible and PendingOperatorApproval are planning metadata only; executionAuthorized is always false.'
            'Milestone 1 compatibility-matrix Eligible is not execution permission.'
            'A future executor must re-verify approval, image identity, inventory, manifests, protection, and contentHash before any mutation.'
        )
    }
}

function Save-XboxOSServicingPlanReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Plan,

        [Parameter(Mandatory)]
        [string]$OutputDirectory,

        [string]$Stem = 'XboxOS11-servicing-plan'
    )

    if ($OutputDirectory -match '(?i)OneDrive') {
        throw "Refusing to write servicing plan reports under OneDrive: $OutputDirectory"
    }

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $jsonPath = Join-Path $OutputDirectory ($Stem + '.json')
    $mdPath = Join-Path $OutputDirectory ($Stem + '.md')

    ($Plan | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $nl = [Environment]::NewLine
    $md = New-Object System.Collections.Generic.List[string]
    $null = $md.Add('# XboxOS11 Servicing Plan (Milestone 2 — dry-run)')
    $null = $md.Add('')
    $null = $md.Add(('- Plan ID: `{0}`' -f $Plan.planId))
    $null = $md.Add(('- Engine: `{0}`' -f $Plan.engineVersion))
    $null = $md.Add(('- Hash schema: `{0}`' -f $Plan.hashSchemaVersion))
    $null = $md.Add(('- Generated (UTC): {0}' -f $Plan.generatedUtc))
    $null = $md.Add(('- Inventory source: `{0}`' -f $Plan.inventorySource))
    $null = $md.Add(('- Inventory verification: `{0}`' -f $Plan.inventoryVerification))
    $null = $md.Add(('- Inventory fingerprint: `{0}`' -f $Plan.inventoryFingerprint))
    $null = $md.Add(('- DryRun: {0}' -f $Plan.dryRun))
    $null = $md.Add(('- Modifying DISM commands invoked: **{0}**' -f $Plan.modifyingCommandsInvoked))
    $null = $md.Add(('- Execution authorized: **{0}**' -f $Plan.executionAuthorized))
    $null = $md.Add(('- Approval gate: **{0}** (planning metadata only; not executable)' -f $Plan.approvalGate))
    $null = $md.Add(('- Content hash: `{0}`' -f $Plan.contentHash))
    $null = $md.Add('')
    $null = $md.Add('## Summary')
    $null = $md.Add('')
    $null = $md.Add('| Status | Count |')
    $null = $md.Add('|---|---|')
    foreach ($key in @('Eligible', 'AlreadySatisfied', 'Absent', 'Protected', 'Ambiguous', 'Conflicting', 'Blocked', 'NotEvaluated', 'Total')) {
        $null = $md.Add(('| {0} | {1} |' -f $key, $Plan.summary.$key))
    }
    $null = $md.Add('')
    $null = $md.Add('## Operations')
    $null = $md.Add('')
    $null = $md.Add('| Order | ID | Type | Target | State | Status | Risk | Approval | Reason |')
    $null = $md.Add('|---|---|---|---|---|---|---|---|---|')
    foreach ($op in @($Plan.operations)) {
        $reason = if ($op.skipOrRejectionReason) { $op.skipOrRejectionReason } else { $op.expectedOutcome }
        $null = $md.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} |' -f `
                $op.executionOrder, `
                $op.operationId, `
                $op.operationType, `
                $(if ($op.targetIdentity) { $op.targetIdentity } else { '-' }), `
                $(if ($op.currentState) { $op.currentState } else { '-' }), `
                $op.status, `
                $op.risk, `
                $op.approvalRequired, `
                (($reason -replace '\|', '/') -replace '\r?\n', ' ')))
    }
    $null = $md.Add('')
    $null = $md.Add('## Warnings')
    $null = $md.Add('')
    if (@($Plan.warnings).Count -eq 0) { $null = $md.Add('- None') }
    else { foreach ($w in @($Plan.warnings)) { $null = $md.Add(('- {0}' -f $w)) } }
    $null = $md.Add('')
    $null = $md.Add('## Errors')
    $null = $md.Add('')
    if (@($Plan.errors).Count -eq 0) { $null = $md.Add('- None') }
    else { foreach ($e in @($Plan.errors)) { $null = $md.Add(('- {0}' -f $e)) } }
    $null = $md.Add('')
    $null = $md.Add('## Notes')
    $null = $md.Add('')
    foreach ($n in @($Plan.notes)) { $null = $md.Add(('- {0}' -f $n)) }
    $null = $md.Add('')

    ($md -join $nl) | Set-Content -LiteralPath $mdPath -Encoding UTF8

    return [pscustomobject]@{
        Json     = $jsonPath
        Markdown = $mdPath
        PlanId   = $Plan.planId
    }
}
