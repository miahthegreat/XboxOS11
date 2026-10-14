# Milestone 2 servicing plan engine (plan-only; no modifying DISM).
# Dotted into XboxOS.Build.psm1.

$script:XboxOSServicingPlanEngineVersion = '2.0.0'

function Get-XboxOSServicingPlanEngineVersion {
    [CmdletBinding()]
    param()
    return $script:XboxOSServicingPlanEngineVersion
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

        [nullable[datetime]]$CapturedUtc = $null,

        [AllowEmptyCollection()]
        [string[]]$Notes = @()
    )

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

    return [pscustomobject]@{
        source               = $Source
        capturedUtc          = $CapturedUtc
        appxAvailability     = $AppxAvailability
        featureAvailability  = $FeatureAvailability
        appxPackages         = [string[]]@($AppxPackages | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        features             = $normalizedFeatures
        packages             = @($Packages)
        notes                = @($Notes)
    }
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
    $appxNames = @()
    $features = @()
    $packages = @()
    $notes = New-Object System.Collections.Generic.List[string]

    if ($report.PSObject.Properties['appxPackages'] -and $report.appxPackages) {
        $raw = @($report.appxPackages)
        if ($raw.Count -gt 0 -and $raw[0] -is [string]) {
            $appxNames = [string[]]$raw
        }
        else {
            $appxNames = [string[]]@($raw | ForEach-Object {
                    if ($_ -is [string]) { $_ }
                    elseif ($_.PSObject.Properties['PackageName']) { [string]$_.PackageName }
                })
        }
    }

    if ($appxNames.Count -eq 0) {
        $appxCmd = @($report.commands | Where-Object { $_.Step -eq 'Get-ProvisionedAppxPackages' } | Select-Object -First 1)
        if ($appxCmd.Count -eq 1) {
            $appxNames = [string[]]@(
                ConvertFrom-XboxOSDismProvisionedAppxListOutput -Output @($appxCmd[0].Output) |
                    ForEach-Object { $_.PackageName }
            )
            $notes.Add('AppX inventory reconstructed from Get-ProvisionedAppxPackages command output.') | Out-Null
        }
    }

    if ($report.PSObject.Properties['features'] -and $report.features) {
        $features = @(
            foreach ($feature in @($report.features)) {
                if ($feature -is [string]) {
                    [pscustomobject]@{ Name = $feature; State = $null }
                }
                else {
                    [pscustomobject]@{
                        Name  = [string]$feature.Name
                        State = $(if ($feature.PSObject.Properties['State']) { [string]$feature.State } else { $null })
                    }
                }
            }
        )
    }

    $needsFeatureRebuild = ($features.Count -eq 0)
    if (-not $needsFeatureRebuild) {
        $withState = @($features | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.State) }).Count
        if ($withState -eq 0) { $needsFeatureRebuild = $true }
    }
    if ($needsFeatureRebuild) {
        $featCmd = @($report.commands | Where-Object { $_.Step -eq 'Get-Features' } | Select-Object -First 1)
        if ($featCmd.Count -eq 1) {
            $features = @(ConvertFrom-XboxOSDismFeatureListOutput -Output @($featCmd[0].Output))
            $notes.Add('Feature inventory reconstructed from Get-Features command output.') | Out-Null
        }
    }

    $pkgCmd = @($report.commands | Where-Object { $_.Step -eq 'Get-Packages' } | Select-Object -First 1)
    if ($pkgCmd.Count -eq 1) {
        $packages = @(ConvertFrom-XboxOSDismPackageListOutput -Output @($pkgCmd[0].Output))
    }

    $appxAvailability = if ($appxNames.Count -gt 0) { 'Available' } else { 'Unknown' }
    $featureAvailability = if ($features.Count -gt 0) { 'Available' } else { 'Unknown' }

    if ($appxAvailability -eq 'Unknown') {
        $notes.Add('AppX inventory could not be reconstructed; plan will fail closed.') | Out-Null
    }
    if ($featureAvailability -eq 'Unknown') {
        $notes.Add('Feature inventory could not be reconstructed; plan will fail closed.') | Out-Null
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
        -Notes $notes.ToArray()
}

function Get-XboxOSCanonicalPlanPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Operations
    )

    $rows = @(
        $Operations | Sort-Object operationId | ForEach-Object {
            [ordered]@{
                operationId     = [string]$_.operationId
                operationType   = [string]$_.operationType
                targetIdentity  = [string]$_.targetIdentity
                status          = [string]$_.status
                proposedAction  = [string]$_.proposedAction
                executionOrder  = [int]$_.executionOrder
                approvalRequired = [bool]$_.approvalRequired
            }
        }
    )
    return ($rows | ConvertTo-Json -Compress -Depth 6)
}

function Get-XboxOSPlanContentHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CanonicalPayload
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($CanonicalPayload)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }
    return ([System.BitConverter]::ToString($hash) -replace '-', '')
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
        [bool]$ApprovalRequired = $false
    )

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
    $appxCanEvaluate = $appxState -in @('Empty', 'Available')
    $featureCanEvaluate = $featureState -in @('Empty', 'Available')

    if (-not $appxCanEvaluate) {
        $errors.Add('AppX inventory availability is Unknown or incomplete; fail closed.') | Out-Null
    }
    if (-not $featureCanEvaluate) {
        $errors.Add('Feature inventory availability is Unknown or incomplete; fail closed.') | Out-Null
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

                $depNote = 'Dependency completeness not proven by presence alone; operator must review Store/Xbox impact before approval.'
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
                        -ExpectedOutcome 'Provisioned AppX removed from disposable WIM after separate approval.' `
                        -SkipOrRejectionReason '' `
                        -ApprovalRequired:$true)) | Out-Null
                $warnings.Add("Eligible AppX removal planned for exact identity '$identity' (candidate '$ruleId'); approval required; not authorized to execute.") | Out-Null
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
                        -Dependencies @('Feature dependency graph not fully modeled; missing dependency info recorded explicitly.') `
                        -ExecutionOrder ($featureOrder++) `
                        -Risk 'Medium' `
                        -ExpectedOutcome 'Feature disabled with payload retained (removePayload=false) after separate approval.' `
                        -SkipOrRejectionReason '' `
                        -ApprovalRequired:$true)) | Out-Null
                $warnings.Add("Eligible feature disable planned for '$identity' (candidate '$ruleId'); approval required; not authorized to execute.") | Out-Null
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

    $hasBlocking = ($summary.Ambiguous -gt 0 -or $summary.Conflicting -gt 0 -or $summary.NotEvaluated -gt 0 -or $errors.Count -gt 0 -or -not $appxCanEvaluate -or -not $featureCanEvaluate)
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

    $canonical = Get-XboxOSCanonicalPlanPayload -Operations $ordered
    $contentHash = Get-XboxOSPlanContentHash -CanonicalPayload $canonical
    $generatedUtc = [datetime]::UtcNow
    $planId = 'plan-{0}-{1}' -f $generatedUtc.ToString('yyyyMMddHHmmss'), $contentHash.Substring(0, 12).ToLowerInvariant()

    return [pscustomobject]@{
        planId                     = $planId
        engineVersion              = Get-XboxOSServicingPlanEngineVersion
        generatedUtc               = $generatedUtc
        dryRun                     = $true
        modifyingCommandsInvoked   = $false
        inventorySource            = [string]$Inventory.source
        inventoryAvailability      = [pscustomobject]@{
            appx     = $appxState
            features = $featureState
        }
        approvalGate               = $approvalGate
        summary                    = [pscustomobject]$summary
        operations                 = $ordered
        warnings                   = @($warnings)
        errors                     = @($errors)
        contentHash                = $contentHash
        contractsDoc               = 'docs/m2-servicing-plan-contracts.md'
        recoveryDoc                = 'docs/m2-operation-ordering-and-recovery.md'
        notes                      = @(
            'Plan generation never invokes modifying DISM commands.'
            'Milestone 1 compatibility-matrix Eligible is not execution permission.'
            'Writable servicing remains unauthorized until a future approval gate is satisfied.'
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
    $null = $md.Add(('- Generated (UTC): {0}' -f $Plan.generatedUtc))
    $null = $md.Add(('- Inventory source: `{0}`' -f $Plan.inventorySource))
    $null = $md.Add(('- DryRun: {0}' -f $Plan.dryRun))
    $null = $md.Add(('- Modifying DISM commands invoked: **{0}**' -f $Plan.modifyingCommandsInvoked))
    $null = $md.Add(('- Approval gate: **{0}**' -f $Plan.approvalGate))
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
