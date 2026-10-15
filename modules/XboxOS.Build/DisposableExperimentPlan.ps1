# Milestone 6A — Disposable-image experiment planning and authorization simulation.
# Analysis / simulation only. No writable DISM. No WIM create/mount.

$script:XboxOSExperimentPlanEngineVersion = '6.0.0-a'
$script:XboxOSExperimentPlanSchemaVersion = 'experiment-plan-v1'
$script:XboxOSExperimentAllowlistSchemaVersion = 'experiment-allowlist-v1'
$script:XboxOSExperimentAuthLayerSchemaVersion = 'experiment-auth-layer-v1'
$script:XboxOSExperimentSnapshotSchemaVersion = 'experiment-snapshot-v1'
$script:XboxOSExperimentTransactionSchemaVersion = 'experiment-transaction-v1'
$script:XboxOSFunctionalValidationSchemaVersion = 'functional-validation-v1'
$script:XboxOSExperimentPlanHashSchemaVersion = 'experiment-plan-hash-v1'

$script:XboxOSExperimentTransactionStates = @(
    'Planned',
    'AwaitingOperatorReview',
    'ReviewRecorded',
    'RiskAcceptanceRequired',
    'BlockedForExecution',
    'ExperimentPrepared',
    'Aborted',
    'RecoveryRequired',
    # Named only so fail-closed tests can assert they are unreachable:
    'LiveMutation',
    'ExecutingMutation',
    'WritableExecution'
)

# Allowed edges only. No writable-execution state exists in 6A.
$script:XboxOSExperimentTransactionTransitions = @{
    'Planned'                 = @('AwaitingOperatorReview', 'BlockedForExecution', 'Aborted')
    'AwaitingOperatorReview'  = @('ReviewRecorded', 'BlockedForExecution', 'Aborted')
    'ReviewRecorded'          = @('RiskAcceptanceRequired', 'BlockedForExecution', 'ExperimentPrepared', 'Aborted')
    'RiskAcceptanceRequired'  = @('BlockedForExecution', 'ExperimentPrepared', 'Aborted', 'RecoveryRequired')
    'ExperimentPrepared'      = @('BlockedForExecution', 'Aborted', 'RecoveryRequired')
    'BlockedForExecution'     = @('RecoveryRequired')
    'Aborted'                 = @('RecoveryRequired')
    'RecoveryRequired'        = @()
}

$script:XboxOSExperimentAuthLayers = @(
    'ExperimentPlanning',
    'OperatorReviewConsent',
    'ExperimentalRiskAcceptance',
    'ExecutionAuthorization',
    'FunctionalValidation'
)

$script:XboxOSExperimentSupportedOperationTypes = @(
    'RemoveProvisionedAppx',
    'DisableOptionalFeature'
)

$script:XboxOSExperimentUsedNonces = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

function Get-XboxOSExperimentPlanEngineVersion { return $script:XboxOSExperimentPlanEngineVersion }
function Get-XboxOSExperimentPlanSchemaVersion { return $script:XboxOSExperimentPlanSchemaVersion }
function Get-XboxOSExperimentAllowlistSchemaVersion { return $script:XboxOSExperimentAllowlistSchemaVersion }
function Get-XboxOSExperimentAuthLayerSchemaVersion { return $script:XboxOSExperimentAuthLayerSchemaVersion }
function Get-XboxOSExperimentSnapshotSchemaVersion { return $script:XboxOSExperimentSnapshotSchemaVersion }
function Get-XboxOSExperimentTransactionSchemaVersion { return $script:XboxOSExperimentTransactionSchemaVersion }
function Get-XboxOSFunctionalValidationSchemaVersion { return $script:XboxOSFunctionalValidationSchemaVersion }
function Get-XboxOSExperimentPlanHashSchemaVersion { return $script:XboxOSExperimentPlanHashSchemaVersion }

function Get-XboxOSExperimentalMutationEnabled { return $false }
function Get-XboxOSExperimentalExecutionAuthorized { return $false }

function Assert-XboxOSExperimentSafetyInvariants {
    [CmdletBinding()]
    param([object]$Report = $null)

    if (Get-XboxOSRealDismExecutionEnabled) {
        throw 'Safety invariant violated: realDismExecutionEnabled must be False.'
    }
    if (Get-XboxOSExperimentalMutationEnabled) {
        throw 'Safety invariant violated: experimentalMutationEnabled must be False.'
    }
    if (Get-XboxOSExperimentalExecutionAuthorized) {
        throw 'Safety invariant violated: experimentalExecutionAuthorized must be False.'
    }
    if ($null -eq $Report) { return }

    foreach ($flag in @(
            'realDismExecutionEnabled',
            'modifyingCommandsInvoked',
            'executionAuthorized',
            'servicingAuthorized',
            'experimentalMutationEnabled',
            'experimentalExecutionAuthorized'
        )) {
        if ($Report.PSObject.Properties[$flag] -and $Report.$flag) {
            throw ("Safety invariant violated: {0} must be False." -f $flag)
        }
    }
}

function Import-XboxOSFunctionalValidationCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Functional validation catalog not found: $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$raw.schemaVersion -ne (Get-XboxOSFunctionalValidationSchemaVersion)) {
        throw ("Functional validation schema mismatch: expected {0}, got {1}" -f (Get-XboxOSFunctionalValidationSchemaVersion), $raw.schemaVersion)
    }
    if (-not $raw.tests -or @($raw.tests).Count -eq 0) {
        throw 'Functional validation catalog contains no tests.'
    }
    $ids = @{}
    foreach ($t in @($raw.tests)) {
        if ([string]::IsNullOrWhiteSpace([string]$t.testId)) {
            throw 'Functional validation test missing testId.'
        }
        if ($ids.ContainsKey([string]$t.testId)) {
            throw ("Duplicate functional validation testId: {0}" -f $t.testId)
        }
        $ids[[string]$t.testId] = $true
        foreach ($req in @('capabilityId', 'executionEnvironment', 'expectedResult', 'failureSeverity', 'abortBehavior', 'recoveryExpectations')) {
            if (-not $t.PSObject.Properties[$req] -or [string]::IsNullOrWhiteSpace([string]$t.$req)) {
                throw ("Functional validation test '{0}' missing required field '{1}'." -f $t.testId, $req)
            }
        }
    }
    return $raw
}

function Test-XboxOSExperimentWorkspaceConstraints {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProposedWorkspaceRoot,
        [Parameter(Mandatory)][string]$SourceIsoPath,
        [string]$HostOsImagePath = $null,
        [string]$OwnerId = 'sim-operator',
        [switch]$AllowOneDrive
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    if ([string]::IsNullOrWhiteSpace($ProposedWorkspaceRoot)) {
        [void]$errors.Add('ProposedWorkspaceRoot is required.')
    }
    else {
        if ($ProposedWorkspaceRoot -match '\.\.') {
            [void]$errors.Add('Workspace path traversal (.. ) is forbidden.')
        }
        if (-not $AllowOneDrive -and ($ProposedWorkspaceRoot -match '(?i)OneDrive')) {
            [void]$errors.Add('Workspace must be outside OneDrive.')
        }
        if ($ProposedWorkspaceRoot -match '(?i)\\Windows\\|\\Windows$') {
            [void]$errors.Add('Workspace must not target host Windows directories.')
        }
    }

    if ([string]::IsNullOrWhiteSpace($SourceIsoPath)) {
        [void]$errors.Add('SourceIsoPath is required.')
    }
    elseif ($SourceIsoPath -match '\.\.') {
        [void]$errors.Add('Source ISO path traversal is forbidden.')
    }

    if ($HostOsImagePath) {
        [void]$errors.Add('Host operating-system image targets are forbidden.')
    }

    # Simulation-only ownership token (no filesystem create/mount).
    $ownedWim = if ($ProposedWorkspaceRoot) { Join-Path $ProposedWorkspaceRoot 'install-pro-disposable.wim' } else { '' }
    $ownedMount = if ($ProposedWorkspaceRoot) { Join-Path $ProposedWorkspaceRoot 'mount' } else { '' }
    $tokenMaterial = '{0}|{1}|{2}' -f $OwnerId, $ProposedWorkspaceRoot, $ownedWim
    $ownershipToken = Get-XboxOSUtf8Sha256Hex -Text $tokenMaterial

    $valid = [bool]($errors.Count -eq 0)
    return [pscustomobject]@{
        schemaVersion              = 'experiment-workspace-constraints-v1'
        valid                      = $valid
        errors                     = [string[]]@($errors.ToArray())
        warnings                   = [string[]]@($warnings.ToArray())
        sourceIsoImmutable         = $true
        workspaceOutsideOneDrive   = -not ($ProposedWorkspaceRoot -match '(?i)OneDrive')
        ownedWorkspaceIdentity     = $ownershipToken
        ownedWimPath               = $ownedWim
        ownedMountPath             = $ownedMount
        hostOsImageTargetForbidden = $true
        productionMediaModificationForbidden = $true
        arbitraryPathsForbidden    = $true
        globalDismCleanupForbidden = $true
        staleMountOwnershipForbidden = $true
        untrackedHiveOwnershipForbidden = $true
        filesystemMutationPerformed = $false
        notes                      = @(
            'Constraint evaluation only. Milestone 6A does not create or mount a WIM.'
            'Source ISO is treated as immutable; production installation media must not be modified.'
        )
    }
}

function Test-XboxOSExperimentOperationAllowlist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object]$ReadinessAssessment,
        [Parameter(Mandatory)][string[]]$RequestedOperationIds,
        [string]$ExpectedInventoryFingerprint = $null,
        [string]$ExpectedPlanContentHash = $null,
        [string]$ExpectedIsoSha256 = $null
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $selected = New-Object System.Collections.Generic.List[object]

    if ($null -eq $RequestedOperationIds -or @($RequestedOperationIds).Count -eq 0) {
        [void]$errors.Add('Deny-by-default: RequestedOperationIds must be non-empty for selection evaluation.')
    }

    if ($RequestedOperationIds | Where-Object { $_ -match '[\*\?]' }) {
        [void]$errors.Add('Wildcard-only approvals are rejected.')
    }

    $planFp = [string]$Plan.inventoryFingerprint
    $planHash = [string]$Plan.contentHash
    $readyFp = [string]$ReadinessAssessment.inventoryFingerprint
    $readyHash = [string]$ReadinessAssessment.planContentHash

    if ($planFp -ne $readyFp) {
        [void]$errors.Add('Plan inventoryFingerprint does not match readiness report inventoryFingerprint.')
    }
    if ($planHash -ne $readyHash) {
        [void]$errors.Add('Plan contentHash does not match readiness report planContentHash.')
    }
    if ($ExpectedInventoryFingerprint -and $ExpectedInventoryFingerprint -ne $planFp) {
        [void]$errors.Add('Expected inventory fingerprint mismatch.')
    }
    if ($ExpectedPlanContentHash -and $ExpectedPlanContentHash -ne $planHash) {
        [void]$errors.Add('Expected plan content hash mismatch.')
    }
    if ($ExpectedIsoSha256) {
        $iso = ''
        if ($Plan.sourceImage -and $Plan.sourceImage.PSObject.Properties['isoSha256']) {
            $iso = [string]$Plan.sourceImage.isoSha256
        }
        if ($iso -ne $ExpectedIsoSha256) {
            [void]$errors.Add('Source ISO identity mismatch.')
        }
    }

    $edition = ''
    $build = ''
    if ($Plan.sourceImage) {
        if ($Plan.sourceImage.PSObject.Properties['editionName']) { $edition = [string]$Plan.sourceImage.editionName }
        if ($Plan.sourceImage.PSObject.Properties['buildNumber']) { $build = [string]$Plan.sourceImage.buildNumber }
    }
    if ([string]::IsNullOrWhiteSpace($edition) -or [string]::IsNullOrWhiteSpace($build)) {
        [void]$errors.Add('Unrecognized Windows image identity: edition/build missing.')
    }

    $planOps = @{}
    foreach ($op in @($Plan.operations)) {
        $planOps[[string]$op.operationId] = $op
    }
    $readyOps = @{}
    foreach ($a in @($ReadinessAssessment.operationAssessments)) {
        $readyOps[[string]$a.operationId] = $a
    }

    foreach ($id in @($RequestedOperationIds | Select-Object -Unique)) {
        if (-not $planOps.ContainsKey($id)) {
            [void]$errors.Add(("Unknown operation not present in bound M2 plan: {0}" -f $id))
            continue
        }
        $op = $planOps[$id]
        $target = if ($null -ne $op.targetIdentity) { [string]$op.targetIdentity } else { '' }
        if ([string]::IsNullOrWhiteSpace($target)) {
            [void]$errors.Add(("Ambiguous identity for operation {0}." -f $id))
            continue
        }
        if ($script:XboxOSExperimentSupportedOperationTypes -notcontains [string]$op.operationType) {
            [void]$errors.Add(("Unsupported operation type '{0}' for {1}." -f $op.operationType, $id))
            continue
        }
        if ([string]$op.status -eq 'Protected') {
            [void]$errors.Add(("Protected component rejected: {0}" -f $id))
            continue
        }
        if (-not $readyOps.ContainsKey($id)) {
            [void]$errors.Add(("Operation absent from bound readiness report: {0}" -f $id))
            continue
        }
        $ra = $readyOps[$id]
        $readyTarget = if ($ra.PSObject.Properties['targetIdentity']) { [string]$ra.targetIdentity } else { '' }
        if ($readyTarget -ne $target) {
            [void]$errors.Add(("Target identity mismatch for {0}: plan='{1}' readiness='{2}'." -f $id, $target, $readyTarget))
            continue
        }

        [void]$selected.Add([pscustomobject]@{
                operationId                 = [string]$op.operationId
                targetIdentity              = $target
                operationType               = [string]$op.operationType
                planStatus                  = [string]$op.status
                catalogCandidateReadiness   = $(if ($ra.PSObject.Properties['catalogCandidateReadiness']) { [string]$ra.catalogCandidateReadiness } else { '' })
                effectiveReadiness          = $(if ($ra.PSObject.Properties['readiness']) { [string]$ra.readiness } else { '' })
                dependencyClosureCompleteness = $(
                    if ($ra.PSObject.Properties['dependencyClosure'] -and $ra.dependencyClosure -and $ra.dependencyClosure.PSObject.Properties['completeness']) {
                        [string]$ra.dependencyClosure.completeness
                    }
                    else { 'Unknown' }
                )
                affectedCapabilities        = @(
                    if ($ra.PSObject.Properties['affectedCapabilities']) { @($ra.affectedCapabilities) } else { @() }
                )
                requiredFunctionalTests     = @(
                    if ($ra.PSObject.Properties['requiredFunctionalTests']) { @($ra.requiredFunctionalTests) } else { @() }
                )
                selectedForExperiment       = $true
                executionAuthorized         = $false
            })
    }

    $valid = [bool](($errors.Count -eq 0) -and ($selected.Count -gt 0))
    $errorArr = [string[]]@($errors.ToArray())
    $selectedArr = [object[]]@($selected.ToArray())
    return [pscustomobject]@{
        schemaVersion                = [string](Get-XboxOSExperimentAllowlistSchemaVersion)
        valid                        = $valid
        errors                       = $errorArr
        selectedOperations           = $selectedArr
        denyByDefault                = $true
        selectionAuthorizesExecution = $false
        notes                        = [string[]]@(
            'Selecting an operation for an experiment never authorizes its execution.'
            'Only exact operationId + targetIdentity matches from the bound M2 plan are considered.'
        )
    }
}

function Test-XboxOSExperimentMissingEvidencePolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$SelectedOperations,
        [switch]$SimulateRiskAcceptance,
        [switch]$AttemptDisposablePromotion,
        [switch]$AttemptExecutionAuthorization
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]
    $ops = New-Object System.Collections.Generic.List[object]

    foreach ($op in @($SelectedOperations)) {
        $effective = [string]$op.effectiveReadiness
        $candidate = [string]$op.catalogCandidateReadiness
        $promoted = $effective
        $overrideAttempted = $false

        if ($AttemptDisposablePromotion -and $effective -eq 'MissingEvidence') {
            $overrideAttempted = $true
            [void]$errors.Add(("MissingEvidence cannot become VerifiedSafeForConsideration merely because an experiment is disposable: {0}" -f $op.operationId))
            $promoted = 'MissingEvidence'
        }
        if ($AttemptExecutionAuthorization) {
            $overrideAttempted = $true
            [void]$errors.Add(("MissingEvidence cannot automatically authorize execution: {0}" -f $op.operationId))
        }
        if ($SimulateRiskAcceptance -and $effective -eq 'MissingEvidence') {
            [void]$notes.Add(("Simulated risk acceptance recorded for {0}; does not grant execution authorization." -f $op.operationId))
        }

        [void]$ops.Add([pscustomobject]@{
                operationId               = [string]$op.operationId
                catalogCandidateReadiness = $candidate
                effectiveReadiness        = $promoted
                disposablePromotionApplied = $false
                riskAcceptanceSimulated   = [bool]$SimulateRiskAcceptance
                executionAuthorized       = $false
                overrideAttempted         = $overrideAttempted
            })
    }

    if ($AttemptExecutionAuthorization) {
        [void]$errors.Add('Experimental override remains disabled on production paths.')
    }

    return [pscustomobject]@{
        policyVersion                   = 'missing-evidence-policy-v1'
        valid                           = [bool]($errors.Count -eq 0)
        errors                          = [string[]]@($errors.ToArray())
        notes                           = [string[]]@($notes.ToArray())
        operations                      = [object[]]@($ops.ToArray())
        riskAcceptanceIsSeparateControl = $true
        finalDecisionMustRemainBlocked  = $true
        experimentalOverrideDisabled    = $true
    }
}

function Get-XboxOSExperimentPlanCanonicalDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$PlanFields
    )

    $ops = @(
        @($PlanFields.operations) |
            Sort-Object operationId |
            ForEach-Object {
                [ordered]@{
                    operationId                   = [string]$_.operationId
                    targetIdentity                = [string]$_.targetIdentity
                    operationType                 = [string]$_.operationType
                    planStatus                    = [string]$_.planStatus
                    catalogCandidateReadiness     = [string]$_.catalogCandidateReadiness
                    effectiveReadiness            = [string]$_.effectiveReadiness
                    dependencyClosureCompleteness = [string]$_.dependencyClosureCompleteness
                }
            }
    )

    return [ordered]@{
        hashSchemaVersion          = Get-XboxOSExperimentPlanHashSchemaVersion
        schemaVersion              = Get-XboxOSExperimentPlanSchemaVersion
        engineVersion              = Get-XboxOSExperimentPlanEngineVersion
        sourceIsoSha256            = [string]$PlanFields.sourceIsoSha256
        editionName                = [string]$PlanFields.editionName
        buildNumber                = [string]$PlanFields.buildNumber
        architecture               = [string]$PlanFields.architecture
        sourceIndex                = [string]$PlanFields.sourceIndex
        inventoryFingerprint       = [string]$PlanFields.inventoryFingerprint
        servicingPlanContentHash   = [string]$PlanFields.servicingPlanContentHash
        readinessReportIdentity    = [ordered]@{
            sourcePath           = [string]$PlanFields.readinessReportIdentity.sourcePath
            decision             = [string]$PlanFields.readinessReportIdentity.decision
            engineVersion        = [string]$PlanFields.readinessReportIdentity.engineVersion
            planContentHash      = [string]$PlanFields.readinessReportIdentity.planContentHash
            inventoryFingerprint = [string]$PlanFields.readinessReportIdentity.inventoryFingerprint
        }
        gitCommitSha               = [string]$PlanFields.git.gitCommitSha
        gitDirty                   = [string]$PlanFields.git.gitDirty
        operations                 = $ops
        expectedScope              = [string]$PlanFields.expectedScope
        workspaceConstraintDigest  = [string]$PlanFields.workspaceConstraintDigest
        requiredSnapshots          = @($PlanFields.requiredSnapshots | Sort-Object)
        requiredFunctionalTests    = @($PlanFields.requiredFunctionalTests | Sort-Object)
        abortConditions            = @($PlanFields.abortConditions | Sort-Object)
        recoveryRequirements       = @($PlanFields.recoveryRequirements | Sort-Object)
    }
}

function Get-XboxOSExperimentPlanContentHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$CanonicalDocument
    )

    return Get-XboxOSUtf8Sha256Hex -Text (ConvertTo-XboxOSCanonicalJson -Value $CanonicalDocument)
}

function New-XboxOSExperimentAuthorizationRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ExperimentPlanning', 'OperatorReviewConsent', 'ExperimentalRiskAcceptance', 'ExecutionAuthorization', 'FunctionalValidation')]
        [string]$Layer,
        [Parameter(Mandatory)][string]$ExperimentContentHash,
        [Parameter(Mandatory)][string]$ServicingPlanContentHash,
        [Parameter(Mandatory)][string]$InventoryFingerprint,
        [Parameter(Mandatory)][string]$SourceIsoSha256,
        [Parameter(Mandatory)][string]$OperatorId,
        [Parameter(Mandatory)][string[]]$OperationIds,
        [datetime]$IssuedUtc = [datetime]::UtcNow,
        [datetime]$ExpiresUtc = [datetime]::UtcNow.AddHours(8),
        [string]$Decision = 'Recorded',
        [string]$Nonce = $null,
        [string]$PrivateKeyPemPath = $null,
        [switch]$ClaimApprovedTrue
    )

    if ($Layer -eq 'ExecutionAuthorization') {
        throw 'ExecutionAuthorization layer is structurally disabled in Milestone 6A.'
    }
    if ([string]::IsNullOrWhiteSpace($OperatorId)) {
        throw 'OperatorId is required.'
    }
    if ($ExpiresUtc -le $IssuedUtc) {
        throw 'ExpiresUtc must be after IssuedUtc.'
    }
    if (-not $Nonce) {
        $Nonce = [guid]::NewGuid().ToString('N')
    }
    if (-not $script:XboxOSExperimentUsedNonces.Add($Nonce)) {
        throw ("Authorization nonce replay detected: {0}" -f $Nonce)
    }

    $binding = [ordered]@{
        authLayerSchemaVersion   = Get-XboxOSExperimentAuthLayerSchemaVersion
        layer                    = $Layer
        experimentContentHash    = $ExperimentContentHash
        servicingPlanContentHash = $ServicingPlanContentHash
        inventoryFingerprint     = $InventoryFingerprint
        sourceIsoSha256          = $SourceIsoSha256
        operatorId               = $OperatorId
        operationIds             = @($OperationIds | Sort-Object)
        issuedUtc                = $IssuedUtc.ToUniversalTime().ToString('o')
        expiresUtc               = $ExpiresUtc.ToUniversalTime().ToString('o')
        nonce                    = $Nonce
        decision                 = $Decision
        # Intentionally not trusted alone:
        approved                 = [bool]$ClaimApprovedTrue
    }
    $bindingHash = Get-XboxOSUtf8Sha256Hex -Text (ConvertTo-XboxOSCanonicalJson -Value $binding)
    $canonicalPayload = ConvertTo-XboxOSCanonicalJson -Value ([ordered]@{
            bindingHash = $bindingHash
            binding     = $binding
        })

    $signature = $null
    $signatureValid = $false
    if ($PrivateKeyPemPath) {
        $signature = New-XboxOSApprovalSignature -CanonicalPayload $canonicalPayload -PrivateKeyPemPath $PrivateKeyPemPath
    }

    return [pscustomobject]@{
        recordId                       = ('exp-auth-{0}-{1}' -f $Layer, $bindingHash.Substring(0, 12).ToLowerInvariant())
        authLayerSchemaVersion         = Get-XboxOSExperimentAuthLayerSchemaVersion
        layer                          = $Layer
        binding                        = [pscustomobject]$binding
        bindingHash                    = $bindingHash
        canonicalPayload               = $canonicalPayload
        signatureBase64                = $signature
        signatureValid                 = $signatureValid
        cryptographicallyAuthenticated = $false
        testKeyOnly                    = [bool]$PrivateKeyPemPath
        interchangeableWithOtherLayers = $false
        grantsExecutionAuthorization   = $false
        experimentalMutationEnabled    = $false
        experimentalExecutionAuthorized = $false
        realDismExecutionEnabled       = $false
        modifyingCommandsInvoked       = $false
        executionAuthorized            = $false
        servicingAuthorized            = $false
        notes                          = @(
            'Authorization layers are not interchangeable.'
            'approved=true on JSON is never trusted alone.'
            'Test signing keys remain test-only.'
            'Layer D ExecutionAuthorization is structurally disabled in Milestone 6A.'
        )
    }
}

function Test-XboxOSExperimentAuthorizationRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Record,
        [Parameter(Mandatory)][string]$ExpectedLayer,
        [Parameter(Mandatory)][string]$ExperimentContentHash,
        [Parameter(Mandatory)][string]$ServicingPlanContentHash,
        [Parameter(Mandatory)][string]$InventoryFingerprint,
        [Parameter(Mandatory)][string]$SourceIsoSha256,
        [Parameter(Mandatory)][string]$OperatorId,
        [datetime]$AsOfUtc = [datetime]::UtcNow,
        [string]$PublicKeyPemPath = $null,
        [string[]]$ExpectedOperationIds = @()
    )

    $errors = New-Object System.Collections.Generic.List[string]

    if ([string]$Record.layer -ne $ExpectedLayer) {
        [void]$errors.Add(("Authorization layer mismatch: expected {0}, got {1}." -f $ExpectedLayer, $Record.layer))
    }
    if ($ExpectedLayer -eq 'ExecutionAuthorization' -or [string]$Record.layer -eq 'ExecutionAuthorization') {
        [void]$errors.Add('ExecutionAuthorization layer is structurally disabled in Milestone 6A.')
    }
    if (-not $Record.PSObject.Properties['binding'] -or $null -eq $Record.binding) {
        [void]$errors.Add('Authorization binding missing.')
        return [pscustomobject]@{
            validForSimulation           = $false
            errors                       = [string[]]@($errors.ToArray())
            signatureValid               = $false
            grantsExecutionAuthorization = $false
        }
    }

    $b = $Record.binding
    $recomputed = Get-XboxOSUtf8Sha256Hex -Text (ConvertTo-XboxOSCanonicalJson -Value ([ordered]@{
                authLayerSchemaVersion   = [string]$b.authLayerSchemaVersion
                layer                    = [string]$b.layer
                experimentContentHash    = [string]$b.experimentContentHash
                servicingPlanContentHash = [string]$b.servicingPlanContentHash
                inventoryFingerprint     = [string]$b.inventoryFingerprint
                sourceIsoSha256          = [string]$b.sourceIsoSha256
                operatorId               = [string]$b.operatorId
                operationIds             = @($b.operationIds | Sort-Object)
                issuedUtc                = [string]$b.issuedUtc
                expiresUtc               = [string]$b.expiresUtc
                nonce                    = [string]$b.nonce
                decision                 = [string]$b.decision
                approved                 = [bool]$b.approved
            }))
    if ([string]$Record.bindingHash -ne $recomputed) {
        [void]$errors.Add('Authorization binding hash mismatch (forged or tampered record).')
    }
    if ([string]$b.experimentContentHash -ne $ExperimentContentHash) {
        [void]$errors.Add('Experiment content hash mismatch (evidence/plan substitution).')
    }
    if ([string]$b.servicingPlanContentHash -ne $ServicingPlanContentHash) {
        [void]$errors.Add('Servicing plan hash mismatch.')
    }
    if ([string]$b.inventoryFingerprint -ne $InventoryFingerprint) {
        [void]$errors.Add('Inventory fingerprint mismatch.')
    }
    if ([string]$b.sourceIsoSha256 -ne $SourceIsoSha256) {
        [void]$errors.Add('Source ISO identity mismatch.')
    }
    if ([string]$b.operatorId -ne $OperatorId) {
        [void]$errors.Add('Mismatched operator identity.')
    }

    try {
        $exp = [datetime]::Parse([string]$b.expiresUtc, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        if ($AsOfUtc.ToUniversalTime() -gt $exp) {
            [void]$errors.Add('Operator consent/risk acceptance expired.')
        }
    }
    catch {
        [void]$errors.Add('Invalid expiresUtc on authorization record.')
    }

    if ($ExpectedOperationIds.Count -gt 0) {
        $bound = @($b.operationIds | Sort-Object)
        $expect = @($ExpectedOperationIds | Sort-Object)
        if (($bound -join '|') -ne ($expect -join '|')) {
            [void]$errors.Add('Changed operation allowlist relative to authorization binding.')
        }
    }

    # approved=true alone never validates
    if ($b.PSObject.Properties['approved'] -and $b.approved -eq $true -and $errors.Count -gt 0) {
        [void]$errors.Add('approved=true is not trusted when binding validation failed.')
    }

    $sigOk = $false
    if ($PublicKeyPemPath -and $Record.PSObject.Properties['signatureBase64'] -and $Record.signatureBase64) {
        $payload = if ($Record.PSObject.Properties['canonicalPayload']) { [string]$Record.canonicalPayload } else { '' }
        if ([string]::IsNullOrWhiteSpace($payload)) {
            [void]$errors.Add('Signed authorization record missing canonicalPayload.')
        }
        else {
            $vr = Test-XboxOSApprovalSignature -CanonicalPayload $payload -SignatureBase64 ([string]$Record.signatureBase64) -PublicKeyPemPath $PublicKeyPemPath
            $sigOk = [bool]$vr.signatureValid
            if (-not $sigOk) {
                [void]$errors.Add('Invalid authorization signature.')
            }
        }
    }
    elseif ($Record.PSObject.Properties['signatureBase64'] -and $Record.signatureBase64 -and -not $PublicKeyPemPath) {
        [void]$errors.Add('Signature present but PublicKeyPemPath not supplied; fail closed.')
    }

    if ($Record.PSObject.Properties['grantsExecutionAuthorization'] -and $Record.grantsExecutionAuthorization) {
        [void]$errors.Add('Record claims grantsExecutionAuthorization; forbidden in Milestone 6A.')
    }
    if ($Record.PSObject.Properties['executionAuthorized'] -and $Record.executionAuthorized) {
        [void]$errors.Add('Record claims executionAuthorized; forbidden.')
    }

    return [pscustomobject]@{
        validForSimulation              = [bool]($errors.Count -eq 0)
        errors                          = [string[]]@($errors.ToArray())
        signatureValid                  = $sigOk
        grantsExecutionAuthorization    = $false
        experimentalMutationEnabled     = $false
        experimentalExecutionAuthorized = $false
        executionAuthorized             = $false
        notes                           = [string[]]@('Validation success never enables writable execution.')
    }
}

function Assert-XboxOSExperimentTransactionTransition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )

    if ($script:XboxOSExperimentTransactionStates -notcontains $From) {
        throw ("Unknown experiment transaction state '{0}'." -f $From)
    }
    if ($script:XboxOSExperimentTransactionStates -notcontains $To) {
        throw ("Unknown experiment transaction state '{0}'." -f $To)
    }
    # Explicit hard block for writable labels (checked before allowlist; do not match BlockedForExecution).
    $writableBlocked = @(
        'Executing', 'ExecutingMutation', 'MutationInProgress', 'Apply', 'Committed',
        'WritableExecution', 'AuthorizedForExecution', 'LiveMutation'
    )
    if ($writableBlocked -contains $To) {
        throw ("Writable-execution transition '{0}' is not reachable in Milestone 6A." -f $To)
    }
    $allowed = @($script:XboxOSExperimentTransactionTransitions[$From])
    if ($allowed -notcontains $To) {
        throw ("Invalid experiment transaction transition: {0} -> {1}." -f $From, $To)
    }
    return $true
}

function New-XboxOSExperimentTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExperimentId,
        [Parameter(Mandatory)][string]$ContentHash,
        [string]$InitialState = 'Planned'
    )

    if ($script:XboxOSExperimentTransactionStates -notcontains $InitialState) {
        throw ("Unknown initial state '{0}'." -f $InitialState)
    }

    return [pscustomobject]@{
        schemaVersion                      = Get-XboxOSExperimentTransactionSchemaVersion
        experimentId                       = $ExperimentId
        contentHash                        = $ContentHash
        state                              = $InitialState
        history                            = @([pscustomobject]@{ utc = [datetime]::UtcNow; state = $InitialState; note = 'Created' })
        realDismExecutionEnabled           = $false
        modifyingCommandsInvoked           = $false
        executionAuthorized                = $false
        servicingAuthorized                = $false
        experimentalMutationEnabled        = $false
        experimentalExecutionAuthorized    = $false
    }
}

function Set-XboxOSExperimentTransactionState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Transaction,
        [Parameter(Mandatory)][string]$To,
        [string]$Note = ''
    )

    Assert-XboxOSExperimentTransactionTransition -From ([string]$Transaction.state) -To $To
    $Transaction.state = $To
    $hist = @($Transaction.history) + @([pscustomobject]@{ utc = [datetime]::UtcNow; state = $To; note = $Note })
    $Transaction.history = $hist
    Assert-XboxOSExperimentSafetyInvariants -Report $Transaction
    return $Transaction
}

function New-XboxOSExperimentSnapshotContract {
    [CmdletBinding()]
    param()

    return @(
        [pscustomobject]@{ snapshotId = 'snap-source-identity'; schemaVersion = (Get-XboxOSExperimentSnapshotSchemaVersion); fields = @('sourceIsoSha256', 'editionName', 'buildNumber', 'architecture', 'sourceIndex') },
        [pscustomobject]@{ snapshotId = 'snap-inventory-fingerprint'; schemaVersion = (Get-XboxOSExperimentSnapshotSchemaVersion); fields = @('inventoryFingerprint') },
        [pscustomobject]@{ snapshotId = 'snap-wim-hash'; schemaVersion = (Get-XboxOSExperimentSnapshotSchemaVersion); fields = @('disposableWimSha256') },
        [pscustomobject]@{ snapshotId = 'snap-mount-ownership'; schemaVersion = (Get-XboxOSExperimentSnapshotSchemaVersion); fields = @('ownedMountPath', 'ownershipToken') },
        [pscustomobject]@{ snapshotId = 'snap-registry-hive-ownership'; schemaVersion = (Get-XboxOSExperimentSnapshotSchemaVersion); fields = @('ownedHiveKey', 'ownershipToken') },
        [pscustomobject]@{ snapshotId = 'snap-plan-hash'; schemaVersion = (Get-XboxOSExperimentSnapshotSchemaVersion); fields = @('servicingPlanContentHash', 'experimentContentHash') },
        [pscustomobject]@{ snapshotId = 'snap-evidence-bindings'; schemaVersion = (Get-XboxOSExperimentSnapshotSchemaVersion); fields = @('readinessReportIdentity', 'evidenceIds') }
    )
}

function New-XboxOSExperimentPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object]$ReadinessAssessment,
        [Parameter(Mandatory)][object]$AllowlistResult,
        [Parameter(Mandatory)][object]$WorkspaceConstraints,
        [Parameter(Mandatory)][object]$FunctionalValidationCatalog,
        [string]$RepoRoot = $null,
        [string]$ExpectedScope = 'disposable-lab-analysis-only',
        [string]$ReadinessReportPath = ''
    )

    Assert-XboxOSExecutionSafetyInvariants
    Assert-XboxOSExperimentSafetyInvariants

    if (-not $AllowlistResult.valid) {
        throw ("Allowlist rejected: {0}" -f ($AllowlistResult.errors -join '; '))
    }
    if (-not $WorkspaceConstraints.valid) {
        throw ("Workspace constraints rejected: {0}" -f ($WorkspaceConstraints.errors -join '; '))
    }

    $src = $Plan.sourceImage
    $iso = if ($src -and $src.PSObject.Properties['isoSha256']) { [string]$src.isoSha256 } else { '' }
    $edition = if ($src -and $src.PSObject.Properties['editionName']) { [string]$src.editionName } else { '' }
    $build = if ($src -and $src.PSObject.Properties['buildNumber']) { [string]$src.buildNumber } else { '' }
    $index = if ($src -and $src.PSObject.Properties['sourceIndex']) { [string]$src.sourceIndex } else { '' }
    $arch = 'Unknown'
    if ($ReadinessAssessment.PSObject.Properties['sourceImage'] -and $ReadinessAssessment.sourceImage -and $ReadinessAssessment.sourceImage.PSObject.Properties['architecture']) {
        $arch = [string]$ReadinessAssessment.sourceImage.architecture
        if ([string]::IsNullOrWhiteSpace($arch)) { $arch = 'Unknown' }
    }

    foreach ($name in @('iso', 'edition', 'build', 'index')) {
        $val = switch ($name) {
            'iso' { $iso }
            'edition' { $edition }
            'build' { $build }
            'index' { $index }
        }
        if ([string]::IsNullOrWhiteSpace([string]$val)) {
            throw ("Missing required source identity field: {0}" -f $name)
        }
    }

    $git = if ($ReadinessAssessment.PSObject.Properties['git']) { $ReadinessAssessment.git } else { Get-XboxOSReportTraceability -RepoRoot $RepoRoot }
    $snapshots = @(New-XboxOSExperimentSnapshotContract)
    $requiredTests = @(
        @($FunctionalValidationCatalog.tests) | ForEach-Object { [string]$_.testId }
    )
    foreach ($op in @($AllowlistResult.selectedOperations)) {
        if ($op.PSObject.Properties['requiredFunctionalTests']) {
            $requiredTests += @($op.requiredFunctionalTests | ForEach-Object { [string]$_ })
        }
    }
    $requiredTests = @($requiredTests | Select-Object -Unique | Sort-Object)

    $abort = @(
        'Integrity mismatch on source ISO SHA256',
        'Inventory fingerprint drift',
        'Plan hash mismatch',
        'Workspace ownership token mismatch',
        'Stale mount ownership detected',
        'Untracked registry-hive ownership detected',
        'Protected component selected',
        'MissingEvidence execution authorization attempted',
        'Any safety flag attempted True'
    )
    $recovery = @(
        'Do not modify source ISO',
        'Discard disposable mount without Commit',
        'Verify mount inventory empty',
        'Verify hive unload independently absent',
        'Retain logs under C:\XboxOS\Logs m6a namespace only',
        'Transition to RecoveryRequired on cleanup failure'
    )

    $wsDigest = Get-XboxOSUtf8Sha256Hex -Text (ConvertTo-XboxOSCanonicalJson -Value ([ordered]@{
                ownedWorkspaceIdentity = [string]$WorkspaceConstraints.ownedWorkspaceIdentity
                ownedWimPath           = [string]$WorkspaceConstraints.ownedWimPath
                ownedMountPath         = [string]$WorkspaceConstraints.ownedMountPath
                sourceIsoImmutable     = [bool]$WorkspaceConstraints.sourceIsoImmutable
            }))

    $readinessIdentity = [pscustomobject]@{
        sourcePath           = $ReadinessReportPath
        decision             = [string]$ReadinessAssessment.decision
        engineVersion        = [string]$ReadinessAssessment.engineVersion
        planContentHash      = [string]$ReadinessAssessment.planContentHash
        inventoryFingerprint = [string]$ReadinessAssessment.inventoryFingerprint
    }

    # Stale evidence: readiness decision Failed, or provenance missing
    if ([string]$ReadinessAssessment.decision -eq 'Failed') {
        throw 'Readiness assessment decision Failed; refusing stale/failed evidence.'
    }
    if (-not $ReadinessAssessment.PSObject.Properties['inventoryProvenance']) {
        throw 'Readiness assessment missing inventoryProvenance.'
    }

    $ops = @($AllowlistResult.selectedOperations)
    $fields = [pscustomobject]@{
        sourceIsoSha256          = $iso
        editionName              = $edition
        buildNumber              = $build
        architecture             = $arch
        sourceIndex              = $index
        inventoryFingerprint     = [string]$Plan.inventoryFingerprint
        servicingPlanContentHash = [string]$Plan.contentHash
        readinessReportIdentity  = $readinessIdentity
        git                      = $git
        operations               = $ops
        expectedScope            = $ExpectedScope
        workspaceConstraintDigest = $wsDigest
        requiredSnapshots        = @($snapshots | ForEach-Object { $_.snapshotId })
        requiredFunctionalTests  = $requiredTests
        abortConditions          = $abort
        recoveryRequirements     = $recovery
    }

    $canonical = Get-XboxOSExperimentPlanCanonicalDocument -PlanFields $fields
    $contentHash = Get-XboxOSExperimentPlanContentHash -CanonicalDocument $canonical
    $experimentId = ('experiment-{0}-{1}' -f [datetime]::UtcNow.ToString('yyyyMMddHHmmssfff'), $contentHash.Substring(0, 12).ToLowerInvariant())

    return [pscustomobject]@{
        experimentId               = $experimentId
        schemaVersion              = Get-XboxOSExperimentPlanSchemaVersion
        engineVersion              = Get-XboxOSExperimentPlanEngineVersion
        hashSchemaVersion          = Get-XboxOSExperimentPlanHashSchemaVersion
        contentHash                = $contentHash
        sourceIsoSha256            = $iso
        editionName                = $edition
        buildNumber                = $build
        architecture               = $arch
        sourceIndex                = $index
        inventoryFingerprint       = [string]$Plan.inventoryFingerprint
        servicingPlanContentHash   = [string]$Plan.contentHash
        readinessReportIdentity    = $readinessIdentity
        git                        = $git
        operations                 = $ops
        expectedScope              = $ExpectedScope
        disposableWorkspaceConstraints = $WorkspaceConstraints
        requiredSnapshots          = $snapshots
        requiredFunctionalTests    = $requiredTests
        abortConditions            = $abort
        recoveryRequirements       = $recovery
        protectedCapabilityImpacts = @(
            $ops | ForEach-Object { @($_.affectedCapabilities) } | Where-Object { $_ } | Select-Object -Unique
        )
        dependencyClosureResults   = @(
            $ops | ForEach-Object {
                [pscustomobject]@{
                    operationId  = $_.operationId
                    completeness = $_.dependencyClosureCompleteness
                }
            }
        )
        realDismExecutionEnabled           = $false
        modifyingCommandsInvoked           = $false
        executionAuthorized                = $false
        servicingAuthorized                = $false
        experimentalMutationEnabled        = $false
        experimentalExecutionAuthorized    = $false
        generatedUtc                       = [datetime]::UtcNow
        notes                              = @(
            'Milestone 6A experiment plan: analysis/simulation only.'
            'All selected operations may be planned; none are authorized for execution.'
        )
    }
}

function Invoke-XboxOSExperimentPlanSimulate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object]$ReadinessAssessment,
        [Parameter(Mandatory)][string[]]$RequestedOperationIds,
        [Parameter(Mandatory)][object]$FunctionalValidationCatalog,
        [string]$RepoRoot = $null,
        [string]$OperatorId = 'sim-operator',
        [string]$ProposedWorkspaceRoot = 'C:\XboxOS\Work\experiment-m6a-sim',
        [string]$SourceIsoPath = 'C:\XboxOS\Sources\Windows11_Client_x64_en-us_26300_9457.iso',
        [string]$ReadinessReportPath = '',
        [string]$PrivateKeyPemPath = $null,
        [string]$PublicKeyPemPath = $null,
        [switch]$SimulateOperatorConsent,
        [switch]$SimulateRiskAcceptance,
        [switch]$AttemptMissingEvidenceExecution
    )

    Assert-XboxOSExperimentSafetyInvariants

    $isoExpected = ''
    if ($Plan.sourceImage -and $Plan.sourceImage.PSObject.Properties['isoSha256']) {
        $isoExpected = [string]$Plan.sourceImage.isoSha256
    }

    $allow = Test-XboxOSExperimentOperationAllowlist `
        -Plan $Plan `
        -ReadinessAssessment $ReadinessAssessment `
        -RequestedOperationIds $RequestedOperationIds `
        -ExpectedInventoryFingerprint ([string]$Plan.inventoryFingerprint) `
        -ExpectedPlanContentHash ([string]$Plan.contentHash) `
        -ExpectedIsoSha256 $isoExpected

    $ws = Test-XboxOSExperimentWorkspaceConstraints `
        -ProposedWorkspaceRoot $ProposedWorkspaceRoot `
        -SourceIsoPath $SourceIsoPath `
        -OwnerId $OperatorId

    $blockers = New-Object System.Collections.Generic.List[string]
    if (-not $allow.valid) { foreach ($e in @($allow.errors)) { [void]$blockers.Add($e) } }
    if (-not $ws.valid) { foreach ($e in @($ws.errors)) { [void]$blockers.Add($e) } }

    $experimentPlan = $null
    $tx = $null
    $authRecords = @()
    $missingPolicy = $null
    $decision = 'BlockedForExecution'
    $state = 'BlockedForExecution'

    if ($allow.valid -and $ws.valid) {
        $experimentPlan = New-XboxOSExperimentPlan `
            -Plan $Plan `
            -ReadinessAssessment $ReadinessAssessment `
            -AllowlistResult $allow `
            -WorkspaceConstraints $ws `
            -FunctionalValidationCatalog $FunctionalValidationCatalog `
            -RepoRoot $RepoRoot `
            -ReadinessReportPath $ReadinessReportPath

        $tx = New-XboxOSExperimentTransaction -ExperimentId $experimentPlan.experimentId -ContentHash $experimentPlan.contentHash
        $null = Set-XboxOSExperimentTransactionState -Transaction $tx -To 'AwaitingOperatorReview' -Note 'Plan constructed'

        $planningRec = New-XboxOSExperimentAuthorizationRecord `
            -Layer ExperimentPlanning `
            -ExperimentContentHash $experimentPlan.contentHash `
            -ServicingPlanContentHash $experimentPlan.servicingPlanContentHash `
            -InventoryFingerprint $experimentPlan.inventoryFingerprint `
            -SourceIsoSha256 $experimentPlan.sourceIsoSha256 `
            -OperatorId $OperatorId `
            -OperationIds @($experimentPlan.operations | ForEach-Object { $_.operationId }) `
            -Decision 'Planned' `
            -PrivateKeyPemPath $PrivateKeyPemPath
        if ($PublicKeyPemPath -and $planningRec.signatureBase64) {
            $vr = Test-XboxOSExperimentAuthorizationRecord `
                -Record $planningRec `
                -ExpectedLayer ExperimentPlanning `
                -ExperimentContentHash $experimentPlan.contentHash `
                -ServicingPlanContentHash $experimentPlan.servicingPlanContentHash `
                -InventoryFingerprint $experimentPlan.inventoryFingerprint `
                -SourceIsoSha256 $experimentPlan.sourceIsoSha256 `
                -OperatorId $OperatorId `
                -PublicKeyPemPath $PublicKeyPemPath `
                -ExpectedOperationIds @($experimentPlan.operations | ForEach-Object { $_.operationId })
            $planningRec.signatureValid = $vr.signatureValid
            $planningRec.cryptographicallyAuthenticated = $vr.signatureValid
            if (-not $vr.validForSimulation) {
                foreach ($e in @($vr.errors)) { [void]$blockers.Add($e) }
            }
        }
        $authRecords += $planningRec

        if ($SimulateOperatorConsent) {
            $consent = New-XboxOSExperimentAuthorizationRecord `
                -Layer OperatorReviewConsent `
                -ExperimentContentHash $experimentPlan.contentHash `
                -ServicingPlanContentHash $experimentPlan.servicingPlanContentHash `
                -InventoryFingerprint $experimentPlan.inventoryFingerprint `
                -SourceIsoSha256 $experimentPlan.sourceIsoSha256 `
                -OperatorId $OperatorId `
                -OperationIds @($experimentPlan.operations | ForEach-Object { $_.operationId }) `
                -Decision 'ConsentRecorded' `
                -ClaimApprovedTrue `
                -PrivateKeyPemPath $PrivateKeyPemPath
            if ($PublicKeyPemPath -and $consent.signatureBase64) {
                $vr = Test-XboxOSExperimentAuthorizationRecord `
                    -Record $consent `
                    -ExpectedLayer OperatorReviewConsent `
                    -ExperimentContentHash $experimentPlan.contentHash `
                    -ServicingPlanContentHash $experimentPlan.servicingPlanContentHash `
                    -InventoryFingerprint $experimentPlan.inventoryFingerprint `
                    -SourceIsoSha256 $experimentPlan.sourceIsoSha256 `
                    -OperatorId $OperatorId `
                    -PublicKeyPemPath $PublicKeyPemPath `
                    -ExpectedOperationIds @($experimentPlan.operations | ForEach-Object { $_.operationId })
                $consent.signatureValid = $vr.signatureValid
                $consent.cryptographicallyAuthenticated = $vr.signatureValid
                if (-not $vr.validForSimulation) {
                    foreach ($e in @($vr.errors)) { [void]$blockers.Add($e) }
                }
            }
            $authRecords += $consent
            $null = Set-XboxOSExperimentTransactionState -Transaction $tx -To 'ReviewRecorded' -Note 'Operator consent simulated'
        }

        $missingPolicy = Test-XboxOSExperimentMissingEvidencePolicy `
            -SelectedOperations $experimentPlan.operations `
            -SimulateRiskAcceptance:$SimulateRiskAcceptance `
            -AttemptDisposablePromotion:$AttemptMissingEvidenceExecution `
            -AttemptExecutionAuthorization:$AttemptMissingEvidenceExecution

        if (-not $missingPolicy.valid) {
            foreach ($e in @($missingPolicy.errors)) { [void]$blockers.Add($e) }
        }

        $needsRisk = @($experimentPlan.operations | Where-Object { $_.effectiveReadiness -eq 'MissingEvidence' }).Count -gt 0
        if ($needsRisk) {
            $null = Set-XboxOSExperimentTransactionState -Transaction $tx -To 'RiskAcceptanceRequired' -Note 'MissingEvidence ops require separate risk control'
            if ($SimulateRiskAcceptance) {
                $risk = New-XboxOSExperimentAuthorizationRecord `
                    -Layer ExperimentalRiskAcceptance `
                    -ExperimentContentHash $experimentPlan.contentHash `
                    -ServicingPlanContentHash $experimentPlan.servicingPlanContentHash `
                    -InventoryFingerprint $experimentPlan.inventoryFingerprint `
                    -SourceIsoSha256 $experimentPlan.sourceIsoSha256 `
                    -OperatorId $OperatorId `
                    -OperationIds @($experimentPlan.operations | ForEach-Object { $_.operationId }) `
                    -Decision 'RiskAcceptanceSimulated' `
                    -ClaimApprovedTrue `
                    -PrivateKeyPemPath $PrivateKeyPemPath
                $authRecords += $risk
            }
        }
        else {
            $null = Set-XboxOSExperimentTransactionState -Transaction $tx -To 'ExperimentPrepared' -Note 'No MissingEvidence (unexpected for M5 baseline)'
        }

        # Milestone 6A hard stop: never grant execution
        $null = Set-XboxOSExperimentTransactionState -Transaction $tx -To 'BlockedForExecution' -Note 'Milestone 6A structurally blocks execution'
        $state = [string]$tx.state
        $decision = 'BlockedForExecution'
        [void]$blockers.Add('Milestone 6A final decision is BlockedForExecution; execution authorization structurally disabled.')
    }

    $report = [pscustomobject]@{
        reportSchemaVersion                = 'experiment-plan-report-v1'
        engineVersion                      = Get-XboxOSExperimentPlanEngineVersion
        decision                           = $decision
        transactionState                   = $state
        experimentPlan                     = $experimentPlan
        allowlist                          = $allow
        workspaceConstraints               = $ws
        missingEvidencePolicy              = $missingPolicy
        authorizationRecords               = $authRecords
        transaction                        = $tx
        blockers                           = [string[]]@($blockers.ToArray() | Select-Object -Unique)
        simulatedOperatorConsent           = [bool]$SimulateOperatorConsent
        simulatedRiskAcceptance            = [bool]$SimulateRiskAcceptance
        functionalValidationCatalogVersion = [string]$FunctionalValidationCatalog.catalogVersion
        realDismExecutionEnabled           = $false
        modifyingCommandsInvoked           = $false
        executionAuthorized                = $false
        servicingAuthorized                = $false
        experimentalMutationEnabled        = $false
        experimentalExecutionAuthorized    = $false
        generatedUtc                       = [datetime]::UtcNow
        notes                              = @(
            'All eight Eligible operations may be planned for analysis, but none may be authorized for execution.'
            'Simulation outcomes never enable writable DISM or experimental mutation.'
        )
    }

    Assert-XboxOSExperimentSafetyInvariants -Report $report
    return $report
}

function Save-XboxOSExperimentPlanReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Report,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$Stem = 'XboxOS11-experiment-plan-m6a',
        [string]$RepoRoot = $null
    )

    Assert-XboxOSExperimentSafetyInvariants -Report $Report
    if ($OutputDirectory -match '(?i)OneDrive') {
        throw "Refusing to write experiment reports under OneDrive: $OutputDirectory"
    }
    if ($RepoRoot) {
        $null = Assert-XboxOSServicingPathSafety -Path $OutputDirectory -RepoRoot $RepoRoot -Purpose 'experiment plan reports'
    }
    # Refuse overwriting known M1-M5 baseline stems
    $forbidden = @(
        'DISM-Compatibility-20261014-2',
        'XboxOS11-disposable-preflight-m4-live-readonly',
        'XboxOS11-servicing-readiness-m5',
        'XboxOS11-execution-safety-m3',
        'XboxOS11-servicing-plan'
    )
    foreach ($f in $forbidden) {
        if ($Stem -eq $f -or $Stem -like "$f*") {
            throw ("Refusing to overwrite Milestone 1-5 baseline stem: {0}" -f $Stem)
        }
    }

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $jsonPath = Join-Path $OutputDirectory ($Stem + '.json')
    $mdPath = Join-Path $OutputDirectory ($Stem + '.md')

    ($Report | ConvertTo-Json -Depth 14) | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $plan = $Report.experimentPlan
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('# XboxOS11 Milestone 6A — Disposable Experiment Plan (simulation)')
    [void]$lines.Add('')
    [void]$lines.Add(('Engine: `{0}`' -f $Report.engineVersion))
    [void]$lines.Add(('Decision: **{0}**' -f $Report.decision))
    [void]$lines.Add(('Transaction state: `{0}`' -f $Report.transactionState))
    [void]$lines.Add('')
    [void]$lines.Add('## Safety flags (must remain False)')
    [void]$lines.Add('')
    [void]$lines.Add('| Flag | Value |')
    [void]$lines.Add('|------|-------|')
    foreach ($flag in @('realDismExecutionEnabled', 'modifyingCommandsInvoked', 'executionAuthorized', 'servicingAuthorized', 'experimentalMutationEnabled', 'experimentalExecutionAuthorized')) {
        [void]$lines.Add(('| `{0}` | {1} |' -f $flag, $Report.$flag))
    }
    [void]$lines.Add('')
    if ($plan) {
        [void]$lines.Add('## Experiment plan')
        [void]$lines.Add('')
        [void]$lines.Add('| Field | Value |')
        [void]$lines.Add('|------|-------|')
        [void]$lines.Add(('| experimentId | `{0}` |' -f $plan.experimentId))
        [void]$lines.Add(('| contentHash | `{0}` |' -f $plan.contentHash))
        [void]$lines.Add(('| plan hash | `{0}` |' -f $plan.servicingPlanContentHash))
        [void]$lines.Add(('| inventory fingerprint | `{0}` |' -f $plan.inventoryFingerprint))
        [void]$lines.Add(('| ISO SHA256 | `{0}` |' -f $plan.sourceIsoSha256))
        [void]$lines.Add(('| architecture | `{0}` |' -f $plan.architecture))
        [void]$lines.Add('')
        [void]$lines.Add('## Selected operations (planned only)')
        [void]$lines.Add('')
        [void]$lines.Add('| Operation | Candidate | Effective | Closure |')
        [void]$lines.Add('|-----------|-----------|-----------|---------|')
        foreach ($op in @($plan.operations)) {
            [void]$lines.Add(('| `{0}` | {1} | {2} | {3} |' -f $op.operationId, $op.catalogCandidateReadiness, $op.effectiveReadiness, $op.dependencyClosureCompleteness))
        }
    }
    [void]$lines.Add('')
    [void]$lines.Add('## Blockers')
    [void]$lines.Add('')
    foreach ($b in @($Report.blockers)) {
        [void]$lines.Add(("- {0}" -f $b))
    }
    [void]$lines.Add('')
    [void]$lines.Add('No writable DISM was invoked. No WIM was created or mounted.')
    ($lines -join "`n") + "`n" | Set-Content -LiteralPath $mdPath -Encoding UTF8

    Assert-XboxOSExperimentSafetyInvariants -Report $Report
    return [pscustomobject]@{
        JsonPath     = $jsonPath
        MarkdownPath = $mdPath
    }
}

function Reset-XboxOSExperimentNonceRegistry {
    [CmdletBinding()]
    param()
    $script:XboxOSExperimentUsedNonces.Clear()
}
