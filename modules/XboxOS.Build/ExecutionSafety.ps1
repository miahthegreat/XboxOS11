# Milestone 3 execution safety (non-executing). Dotted into XboxOS.Build.psm1.
# Real DISM mutation backends are unavailable; no enable switch exists.

$script:XboxOSApprovalSchemaVersion = 'approval-v1'
$script:XboxOSDriftSchemaVersion = 'drift-v1'
$script:XboxOSDependencySchemaVersion = 'dependency-v1'
$script:XboxOSTransactionSchemaVersion = 'transaction-v1'
$script:XboxOSExecutionSafetyEngineVersion = '3.0.0'

$script:XboxOSApprovalStates = @(
    'NotRequested', 'Pending', 'Approved', 'Rejected', 'Expired', 'Revoked', 'Invalidated'
)

$script:XboxOSDriftResults = @(
    'Match', 'DriftDetected', 'MissingEvidence', 'IncompatibleSchema', 'ProtectedTarget', 'ValidationError'
)

$script:XboxOSDependencyOutcomes = @(
    'Verified', 'KnownConflict', 'Unknown', 'MissingEvidence', 'Unsupported'
)

$script:XboxOSTransactionStates = @(
    'Created', 'PreflightValidated', 'AwaitingApproval', 'ApprovedForPreparation',
    'WorkspacePrepared', 'WorkingImageValidated', 'ReadyForExecution', 'Executing',
    'VerificationPending', 'CommitPending', 'Completed', 'Aborted', 'RecoveryRequired',
    'Recovered', 'Failed'
)

$script:XboxOSTransactionTransitions = @{
    Created                 = @('PreflightValidated', 'Failed')
    PreflightValidated      = @('AwaitingApproval', 'Failed')
    AwaitingApproval        = @('ApprovedForPreparation', 'Aborted', 'Failed')
    ApprovedForPreparation  = @('WorkspacePrepared', 'RecoveryRequired', 'Failed', 'Aborted')
    WorkspacePrepared       = @('WorkingImageValidated', 'RecoveryRequired', 'Aborted', 'Failed')
    WorkingImageValidated   = @('ReadyForExecution', 'RecoveryRequired', 'Aborted', 'Failed')
    ReadyForExecution       = @('Executing', 'Aborted', 'Failed', 'RecoveryRequired')
    Executing               = @('VerificationPending', 'RecoveryRequired', 'Failed')
    VerificationPending     = @('CommitPending', 'RecoveryRequired', 'Failed')
    CommitPending           = @('Completed', 'RecoveryRequired', 'Failed')
    RecoveryRequired        = @('Recovered', 'Failed')
    Recovered               = @('Aborted', 'Failed')
    Completed               = @()
    Aborted                 = @()
    Failed                  = @()
}

function Get-XboxOSExecutionSafetyEngineVersion {
    [CmdletBinding()]
    param()
    return $script:XboxOSExecutionSafetyEngineVersion
}

function Get-XboxOSApprovalSchemaVersion {
    [CmdletBinding()]
    param()
    return $script:XboxOSApprovalSchemaVersion
}

function Get-XboxOSDriftSchemaVersion {
    [CmdletBinding()]
    param()
    return $script:XboxOSDriftSchemaVersion
}

function Get-XboxOSDependencySchemaVersion {
    [CmdletBinding()]
    param()
    return $script:XboxOSDependencySchemaVersion
}

function Get-XboxOSTransactionSchemaVersion {
    [CmdletBinding()]
    param()
    return $script:XboxOSTransactionSchemaVersion
}

function Get-XboxOSRealDismExecutionEnabled {
    [CmdletBinding()]
    param()
    # Intentionally not parameterized. There is no switch to enable real writable DISM in M3.
    return $false
}

function New-XboxOSAuditEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Data = @{}
    )

    return [pscustomobject]@{
        utc     = [datetime]::UtcNow
        type    = $Type
        message = $Message
        data    = [pscustomobject]$Data
    }
}

function Get-XboxOSApprovalBindingDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string[]]$ApprovedOperationIds,
        [Parameter(Mandatory)][string]$OperatorId,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$IntendedEnvironment,
        [Parameter(Mandatory)][datetime]$ApprovedUtc,
        [Parameter(Mandatory)][datetime]$ExpiresUtc
    )

    $ops = @(
        $Plan.operations |
            Where-Object { $ApprovedOperationIds -contains $_.operationId } |
            Sort-Object operationId |
            ForEach-Object {
                [ordered]@{
                    operationId    = [string]$_.operationId
                    targetIdentity = $(if ($null -ne $_.targetIdentity) { [string]$_.targetIdentity } else { '' })
                    operationType  = [string]$_.operationType
                    status         = [string]$_.status
                }
            }
    )

    $source = [ordered]@{
        isoSha256      = ''
        editionName    = ''
        sourceIndex    = $null
        buildNumber    = ''
        displayVersion = ''
    }
    if ($Plan.sourceImage) {
        foreach ($key in @('isoSha256', 'editionName', 'sourceIndex', 'buildNumber', 'displayVersion')) {
            if ($Plan.sourceImage.PSObject.Properties[$key] -and $null -ne $Plan.sourceImage.$key) {
                $source[$key] = $Plan.sourceImage.$key
            }
        }
    }

    $mf = $Plan.manifestFingerprints
    return [ordered]@{
        approvalSchemaVersion = Get-XboxOSApprovalSchemaVersion
        contentHash           = [string]$Plan.contentHash
        hashSchemaVersion     = [string]$Plan.hashSchemaVersion
        engineVersion         = [string]$Plan.engineVersion
        sourceImage           = $source
        inventoryFingerprint  = [string]$Plan.inventoryFingerprint
        manifestFingerprints  = [ordered]@{
            removeApps      = [string]$mf.removeApps
            disableFeatures = [string]$mf.disableFeatures
            compatibility   = [string]$mf.compatibility
        }
        approvedOperations    = $ops
        operatorId            = [string]$OperatorId
        scope                 = [string]$Scope
        intendedEnvironment   = [string]$IntendedEnvironment
        approvedUtc           = $ApprovedUtc.ToUniversalTime().ToString('o')
        expiresUtc            = $ExpiresUtc.ToUniversalTime().ToString('o')
    }
}

function Get-XboxOSApprovalBindingHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$BindingDocument
    )

    return Get-XboxOSUtf8Sha256Hex -Text (ConvertTo-XboxOSCanonicalJson -Value $BindingDocument)
}

function New-XboxOSApprovalRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string[]]$ApprovedOperationIds,
        [Parameter(Mandatory)][string]$OperatorId,
        [ValidateSet('simulation', 'lab', 'production-forbidden')]
        [string]$Scope = 'simulation',
        [string]$IntendedEnvironment = 'disposable-workspace-simulation',
        [datetime]$ApprovedUtc = [datetime]::UtcNow,
        [datetime]$ExpiresUtc = [datetime]::UtcNow.AddHours(8),
        [ValidateSet('NotRequested', 'Pending', 'Approved', 'Rejected', 'Expired', 'Revoked', 'Invalidated')]
        [string]$State = 'Approved',
        [string]$DecisionNotes = ''
    )

    if ($Scope -eq 'production-forbidden') {
        throw 'Approval scope production-forbidden cannot be issued as an executable approval record.'
    }
    if ($ExpiresUtc -le $ApprovedUtc) {
        throw 'ExpiresUtc must be after ApprovedUtc.'
    }
    if ([string]::IsNullOrWhiteSpace($OperatorId)) {
        throw 'OperatorId is required (non-secret identifier).'
    }
    if ($ApprovedOperationIds.Count -eq 0) {
        throw 'ApprovedOperationIds must contain at least one operationId.'
    }

    $missing = @($ApprovedOperationIds | Where-Object { $id = $_; -not ($Plan.operations | Where-Object operationId -eq $id) })
    if ($missing.Count -gt 0) {
        throw ("Approved operation IDs not present in plan: {0}" -f ($missing -join ', '))
    }

    $binding = Get-XboxOSApprovalBindingDocument `
        -Plan $Plan `
        -ApprovedOperationIds $ApprovedOperationIds `
        -OperatorId $OperatorId `
        -Scope $Scope `
        -IntendedEnvironment $IntendedEnvironment `
        -ApprovedUtc $ApprovedUtc `
        -ExpiresUtc $ExpiresUtc

    $bindingHash = Get-XboxOSApprovalBindingHash -BindingDocument $binding

    return [pscustomobject]@{
        approvalId                 = ('approval-{0}-{1}' -f $ApprovedUtc.ToUniversalTime().ToString('yyyyMMddHHmmssfff'), $bindingHash.Substring(0, 12).ToLowerInvariant())
        approvalSchemaVersion      = Get-XboxOSApprovalSchemaVersion
        state                      = $State
        binding                    = [pscustomobject]$binding
        bindingHash                = $bindingHash
        decisionNotes              = $DecisionNotes
        secretsPresent             = $false
        grantsRealDismExecution    = $false
        realDismExecutionEnabled   = Get-XboxOSRealDismExecutionEnabled
        recordedUtc                = [datetime]::UtcNow
        notes                      = @(
            'Approval records are planning/governance metadata only in Milestone 3.'
            'PendingOperatorApproval on a plan is not an approval record.'
            'This record never enables real DISM mutation.'
        )
    }
}

function Save-XboxOSApprovalRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Approval,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$Stem = 'XboxOS11-approval'
    )

    if ($OutputDirectory -match '(?i)OneDrive') {
        throw "Refusing to write approval records under OneDrive: $OutputDirectory"
    }
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $path = Join-Path $OutputDirectory ($Stem + '.json')
    ($Approval | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Test-XboxOSApprovalValidity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Approval,
        [Parameter(Mandatory)][object]$Plan,
        [datetime]$AsOfUtc = [datetime]::UtcNow
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $state = [string]$Approval.state

    if ($script:XboxOSApprovalStates -notcontains $state) {
        $errors.Add("Unknown approval state '$state'.") | Out-Null
        $state = 'Invalidated'
    }

    if ($Approval.grantsRealDismExecution -eq $true -or $Approval.realDismExecutionEnabled -eq $true) {
        $errors.Add('Approval claims real DISM execution; forbidden in Milestone 3.') | Out-Null
        $state = 'Invalidated'
    }

    if ($Approval.approvalSchemaVersion -ne (Get-XboxOSApprovalSchemaVersion)) {
        $errors.Add('Incompatible approval schema version.') | Out-Null
        $state = 'Invalidated'
    }

    $expectedBinding = Get-XboxOSApprovalBindingDocument `
        -Plan $Plan `
        -ApprovedOperationIds @($Approval.binding.approvedOperations | ForEach-Object { $_.operationId }) `
        -OperatorId ([string]$Approval.binding.operatorId) `
        -Scope ([string]$Approval.binding.scope) `
        -IntendedEnvironment ([string]$Approval.binding.intendedEnvironment) `
        -ApprovedUtc ([datetime]$Approval.binding.approvedUtc) `
        -ExpiresUtc ([datetime]$Approval.binding.expiresUtc)

    $expectedHash = Get-XboxOSApprovalBindingHash -BindingDocument $expectedBinding
    if ($expectedHash -ne [string]$Approval.bindingHash) {
        $errors.Add('Approval bindingHash does not match recomputed binding for the supplied plan.') | Out-Null
        $state = 'Invalidated'
    }

    if ([string]$Approval.binding.contentHash -ne [string]$Plan.contentHash) {
        $errors.Add('Approval contentHash does not match plan contentHash.') | Out-Null
        $state = 'Invalidated'
    }
    if ([string]$Approval.binding.hashSchemaVersion -ne [string]$Plan.hashSchemaVersion) {
        $errors.Add('Approval hashSchemaVersion mismatch.') | Out-Null
        $state = 'Invalidated'
    }
    if ([string]$Approval.binding.engineVersion -ne [string]$Plan.engineVersion) {
        $errors.Add('Approval engineVersion mismatch.') | Out-Null
        $state = 'Invalidated'
    }
    if ([string]$Approval.binding.inventoryFingerprint -ne [string]$Plan.inventoryFingerprint) {
        $errors.Add('Approval inventoryFingerprint mismatch.') | Out-Null
        $state = 'Invalidated'
    }

    foreach ($key in @('removeApps', 'disableFeatures', 'compatibility')) {
        if ([string]$Approval.binding.manifestFingerprints.$key -ne [string]$Plan.manifestFingerprints.$key) {
            $errors.Add("Approval manifest fingerprint mismatch: $key") | Out-Null
            $state = 'Invalidated'
        }
    }

    $expires = [datetime]$Approval.binding.expiresUtc
    if ($state -eq 'Approved' -and $AsOfUtc -gt $expires) {
        $state = 'Expired'
        $errors.Add('Approval has expired.') | Out-Null
    }

    if ($state -eq 'Revoked') {
        $errors.Add('Approval has been revoked.') | Out-Null
    }
    if ($state -eq 'Rejected') {
        $errors.Add('Approval was rejected.') | Out-Null
    }
    if ($state -in @('NotRequested', 'Pending')) {
        $errors.Add("Approval state '$state' does not authorize preparation.") | Out-Null
    }

    $validForSimulation = ($state -eq 'Approved' -and $errors.Count -eq 0)

    return [pscustomobject]@{
        validForSimulation       = $validForSimulation
        effectiveState           = $state
        errors                   = $errors.ToArray()
        grantsRealDismExecution  = $false
        realDismExecutionEnabled = Get-XboxOSRealDismExecutionEnabled
    }
}

function Set-XboxOSApprovalState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Approval,
        [Parameter(Mandatory)]
        [ValidateSet('NotRequested', 'Pending', 'Approved', 'Rejected', 'Expired', 'Revoked', 'Invalidated')]
        [string]$State,
        [string]$Reason = ''
    )

    $Approval.state = $State
    if ($Reason) {
        $Approval.decisionNotes = @($Approval.decisionNotes, $Reason) -join ' | '
    }
    return $Approval
}

function Test-XboxOSInventoryDrift {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object]$FreshInventory,
        [object]$Approval = $null,
        [object]$CompatibilityManifest = $null
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $result = 'Match'

    if ($Plan.hashSchemaVersion -ne (Get-XboxOSPlanHashSchemaVersion) -or
        $Plan.engineVersion -ne (Get-XboxOSServicingPlanEngineVersion)) {
        $result = 'IncompatibleSchema'
        $errors.Add('Plan engine/hash schema is incompatible with this runtime.') | Out-Null
    }

    if (-not $FreshInventory -or [string]::IsNullOrWhiteSpace([string]$FreshInventory.inventoryFingerprint)) {
        return [pscustomobject]@{
            driftSchemaVersion = Get-XboxOSDriftSchemaVersion
            result             = 'MissingEvidence'
            errors             = @('Fresh inventory snapshot or fingerprint is missing.')
            failClosed         = $true
        }
    }

    if ($FreshInventory.verificationStatus -ne 'Authoritative') {
        $result = 'MissingEvidence'
        $errors.Add(("Fresh inventory verificationStatus is '{0}', not Authoritative." -f $FreshInventory.verificationStatus)) | Out-Null
    }

    if ([string]$FreshInventory.inventoryFingerprint -ne [string]$Plan.inventoryFingerprint) {
        if ($result -eq 'Match') { $result = 'DriftDetected' }
        $errors.Add('Inventory fingerprint differs from plan.') | Out-Null
    }

    if ($Plan.sourceImage -and $FreshInventory.sourceImage) {
        foreach ($key in @('editionName', 'sourceIndex', 'buildNumber', 'displayVersion', 'isoSha256')) {
            $planVal = [string]$Plan.sourceImage.$key
            $freshVal = [string]$FreshInventory.sourceImage.$key
            if ($planVal -and $freshVal -and $planVal -ne $freshVal) {
                if ($result -eq 'Match') { $result = 'DriftDetected' }
                $errors.Add("Source image field '$key' drifted: plan='$planVal' fresh='$freshVal'") | Out-Null
            }
        }
    }
    elseif (-not $FreshInventory.sourceImage) {
        if ($result -eq 'Match') { $result = 'MissingEvidence' }
        $errors.Add('Fresh inventory is missing sourceImage metadata.') | Out-Null
    }

    $freshAppx = @($FreshInventory.appxPackages | ForEach-Object { [string]$_ } | Sort-Object)
    $planEligibleAppx = @(
        $Plan.operations |
            Where-Object { $_.operationType -eq 'RemoveProvisionedAppx' -and $_.status -eq 'Eligible' } |
            ForEach-Object { [string]$_.targetIdentity }
    )
    foreach ($target in $planEligibleAppx) {
        if ($target -and $freshAppx -notcontains $target) {
            if ($result -eq 'Match') { $result = 'DriftDetected' }
            $errors.Add("Eligible AppX target missing from fresh inventory: $target") | Out-Null
        }
    }

    $freshFeatures = @{}
    foreach ($f in @($FreshInventory.features)) {
        $freshFeatures[[string]$f.Name] = [string]$f.State
    }
    foreach ($op in @($Plan.operations | Where-Object { $_.operationType -eq 'DisableOptionalFeature' -and $_.status -eq 'Eligible' })) {
        $name = [string]$op.targetIdentity
        if (-not $freshFeatures.ContainsKey($name)) {
            if ($result -eq 'Match') { $result = 'DriftDetected' }
            $errors.Add("Eligible feature target missing from fresh inventory: $name") | Out-Null
        }
        elseif ($freshFeatures[$name] -ne [string]$op.currentState -and $freshFeatures[$name] -ne 'Enabled') {
            if ($result -eq 'Match') { $result = 'DriftDetected' }
            $errors.Add("Feature state drift for '$name': planCurrent='$($op.currentState)' fresh='$($freshFeatures[$name])'") | Out-Null
        }
    }

    if ($CompatibilityManifest) {
        $protectedAppx = @(Get-XboxOSProtectedAppxPatterns -CompatibilityManifest $CompatibilityManifest)
        foreach ($op in @($Plan.operations | Where-Object { $_.status -eq 'Eligible' -and $_.targetKind -eq 'AppX' })) {
            if (Test-XboxOSPackageProtected -PackageName ([string]$op.targetIdentity) -ProtectedPatterns $protectedAppx) {
                $result = 'ProtectedTarget'
                $errors.Add("Protected AppX target in Eligible operation: $($op.targetIdentity)") | Out-Null
            }
        }
        $featurePatterns = @()
        if ($CompatibilityManifest.PSObject.Properties['protectedFeatureNamePatterns'] -and $CompatibilityManifest.protectedFeatureNamePatterns) {
            $featurePatterns = @($CompatibilityManifest.protectedFeatureNamePatterns | ForEach-Object { [string]$_ })
        }
        foreach ($op in @($Plan.operations | Where-Object { $_.status -eq 'Eligible' -and $_.targetKind -eq 'Feature' })) {
            $name = [string]$op.targetIdentity
            $hit = $false
            foreach ($pattern in $featurePatterns) {
                if ($name -like $pattern) { $hit = $true; break }
            }
            if ($hit -or (Test-XboxOSFeatureProtected -FeatureName $name)) {
                $result = 'ProtectedTarget'
                $errors.Add("Protected feature target in Eligible operation: $name") | Out-Null
            }
        }
    }

    if ($Approval) {
        $approvalCheck = Test-XboxOSApprovalValidity -Approval $Approval -Plan $Plan
        if (-not $approvalCheck.validForSimulation) {
            if ($result -eq 'Match') { $result = 'ValidationError' }
            foreach ($e in @($approvalCheck.errors)) { $errors.Add("Approval: $e") | Out-Null }
        }
    }

    if ($result -ne 'Match' -and $script:XboxOSDriftResults -notcontains $result) {
        $result = 'ValidationError'
    }

    return [pscustomobject]@{
        driftSchemaVersion     = $script:XboxOSDriftSchemaVersion
        result                 = $result
        errors                 = $errors.ToArray()
        failClosed             = ($result -ne 'Match')
        planContentHash        = [string]$Plan.contentHash
        freshInventoryFingerprint = [string]$FreshInventory.inventoryFingerprint
        realDismExecutionEnabled  = Get-XboxOSRealDismExecutionEnabled
    }
}

function Test-XboxOSDependencySafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [AllowEmptyCollection()][object[]]$DependencyEvidence = @(),
        [switch]$AllowApprovalOverride
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $eligible = @($Plan.operations | Where-Object status -eq 'Eligible')
    $outcomes = New-Object System.Collections.Generic.List[object]
    $criticalBlock = $false

    if ($AllowApprovalOverride) {
        $errors.Add('AllowApprovalOverride is forbidden; approval cannot override dependency checks.') | Out-Null
        $criticalBlock = $true
    }

    foreach ($op in $eligible) {
        $evidence = @(
            $DependencyEvidence | Where-Object {
                $_.operationId -eq $op.operationId -or $_.targetIdentity -eq $op.targetIdentity
            }
        )

        $outcome = 'Unknown'
        $detail = "No dependency evidence supplied; operation dependencyCompleteness='$($op.dependencyCompleteness)'."

        if ($op.dependencyCompleteness -eq 'Established' -and $evidence.Count -eq 0) {
            $outcome = 'MissingEvidence'
            $detail = 'Operation claims Established completeness without evidence objects.'
            $criticalBlock = $true
        }
        elseif ($evidence.Count -eq 0) {
            if ($op.dependencyCompleteness -eq 'Unverified' -or $op.dependencyCompleteness -eq 'NotApplicable') {
                $outcome = 'Unknown'
                $criticalBlock = $true
            }
            else {
                $outcome = 'MissingEvidence'
                $criticalBlock = $true
            }
        }
        else {
            $conflict = @(
                $evidence | Where-Object {
                    $_.outcome -eq 'KnownConflict' -or
                    ($_.PSObject.Properties['conflict'] -and $_.conflict -eq $true)
                }
            )
            $unsupported = @($evidence | Where-Object { $_.outcome -eq 'Unsupported' })
            $verified = @(
                $evidence | Where-Object {
                    $_.outcome -eq 'Verified' -and
                    $_.PSObject.Properties['evidenceHash'] -and
                    $_.evidenceHash
                }
            )
            if ($conflict.Count -gt 0) {
                $outcome = 'KnownConflict'
                $detail = 'Dependency evidence reports a known conflict.'
                $criticalBlock = $true
            }
            elseif ($unsupported.Count -gt 0 -and $verified.Count -eq 0) {
                $outcome = 'Unsupported'
                $detail = 'Dependency validation unsupported for this target.'
                $criticalBlock = $true
            }
            elseif ($verified.Count -gt 0 -and $verified.Count -eq $evidence.Count) {
                $outcome = 'Verified'
                $detail = 'Supporting evidence hashes present for dependency safety.'
            }
            else {
                $outcome = 'MissingEvidence'
                $detail = 'Partial or incomplete dependency evidence.'
                $criticalBlock = $true
            }
        }

        if ($outcome -ne 'Verified') {
            $warnings.Add(("Operation '{0}' dependency outcome={1}: {2}" -f $op.operationId, $outcome, $detail)) | Out-Null
        }

        $outcomes.Add([pscustomobject]@{
                operationId    = [string]$op.operationId
                targetIdentity = [string]$op.targetIdentity
                outcome        = $outcome
                detail         = $detail
            }) | Out-Null
    }

    $aggregate = if ($eligible.Count -eq 0) {
        'Verified'
    }
    elseif (@($outcomes | Where-Object outcome -eq 'KnownConflict').Count -gt 0) {
        'KnownConflict'
    }
    elseif (@($outcomes | Where-Object outcome -eq 'MissingEvidence').Count -gt 0) {
        'MissingEvidence'
    }
    elseif (@($outcomes | Where-Object outcome -eq 'Unsupported').Count -gt 0) {
        'Unsupported'
    }
    elseif (@($outcomes | Where-Object outcome -eq 'Unknown').Count -gt 0) {
        'Unknown'
    }
    else {
        'Verified'
    }

    return [pscustomobject]@{
        dependencySchemaVersion   = $script:XboxOSDependencySchemaVersion
        aggregateOutcome          = $aggregate
        criticalBlock             = [bool]$criticalBlock
        operations                = $outcomes.ToArray()
        warnings                  = $warnings.ToArray()
        errors                    = $errors.ToArray()
        approvalCannotOverride    = $true
        realDismExecutionEnabled  = Get-XboxOSRealDismExecutionEnabled
        failClosed                = (($aggregate -ne 'Verified') -or ($errors.Count -gt 0) -or $criticalBlock)
    }
}

function New-XboxOSMockServicingBackend {
    [CmdletBinding()]
    param(
        [ValidateSet('Success', 'DismFailure', 'UnmountInterrupted', 'VerificationFailure', 'CommitRejected', 'PreparationInterrupted')]
        [string]$FailureMode = 'Success'
    )

    $ctx = [pscustomobject]@{
        Kind                     = 'mock'
        FailureMode              = $FailureMode
        Steps                    = (New-Object System.Collections.Generic.List[string])
        ModifyingCommandsInvoked = $false
        RealDismExecutionEnabled = $false
        MountOwned               = $false
        SourceIsoModified        = $false
        DiscardAttempts          = 0
    }

    $backend = New-Object psobject
    Add-Member -InputObject $backend -NotePropertyName Ctx -NotePropertyValue $ctx
    Add-Member -InputObject $backend -MemberType ScriptMethod -Name GetState -Value {
        return $this.Ctx
    }
    Add-Member -InputObject $backend -MemberType ScriptMethod -Name PrepareWorkspace -Value {
        param($TransactionId)
        if ($this.Ctx.FailureMode -eq 'PreparationInterrupted') {
            $this.Ctx.Steps.Add('PrepareWorkspace:interrupted') | Out-Null
            throw "Simulated preparation interrupted for $TransactionId"
        }
        $this.Ctx.Steps.Add('PrepareWorkspace') | Out-Null
        return [pscustomobject]@{ workspaceReady = $true; sourceIsoModified = $false }
    }
    Add-Member -InputObject $backend -MemberType ScriptMethod -Name ValidateWorkingImage -Value {
        $this.Ctx.Steps.Add('ValidateWorkingImage') | Out-Null
        $this.Ctx.MountOwned = $true
        return [pscustomobject]@{ validated = $true; mountOwned = $true }
    }
    Add-Member -InputObject $backend -MemberType ScriptMethod -Name ExecuteOperations -Value {
        param($Operations)
        if ($this.Ctx.FailureMode -eq 'DismFailure') {
            $this.Ctx.Steps.Add('ExecuteOperations:dism-failure') | Out-Null
            throw 'Simulated DISM failure'
        }
        $this.Ctx.Steps.Add(('ExecuteOperations:{0}' -f @($Operations).Count)) | Out-Null
        return [pscustomobject]@{ simulated = $true; count = @($Operations).Count }
    }
    Add-Member -InputObject $backend -MemberType ScriptMethod -Name Verify -Value {
        if ($this.Ctx.FailureMode -eq 'VerificationFailure') {
            $this.Ctx.Steps.Add('Verify:failure') | Out-Null
            throw 'Simulated verification failure'
        }
        $this.Ctx.Steps.Add('Verify') | Out-Null
        return [pscustomobject]@{ verified = $true }
    }
    Add-Member -InputObject $backend -MemberType ScriptMethod -Name Commit -Value {
        if ($this.Ctx.FailureMode -eq 'CommitRejected') {
            $this.Ctx.Steps.Add('Commit:rejected') | Out-Null
            throw 'Simulated commit rejection'
        }
        $this.Ctx.Steps.Add('Commit:simulated-only') | Out-Null
        $this.Ctx.ModifyingCommandsInvoked = $false
        $this.Ctx.RealDismExecutionEnabled = $false
        return [pscustomobject]@{ committed = $false; simulatedComplete = $true }
    }
    Add-Member -InputObject $backend -MemberType ScriptMethod -Name Discard -Value {
        $this.Ctx.DiscardAttempts++
        if ($this.Ctx.FailureMode -eq 'UnmountInterrupted' -and $this.Ctx.MountOwned -and $this.Ctx.DiscardAttempts -eq 1) {
            $this.Ctx.Steps.Add('Discard:unmount-interrupted') | Out-Null
            throw 'Simulated interrupted unmount'
        }
        $this.Ctx.Steps.Add('Discard') | Out-Null
        $this.Ctx.MountOwned = $false
        return [pscustomobject]@{ discarded = $true; mountOwned = $false }
    }
    return $backend
}

function New-XboxOSServicingTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [object]$Approval = $null,
        [object]$FreshInventory = $null,
        [object]$CompatibilityManifest = $null,
        [AllowEmptyCollection()][object[]]$DependencyEvidence = @(),
        [object]$Backend = $null
    )

    if (-not $Backend) {
        $Backend = New-XboxOSMockServicingBackend
    }

    $txId = 'tx-{0}' -f [datetime]::UtcNow.ToString('yyyyMMddHHmmssfff')
    return [pscustomobject]@{
        transactionId              = $txId
        transactionSchemaVersion   = $script:XboxOSTransactionSchemaVersion
        state                      = 'Created'
        planContentHash            = [string]$Plan.contentHash
        plan                       = $Plan
        approval                   = $Approval
        freshInventory             = $FreshInventory
        compatibilityManifest      = $CompatibilityManifest
        dependencyEvidence         = @($DependencyEvidence)
        backend                    = $Backend
        audit                      = [System.Collections.ArrayList]@()
        driftResult                = $null
        dependencyResult           = $null
        approvalResult             = $null
        recoveryRecommendation     = $null
        modifyingCommandsInvoked   = $false
        realDismExecutionEnabled   = $false
        executionAuthorized        = $false
        simulatedAuthorizationResult = 'NotEvaluated'
        sourceIsoProtected         = $true
        failureReasons             = [System.Collections.ArrayList]@()
    }
}

function Assert-XboxOSTransactionTransition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Transaction,
        [Parameter(Mandatory)][string]$ToState
    )

    $from = [string]$Transaction.state
    $allowed = @($script:XboxOSTransactionTransitions[$from])
    if ($allowed -notcontains $ToState) {
        throw ("Invalid transaction transition {0} -> {1}" -f $from, $ToState)
    }
}

function Set-XboxOSTransactionState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Transaction,
        [Parameter(Mandatory)]
        [ValidateScript({ $script:XboxOSTransactionStates -contains $_ })]
        [string]$State,
        [string]$Message = ''
    )

    Assert-XboxOSTransactionTransition -Transaction $Transaction -ToState $State
    $from = $Transaction.state
    $Transaction.state = $State
    $null = $Transaction.audit.Add((New-XboxOSAuditEvent -Type 'StateTransition' -Message $(if ($Message) { $Message } else { "$from -> $State" }) -Data @{
                from = $from
                to   = $State
            }))
}

function Invoke-XboxOSTransactionPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Transaction
    )

    try {
        if (-not $Transaction.freshInventory) {
            throw 'Fresh inventory evidence is required for preflight.'
        }

        $Transaction.driftResult = Test-XboxOSInventoryDrift `
            -Plan $Transaction.plan `
            -FreshInventory $Transaction.freshInventory `
            -Approval $Transaction.approval `
            -CompatibilityManifest $Transaction.compatibilityManifest

        $Transaction.dependencyResult = Test-XboxOSDependencySafety `
            -Plan $Transaction.plan `
            -DependencyEvidence $Transaction.dependencyEvidence

        if ($Transaction.driftResult.failClosed) {
            $null = $Transaction.failureReasons.Add(('Drift: {0}' -f $Transaction.driftResult.result))
            foreach ($e in @($Transaction.driftResult.errors)) { $null = $Transaction.failureReasons.Add($e) }
            Set-XboxOSTransactionState -Transaction $Transaction -State Failed -Message 'Preflight failed: drift'
            $Transaction.recoveryRecommendation = 'Abort; regenerate plan from fresh Authoritative inventory.'
            $Transaction.simulatedAuthorizationResult = 'Denied'
            return $Transaction
        }

        if ($Transaction.dependencyResult.failClosed) {
            $null = $Transaction.failureReasons.Add(('Dependency: {0}' -f $Transaction.dependencyResult.aggregateOutcome))
            Set-XboxOSTransactionState -Transaction $Transaction -State Failed -Message 'Preflight failed: dependencies'
            $Transaction.recoveryRecommendation = 'Abort; supply dependency evidence or remove unresolved operations. Approval cannot override.'
            $Transaction.simulatedAuthorizationResult = 'Denied'
            return $Transaction
        }

        Set-XboxOSTransactionState -Transaction $Transaction -State PreflightValidated -Message 'Preflight Match + Verified dependencies'
        Set-XboxOSTransactionState -Transaction $Transaction -State AwaitingApproval -Message 'Awaiting approval-v1 record'
        return $Transaction
    }
    catch {
        $null = $Transaction.failureReasons.Add([string]$_.Exception.Message)
        if ($Transaction.state -eq 'Created') {
            Set-XboxOSTransactionState -Transaction $Transaction -State Failed -Message $_.Exception.Message
        }
        else {
            try {
                Set-XboxOSTransactionState -Transaction $Transaction -State Failed -Message $_.Exception.Message
            }
            catch {
                $Transaction.state = 'Failed'
            }
        }
        $Transaction.simulatedAuthorizationResult = 'Denied'
        $Transaction.recoveryRecommendation = 'Abort; fix validation inputs.'
        return $Transaction
    }
}

function Invoke-XboxOSTransactionApplyApproval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Transaction,
        [Parameter(Mandatory)][object]$Approval
    )

    $Transaction.approval = $Approval
    $Transaction.approvalResult = Test-XboxOSApprovalValidity -Approval $Approval -Plan $Transaction.plan

    if ($Transaction.state -ne 'AwaitingApproval') {
        throw "ApplyApproval requires AwaitingApproval (current=$($Transaction.state))"
    }

    if (-not $Transaction.approvalResult.validForSimulation) {
        foreach ($e in @($Transaction.approvalResult.errors)) { $null = $Transaction.failureReasons.Add($e) }
        if ($Transaction.approvalResult.effectiveState -eq 'Expired') {
            Set-XboxOSTransactionState -Transaction $Transaction -State Failed -Message 'Approval expired'
            $Transaction.recoveryRecommendation = 'Abort; issue a new approval bound to the current contentHash.'
        }
        else {
            Set-XboxOSTransactionState -Transaction $Transaction -State Aborted -Message 'Approval not valid'
            $Transaction.recoveryRecommendation = 'Abort; record a valid approval-v1 or reject the plan.'
        }
        $Transaction.simulatedAuthorizationResult = 'Denied'
        return $Transaction
    }

    # Simulated authorization only — never real DISM permission.
    $Transaction.simulatedAuthorizationResult = 'SimulatedApprovedForPreparation'
    $Transaction.executionAuthorized = $false
    Set-XboxOSTransactionState -Transaction $Transaction -State ApprovedForPreparation -Message 'approval-v1 valid for simulation only'
    return $Transaction
}

function Invoke-XboxOSTransactionSimulate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Transaction,
        [switch]$StopBeforeExecution
    )

    if ($Transaction.state -ne 'ApprovedForPreparation') {
        throw "Simulate requires ApprovedForPreparation (current=$($Transaction.state))"
    }

    $backend = $Transaction.backend
    try {
        $null = $backend.PrepareWorkspace($Transaction.transactionId)
        Set-XboxOSTransactionState -Transaction $Transaction -State WorkspacePrepared -Message 'Simulated workspace prepared; source ISO unmodified'

        $null = $backend.ValidateWorkingImage()
        Set-XboxOSTransactionState -Transaction $Transaction -State WorkingImageValidated -Message 'Simulated working image validated'
        Set-XboxOSTransactionState -Transaction $Transaction -State ReadyForExecution -Message 'Ready for simulated execution only'

        if ($StopBeforeExecution) {
            return $Transaction
        }

        $eligible = @($Transaction.plan.operations | Where-Object status -eq 'Eligible')
        Set-XboxOSTransactionState -Transaction $Transaction -State Executing -Message 'Mock backend executing'
        $null = $backend.ExecuteOperations($eligible)
        Set-XboxOSTransactionState -Transaction $Transaction -State VerificationPending -Message 'Simulated execution finished'

        $null = $backend.Verify()
        Set-XboxOSTransactionState -Transaction $Transaction -State CommitPending -Message 'Verification passed; real commit disabled'

        $commit = $backend.Commit()
        $Transaction.modifyingCommandsInvoked = $false
        $Transaction.realDismExecutionEnabled = $false
        $Transaction.executionAuthorized = $false
        Set-XboxOSTransactionState -Transaction $Transaction -State Completed -Message 'Simulated completion (no real DISM commit)'
        $null = $Transaction.audit.Add((New-XboxOSAuditEvent -Type 'SimulatedCommit' -Message 'Commit simulated only' -Data @{
                    committed                = [bool]$commit.committed
                    modifyingCommandsInvoked = $false
                }))
        return $Transaction
    }
    catch {
        $msg = [string]$_.Exception.Message
        $null = $Transaction.failureReasons.Add($msg)
        $Transaction.executionAuthorized = $false
        $Transaction.modifyingCommandsInvoked = $false
        $Transaction.simulatedAuthorizationResult = 'Denied'

        if ($msg -match 'preparation interrupted') {
            $Transaction.recoveryRecommendation = 'Discard workspace; restart from Created.'
        }
        elseif ($msg -match 'DISM failure') {
            $Transaction.recoveryRecommendation = 'Discard mount; do not commit; RecoveryRequired.'
        }
        elseif ($msg -match 'verification failure') {
            $Transaction.recoveryRecommendation = 'Discard; do not commit; regenerate verification evidence.'
        }
        elseif ($msg -match 'commit rejection') {
            $Transaction.recoveryRecommendation = 'Remain non-committed; discard working image.'
        }
        else {
            $Transaction.recoveryRecommendation = 'Discard workspace; manual review; fresh plan if inventory changed.'
        }

        try {
            if ($Transaction.state -in @('ApprovedForPreparation', 'WorkspacePrepared', 'WorkingImageValidated', 'ReadyForExecution', 'Executing', 'VerificationPending', 'CommitPending')) {
                Set-XboxOSTransactionState -Transaction $Transaction -State RecoveryRequired -Message $msg
            }
        }
        catch {
            $Transaction.state = 'RecoveryRequired'
        }
        return $Transaction
    }
}

function Invoke-XboxOSTransactionRecover {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Transaction,
        [switch]$RetryDiscard
    )

    if ($Transaction.state -ne 'RecoveryRequired') {
        throw "Recover requires RecoveryRequired (current=$($Transaction.state))"
    }

    try {
        $null = $Transaction.backend.Discard()
        $Transaction.modifyingCommandsInvoked = $false
        Set-XboxOSTransactionState -Transaction $Transaction -State Recovered -Message 'Simulated discard completed'
        Set-XboxOSTransactionState -Transaction $Transaction -State Aborted -Message 'Recovered via discard; no commit'
        return $Transaction
    }
    catch {
        $null = $Transaction.failureReasons.Add([string]$_.Exception.Message)
        if ($_.Exception.Message -match 'interrupted unmount') {
            $Transaction.recoveryRecommendation = 'Manual intervention: verify mock mount cleared; rerun discard.'
            if ($RetryDiscard) {
                $null = $Transaction.backend.Discard()
                $Transaction.modifyingCommandsInvoked = $false
                Set-XboxOSTransactionState -Transaction $Transaction -State Recovered -Message 'Discard succeeded on retry'
                Set-XboxOSTransactionState -Transaction $Transaction -State Aborted -Message 'Recovered via discard retry; no commit'
                return $Transaction
            }
            return $Transaction
        }
        Set-XboxOSTransactionState -Transaction $Transaction -State Failed -Message $_.Exception.Message
        return $Transaction
    }
}

function Save-XboxOSExecutionSafetyReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Transaction,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$Stem = 'XboxOS11-execution-safety'
    )

    if ($OutputDirectory -match '(?i)OneDrive') {
        throw "Refusing to write execution safety reports under OneDrive: $OutputDirectory"
    }

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $jsonPath = Join-Path $OutputDirectory ($Stem + '.json')
    $mdPath = Join-Path $OutputDirectory ($Stem + '.md')

    $approvalState = 'NotRequested'
    if ($null -ne $Transaction.PSObject.Properties['approval'] -and $null -ne $Transaction.approval) {
        $approvalState = [string]$Transaction.approval.state
    }

    $auditEvents = @(
        foreach ($evt in @($Transaction.audit)) {
            [pscustomobject]@{
                utc     = $evt.utc
                type    = [string]$evt.type
                message = [string]$evt.message
            }
        }
    )

    $report = [ordered]@{
        reportType                   = 'execution-safety'
        generatedUtc                 = [datetime]::UtcNow
        executionSafetyEngineVersion = Get-XboxOSExecutionSafetyEngineVersion
        transactionId                = [string]$Transaction.transactionId
        transactionState             = [string]$Transaction.state
        planId                       = [string]$Transaction.plan.planId
        planContentHash              = [string]$Transaction.planContentHash
        hashSchemaVersion            = [string]$Transaction.plan.hashSchemaVersion
        engineVersion                = [string]$Transaction.plan.engineVersion
        approvalSchemaVersion        = Get-XboxOSApprovalSchemaVersion
        approvalState                = $approvalState
        approvalValidity             = $Transaction.approvalResult
        inventoryDrift               = $Transaction.driftResult
        dependencyValidation         = $Transaction.dependencyResult
        sourceImage                  = $Transaction.plan.sourceImage
        inventoryFingerprint         = [string]$Transaction.plan.inventoryFingerprint
        failureReasons               = @($Transaction.failureReasons | ForEach-Object { [string]$_ })
        recoveryRecommendation       = $(if ($null -ne $Transaction.recoveryRecommendation) { [string]$Transaction.recoveryRecommendation } else { $null })
        audit                        = $auditEvents
        modifyingCommandsInvoked     = [bool]$Transaction.modifyingCommandsInvoked
        realDismExecutionEnabled     = [bool](Get-XboxOSRealDismExecutionEnabled)
        executionAuthorized          = [bool]$Transaction.executionAuthorized
        simulatedAuthorizationResult = [string]$Transaction.simulatedAuthorizationResult
        sourceIsoProtected           = [bool]$Transaction.sourceIsoProtected
        notes                        = @(
            'Milestone 3 safety report. Simulated authorization is not permission to run real DISM.'
            'modifyingCommandsInvoked must remain False.'
            'realDismExecutionEnabled must remain False.'
        )
    }

    ([pscustomobject]$report | ConvertTo-Json -Depth 14) | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $nl = [Environment]::NewLine
    $md = New-Object System.Collections.Generic.List[string]
    $null = $md.Add('# XboxOS11 Execution Safety Report (Milestone 3)')
    $null = $md.Add('')
    $null = $md.Add(('- Transaction: `{0}`' -f $report.transactionId))
    $null = $md.Add(('- State: **{0}**' -f $report.transactionState))
    $null = $md.Add(('- Plan content hash: `{0}`' -f $report.planContentHash))
    $null = $md.Add(('- Approval state: **{0}**' -f $report['approvalState']))
    $driftLabel = if ($null -ne $report['inventoryDrift']) { $report['inventoryDrift'].result } else { 'n/a' }
    $depLabel = if ($null -ne $report['dependencyValidation']) { $report['dependencyValidation'].aggregateOutcome } else { 'n/a' }
    $null = $md.Add(('- Drift result: **{0}**' -f $driftLabel))
    $null = $md.Add(('- Dependency outcome: **{0}**' -f $depLabel))
    $null = $md.Add(('- Simulated authorization: **{0}**' -f $report['simulatedAuthorizationResult']))
    $null = $md.Add(('- Execution authorized (real): **{0}**' -f $report['executionAuthorized']))
    $null = $md.Add(('- Modifying commands invoked: **{0}**' -f $report['modifyingCommandsInvoked']))
    $null = $md.Add(('- Real DISM execution enabled: **{0}**' -f $report['realDismExecutionEnabled']))
    $null = $md.Add(('- Source ISO protected: **{0}**' -f $report['sourceIsoProtected']))
    $null = $md.Add('')
    $null = $md.Add('## Failure reasons')
    $null = $md.Add('')
    if (@($report['failureReasons']).Count -eq 0) {
        $null = $md.Add('_None_')
    }
    else {
        foreach ($r in @($report['failureReasons'])) { $null = $md.Add(('- {0}' -f $r)) }
    }
    $null = $md.Add('')
    $null = $md.Add('## Recovery recommendation')
    $null = $md.Add('')
    $null = $md.Add($(if ($report['recoveryRecommendation']) { $report['recoveryRecommendation'] } else { '_None_' }))
    $null = $md.Add('')
    $null = $md.Add('## Audit')
    $null = $md.Add('')
    foreach ($evt in @($report['audit'])) {
        $null = $md.Add(('- `{0}` {1}: {2}' -f $evt.utc, $evt.type, $evt.message))
    }

    ($md -join $nl) + $nl | Set-Content -LiteralPath $mdPath -Encoding UTF8

    return [pscustomobject]@{
        Json     = $jsonPath
        Markdown = $mdPath
        Report   = [pscustomobject]$report
    }
}
