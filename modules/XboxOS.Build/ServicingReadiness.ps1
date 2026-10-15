# Milestone 5 — Dependency evidence and servicing readiness (analysis only).
#Requires -Version 5.1
Set-StrictMode -Version Latest

function Get-XboxOSServicingReadinessEngineVersion { '5.0.0' }
function Get-XboxOSDependencyEvidenceSchemaVersion { 'dependency-evidence-v1' }
function Get-XboxOSCapabilityRequirementsSchemaVersion { 'capability-requirements-v1' }
function Get-XboxOSServicingReadinessReportSchemaVersion { 'servicing-readiness-v1' }
function Get-XboxOSEvidenceQualitySchemaVersion { 'evidence-quality-v1' }

function Test-XboxOSWildcardMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Pattern
    )
    $parts = $Pattern -split '\|'
    foreach ($p in $parts) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ($Text -like $p.Trim()) { return $true }
    }
    return $false
}

function Get-XboxOSReportTraceability {
    [CmdletBinding()]
    param(
        [string]$RepoRoot
    )

    $warnings = New-Object System.Collections.Generic.List[string]
    $commit = 'Unknown'
    $dirty = $null
    $branch = 'Unknown'
    $verified = $false

    try {
        if (-not $RepoRoot) { $RepoRoot = Get-XboxOSRepoRoot }
        $git = Get-Command git -ErrorAction SilentlyContinue
        if (-not $git) {
            $warnings.Add('Git executable not found; commit traceability is Unknown.') | Out-Null
        }
        else {
            $sha = & git -C $RepoRoot rev-parse HEAD 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$sha)) {
                $commit = ([string]$sha).Trim()
                $verified = $true
            }
            else {
                $warnings.Add('git rev-parse HEAD failed; commit traceability is Unknown.') | Out-Null
            }

            $br = & git -C $RepoRoot rev-parse --abbrev-ref HEAD 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$br)) {
                $branch = ([string]$br).Trim()
            }

            $porcelain = & git -C $RepoRoot status --porcelain 2>$null
            if ($LASTEXITCODE -eq 0) {
                $dirty = @($porcelain | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
                if ($dirty) {
                    $warnings.Add('Working tree is dirty; report Git SHA may not match committed content.') | Out-Null
                }
            }
            else {
                $warnings.Add('git status --porcelain failed; dirty-tree status is Unknown.') | Out-Null
                $dirty = $null
            }
        }
    }
    catch {
        $warnings.Add(('Git traceability error: {0}' -f $_.Exception.Message)) | Out-Null
        $verified = $false
        $commit = 'Unknown'
    }

    $dirtyLabel = 'Unknown'
    if ($dirty -eq $true) { $dirtyLabel = 'True' }
    elseif ($dirty -eq $false) { $dirtyLabel = 'False' }

    [pscustomobject]@{
        gitCommitSha = [string]$commit
        gitBranch    = [string]$branch
        gitDirty     = [string]$dirtyLabel
        gitVerified  = [bool]$verified
        capturedUtc  = [string]((Get-Date).ToUniversalTime().ToString('o'))
        warnings     = [string[]]@($warnings.ToArray())
    }
}

function Resolve-XboxOSImageArchitectureMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Inventory,
        $CompatReport = $null,
        [string[]]$AdditionalNotes = @()
    )

    $notes = New-Object System.Collections.Generic.List[string]
    foreach ($n in @($AdditionalNotes)) { if ($n) { $notes.Add([string]$n) | Out-Null } }

    $architecture = 'Unknown'
    $source = 'unknown'
    $confidence = 'Insufficient'

    $candidates = @()
    if ($CompatReport) {
        if ($CompatReport.PSObject.Properties['exportMeta'] -and $CompatReport.exportMeta) {
            $em = @($CompatReport.exportMeta)[0]
            if ($em.PSObject.Properties['Architecture'] -and -not [string]::IsNullOrWhiteSpace([string]$em.Architecture)) {
                $candidates += [pscustomobject]@{ Value = [string]$em.Architecture; Source = 'dism-exportMeta.Architecture' }
            }
        }
        if ($CompatReport.PSObject.Properties['sourceSelection'] -and $CompatReport.sourceSelection) {
            $ss = $CompatReport.sourceSelection
            if ($ss.PSObject.Properties['Architecture'] -and -not [string]::IsNullOrWhiteSpace([string]$ss.Architecture)) {
                $candidates += [pscustomobject]@{ Value = [string]$ss.Architecture; Source = 'dism-sourceSelection.Architecture' }
            }
        }
    }

    if ($Inventory.PSObject.Properties['sourceImage'] -and $Inventory.sourceImage) {
        $si = $Inventory.sourceImage
        if ($si.PSObject.Properties['architecture'] -and -not [string]::IsNullOrWhiteSpace([string]$si.architecture)) {
            $candidates += [pscustomobject]@{ Value = [string]$si.architecture; Source = 'inventory.sourceImage.architecture' }
        }
    }

    if ($candidates.Count -gt 0) {
        $architecture = [string]$candidates[0].Value
        $source = [string]$candidates[0].Source
        $confidence = 'High'
        $notes.Add(('Architecture established from trustworthy metadata: {0}' -f $source)) | Out-Null
    }
    else {
        $notes.Add('Architecture metadata unavailable from DISM image fields; reporting Unknown (not assuming x64).') | Out-Null
        $x64Hits = @($Inventory.appxPackages | Where-Object { $_ -match '_x64__' }).Count
        $armHits = @($Inventory.appxPackages | Where-Object { $_ -match '_arm64__' }).Count
        if ($x64Hits -gt 0 -or $armHits -gt 0) {
            $notes.Add(('Non-authoritative package-identity tokens observed: x64={0}, arm64={1}. These do not set architecture.' -f $x64Hits, $armHits)) | Out-Null
        }
    }

    [pscustomobject]@{
        architecture = $architecture
        source       = $source
        confidence   = $confidence
        notes        = @($notes)
    }
}

function Import-XboxOSDependencyEvidenceCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Dependency evidence catalog not found: $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$raw.schemaVersion -ne (Get-XboxOSDependencyEvidenceSchemaVersion)) {
        throw ("Unsupported dependency evidence schema '{0}'." -f $raw.schemaVersion)
    }
    $raw
}

function Import-XboxOSCapabilityRequirementsCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Capability requirements catalog not found: $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$raw.schemaVersion -ne (Get-XboxOSCapabilityRequirementsSchemaVersion)) {
        throw ("Unsupported capability requirements schema '{0}'." -f $raw.schemaVersion)
    }
    $raw
}

function Test-XboxOSEvidenceFreshness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$EvidenceRecord,
        [datetime]$AsOfUtc = [datetime]::UtcNow
    )

    $stale = $false
    $reason = $null
    $days = 0
    if ($EvidenceRecord.PSObject.Properties['stalenessDays']) {
        $days = [int]$EvidenceRecord.stalenessDays
    }
    $anchor = $null
    if ($EvidenceRecord.PSObject.Properties['verifiedUtc'] -and $EvidenceRecord.verifiedUtc) {
        $anchor = [datetime]::Parse([string]$EvidenceRecord.verifiedUtc).ToUniversalTime()
    }
    elseif ($EvidenceRecord.PSObject.Properties['collectedUtc'] -and $EvidenceRecord.collectedUtc) {
        $anchor = [datetime]::Parse([string]$EvidenceRecord.collectedUtc).ToUniversalTime()
    }
    if ($null -ne $anchor -and $days -gt 0) {
        if ($AsOfUtc -gt $anchor.AddDays($days)) {
            $stale = $true
            $reason = ('Evidence {0} exceeded stalenessDays={1}.' -f $EvidenceRecord.evidenceId, $days)
        }
    }
    [pscustomobject]@{
        evidenceId = [string]$EvidenceRecord.evidenceId
        stale      = [bool]$stale
        reason     = $reason
    }
}

function New-XboxOSDependencyGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$EvidenceCatalog,
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)]$CapabilityCatalog
    )

    $nodes = New-Object System.Collections.Generic.List[object]
    $edges = New-Object System.Collections.Generic.List[object]
    $evidenceIndex = New-Object System.Collections.Generic.List[object]
    foreach ($ev in @($EvidenceCatalog.evidence)) {
        $evidenceIndex.Add([pscustomobject]@{
                evidenceId = [string]$ev.evidenceId
                record     = $ev
            }) | Out-Null
    }

    foreach ($c in @($EvidenceCatalog.components)) {
        $nodes.Add([pscustomobject]@{
                id          = [string]$c.id
                kind        = [string]$c.kind
                displayName = [string]$c.displayName
                origin      = 'catalog'
                critical    = $false
            }) | Out-Null
    }

    foreach ($name in @($Inventory.appxPackages)) {
        $id = 'appx:{0}' -f $name
        $nodes.Add([pscustomobject]@{
                id          = $id
                kind        = 'AppX'
                displayName = [string]$name
                origin      = 'inventory-observation'
                critical    = $false
            }) | Out-Null
        $edges.Add([pscustomobject]@{
                relationshipId = 'obs-provides-{0}' -f (Get-XboxOSUtf8Sha256Hex -Text $id).Substring(0, 12)
                from           = $id
                to             = $id
                kind           = 'Provides'
                phase          = 'InstallationTime'
                evidenceIds    = @('ev-m4-inventory-observation')
                notes          = @('Component observed present in authoritative offline inventory.')
            }) | Out-Null
    }

    foreach ($f in @($Inventory.features)) {
        $fname = if ($f.PSObject.Properties['Name']) { [string]$f.Name } elseif ($f.PSObject.Properties['FeatureName']) { [string]$f.FeatureName } else { [string]$f }
        $id = 'feature:{0}' -f $fname
        $nodes.Add([pscustomobject]@{
                id          = $id
                kind        = 'Feature'
                displayName = $fname
                origin      = 'inventory-observation'
                critical    = $false
            }) | Out-Null
    }

    foreach ($cap in @($CapabilityCatalog.capabilities)) {
        $id = 'capability:{0}' -f $cap.id
        $nodes.Add([pscustomobject]@{
                id          = $id
                kind        = 'Capability'
                displayName = [string]$cap.label
                origin      = 'capability-catalog'
                critical    = [bool]$cap.critical
            }) | Out-Null
    }

    foreach ($rel in @($EvidenceCatalog.relationships)) {
        $noteList = @()
        if ($rel.PSObject.Properties['notes'] -and $null -ne $rel.notes) {
            $noteList = @($rel.notes | ForEach-Object { [string]$_ })
        }
        $edges.Add([pscustomobject]@{
                relationshipId = [string]$rel.relationshipId
                from           = [string]$rel.from
                to             = [string]$rel.to
                kind           = [string]$rel.kind
                phase          = [string]$rel.phase
                evidenceIds    = @($rel.evidenceIds | ForEach-Object { [string]$_ })
                notes          = $noteList
            }) | Out-Null
    }

    [pscustomobject]@{
        graphSchemaVersion = 'dependency-graph-v1'
        nodeCount          = [int]$nodes.Count
        edgeCount          = [int]$edges.Count
        nodes              = @($nodes.ToArray())
        edges              = @($edges.ToArray())
        evidenceIndex      = @($evidenceIndex.ToArray())
    }
}

function Get-XboxOSCapabilityInspectionResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$CapabilityCatalog,
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)]$CompatibilityManifest
    )

    $protected = @(Get-XboxOSProtectedAppxPatterns -CompatibilityManifest $CompatibilityManifest)
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($cap in @($CapabilityCatalog.capabilities)) {
        $hits = New-Object System.Collections.Generic.List[string]
        foreach ($pat in @($cap.relatedAppxPatterns)) {
            foreach ($pkg in @($Inventory.appxPackages)) {
                if ($pkg -like $pat) { $hits.Add([string]$pkg) | Out-Null }
            }
        }
        $featureHits = New-Object System.Collections.Generic.List[string]
        foreach ($pat in @($cap.relatedFeaturePatterns)) {
            foreach ($f in @($Inventory.features)) {
                $fname = if ($f.PSObject.Properties['Name']) { [string]$f.Name } elseif ($f.PSObject.Properties['FeatureName']) { [string]$f.FeatureName } else { [string]$f }
                if ($fname -like $pat) { $featureHits.Add($fname) | Out-Null }
            }
        }

        $status = 'MissingEvidence'
        $note = 'Capability requires evidence beyond inventory presence.'
        if (-not [bool]$cap.inventoryObservable) {
            $status = 'NotObservableInProvisionedInventory'
            $note = 'Capability depends on components not fully visible in provisioned AppX inventory; not classified as absent/broken.'
        }
        elseif ($hits.Count -gt 0 -or $featureHits.Count -gt 0) {
            $status = 'InventoryPatternsObserved'
            $note = 'Related inventory patterns observed; this is not proof that all runtime dependencies are satisfied.'
        }
        else {
            $status = 'MissingEvidence'
            $note = 'No related inventory patterns observed; capability evidence remains incomplete (fail closed for critical capabilities).'
        }

        $collision = New-Object System.Collections.Generic.List[string]
        foreach ($hit in @($hits)) {
            foreach ($pat in $protected) {
                if ($hit -like $pat) { $collision.Add([string]$hit) | Out-Null; break }
            }
        }
        $docRefs = @()
        if ($cap.PSObject.Properties['documentationRefs'] -and $null -ne $cap.documentationRefs) {
            $docRefs = @($cap.documentationRefs | ForEach-Object { [string]$_ })
        }
        $results.Add([pscustomobject]@{
                capabilityId              = [string]$cap.id
                label                     = [string]$cap.label
                critical                  = [bool]$cap.critical
                inventoryObservable       = [bool]$cap.inventoryObservable
                status                    = $status
                appxHits                  = @($hits.ToArray() | Select-Object -Unique)
                featureHits               = @($featureHits.ToArray() | Select-Object -Unique)
                note                      = $note
                documentationRefs         = $docRefs
                protectedPatternCollision = @($collision.ToArray() | Select-Object -Unique)
            }) | Out-Null
    }

    [pscustomobject]@{
        schemaVersion = [string](Get-XboxOSCapabilityRequirementsSchemaVersion)
        results       = @($results.ToArray())
    }
}

function Resolve-XboxOSCatalogOperationAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Operation,
        [Parameter(Mandatory)]$EvidenceCatalog
    )

    $matches = @()
    foreach ($a in @($EvidenceCatalog.operationAssessments)) {
        if ([string]$a.manifestRuleId -ne [string]$Operation.manifestRuleId) { continue }
        if ([string]$a.operationType -ne [string]$Operation.operationType) { continue }
        if (Test-XboxOSWildcardMatch -Text ([string]$Operation.targetIdentity) -Pattern ([string]$a.targetIdentityPattern)) {
            $matches += $a
        }
    }
    if ($matches.Count -eq 1) { return $matches[0] }
    if ($matches.Count -gt 1) {
        return [pscustomobject]@{
            conflicting = $true
            matches     = $matches
        }
    }
    return $null
}

function Get-XboxOSRelatedEvidenceRecords {
    [CmdletBinding()]
    param(
        [string[]]$EvidenceIds,
        [Parameter(Mandatory)]$EvidenceCatalog
    )
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($id in @($EvidenceIds)) {
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        foreach ($ev in @($EvidenceCatalog.evidence)) {
            if ([string]$ev.evidenceId -eq [string]$id) {
                $out.Add($ev) | Out-Null
                break
            }
        }
    }
    # Wrap to prevent PowerShell pipeline unrolling of a single record.
    [pscustomobject]@{
        records = [object[]]@($out.ToArray())
    }
}

function Test-XboxOSEvidenceContradiction {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$EvidenceRecords = @()
    )

    $support = New-Object System.Collections.Generic.List[string]
    $contra = New-Object System.Collections.Generic.List[string]
    foreach ($ev in @($EvidenceRecords)) {
        if ($null -eq $ev) { continue }
        $supporting = @()
        $contradicting = @()
        if ($ev.PSObject.Properties['supportingFindings'] -and $null -ne $ev.supportingFindings) {
            $supporting = @($ev.supportingFindings)
        }
        if ($ev.PSObject.Properties['contradictingFindings'] -and $null -ne $ev.contradictingFindings) {
            $contradicting = @($ev.contradictingFindings)
        }
        foreach ($s in $supporting) { if ($s) { $support.Add([string]$s) | Out-Null } }
        foreach ($c in $contradicting) { if ($c) { $contra.Add([string]$c) | Out-Null } }
    }
    $hasConflict = ($support.Count -gt 0 -and $contra.Count -gt 0)
    [pscustomobject]@{
        conflicting             = [bool]$hasConflict
        supportingFindings      = @($support.ToArray())
        contradictingFindings   = @($contra.ToArray())
        hasAssumptionOnlySafety = $false
    }
}

function Invoke-XboxOSOperationReadinessEvaluation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Operation,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)]$CompatibilityManifest,
        [Parameter(Mandatory)]$EvidenceCatalog,
        [Parameter(Mandatory)]$CapabilityInspection,
        [Parameter(Mandatory)]$DependencyGraph
    )

    $uncertainties = New-Object System.Collections.Generic.List[string]
    $blockers = New-Object System.Collections.Generic.List[string]
    $validationSteps = New-Object System.Collections.Generic.List[string]
    $requiredTests = New-Object System.Collections.Generic.List[string]
    $affectedCaps = New-Object System.Collections.Generic.List[string]

    if ([string]$Operation.status -ne 'Eligible') {
        return [pscustomobject]@{
            operationId              = [string]$Operation.operationId
            manifestRuleId           = [string]$Operation.manifestRuleId
            operationType            = [string]$Operation.operationType
            targetIdentity           = [string]$Operation.targetIdentity
            planStatus               = [string]$Operation.status
            readiness                = 'NotApplicable'
            directDependencies       = @()
            transitiveDependencies   = @()
            sharedDependencies       = @()
            affectedCapabilities     = @()
            evidenceRecords          = @()
            uncertainties            = @('Operation is not Eligible in the Milestone 2 plan.')
            validationSteps          = @()
            requiredFunctionalTests  = @()
            blockers                 = @()
        }
    }

    # Exact identity
    $exactIdentity = [string]$Operation.targetIdentity
    $protectedHit = $false
    if ([string]$Operation.operationType -eq 'RemoveProvisionedAppx') {
        $protectedAppx = @(Get-XboxOSProtectedAppxPatterns -CompatibilityManifest $CompatibilityManifest)
        $protectedHit = [bool](Test-XboxOSPackageProtected -PackageName $exactIdentity -ProtectedPatterns $protectedAppx)
    }
    elseif ([string]$Operation.operationType -eq 'DisableOptionalFeature') {
        $protectedFeaturePatterns = @()
        if ($CompatibilityManifest.PSObject.Properties['protectedFeatureNamePatterns'] -and $CompatibilityManifest.protectedFeatureNamePatterns) {
            $protectedFeaturePatterns = @($CompatibilityManifest.protectedFeatureNamePatterns | ForEach-Object { [string]$_ })
        }
        $protectedHit = [bool](Test-XboxOSFeatureProtected -FeatureName $exactIdentity -NeverDisable $protectedFeaturePatterns)
        if (-not $protectedHit) {
            foreach ($pattern in $protectedFeaturePatterns) {
                if ($exactIdentity -like $pattern) { $protectedHit = $true; break }
            }
        }
    }

    if ($protectedHit) {
        $blockers.Add('Target matches protected compatibility patterns; classifying KnownUnsafe.') | Out-Null
        return [pscustomobject]@{
            operationId             = [string]$Operation.operationId
            manifestRuleId          = [string]$Operation.manifestRuleId
            operationType           = [string]$Operation.operationType
            targetIdentity          = $exactIdentity
            planStatus              = [string]$Operation.status
            readiness               = 'KnownUnsafe'
            directDependencies      = @()
            transitiveDependencies  = @()
            sharedDependencies      = @(
                [pscustomobject]@{ kind = 'SharedDependency'; to = 'capability:MicrosoftStore'; note = 'Protected patterns include Store/Xbox surfaces.' }
            )
            affectedCapabilities    = @($CapabilityInspection.results | Where-Object critical | ForEach-Object { $_.capabilityId })
            evidenceRecords         = @((Get-XboxOSRelatedEvidenceRecords -EvidenceIds @('ev-compat-protected-patterns') -EvidenceCatalog $EvidenceCatalog).records)
            uncertainties           = @()
            validationSteps         = @('Refuse removal/disable of protected identity')
            requiredFunctionalTests = @()
            blockers                = @($blockers)
        }
    }

    $catalogAssessment = Resolve-XboxOSCatalogOperationAssessment -Operation $Operation -EvidenceCatalog $EvidenceCatalog
    if ($null -eq $catalogAssessment) {
        $uncertainties.Add('No curated operation assessment found; fail closed as MissingEvidence.') | Out-Null
        $blockers.Add('Missing curated dependency evidence for Eligible operation.') | Out-Null
        return [pscustomobject]@{
            operationId             = [string]$Operation.operationId
            manifestRuleId          = [string]$Operation.manifestRuleId
            operationType           = [string]$Operation.operationType
            targetIdentity          = $exactIdentity
            planStatus              = [string]$Operation.status
            readiness               = 'MissingEvidence'
            directDependencies      = @()
            transitiveDependencies  = @()
            sharedDependencies      = @()
            affectedCapabilities    = @()
            evidenceRecords         = @((Get-XboxOSRelatedEvidenceRecords -EvidenceIds @('ev-consumer-appx-missing-removal-contract') -EvidenceCatalog $EvidenceCatalog).records)
            uncertainties           = @($uncertainties)
            validationSteps         = @('Curate AuthoritativeDocumentation or ControlledTestResult evidence')
            requiredFunctionalTests = @('Future disposable-image functional matrix')
            blockers                = @($blockers)
        }
    }

    if ($catalogAssessment.PSObject.Properties['conflicting'] -and $catalogAssessment.conflicting) {
        return [pscustomobject]@{
            operationId             = [string]$Operation.operationId
            manifestRuleId          = [string]$Operation.manifestRuleId
            operationType           = [string]$Operation.operationType
            targetIdentity          = $exactIdentity
            planStatus              = [string]$Operation.status
            readiness               = 'ConflictingEvidence'
            directDependencies      = @()
            transitiveDependencies  = @()
            sharedDependencies      = @()
            affectedCapabilities    = @()
            evidenceRecords         = @()
            uncertainties           = @('Multiple catalog assessments matched the same operation identity.')
            validationSteps         = @('Resolve duplicate catalog assessments')
            requiredFunctionalTests = @()
            blockers                = @('Conflicting curated assessments')
        }
    }

    $evidenceRecords = @((Get-XboxOSRelatedEvidenceRecords -EvidenceIds @($catalogAssessment.evidenceIds) -EvidenceCatalog $EvidenceCatalog).records)
    $freshnessIssues = @()
    foreach ($ev in $evidenceRecords) {
        $fr = Test-XboxOSEvidenceFreshness -EvidenceRecord $ev
        if ($fr.stale) {
            $freshnessIssues += $fr.reason
            $uncertainties.Add($fr.reason) | Out-Null
        }
    }

    $contradiction = Test-XboxOSEvidenceContradiction -EvidenceRecords $evidenceRecords
    $readiness = [string]$catalogAssessment.readiness

    # Assumption-only evidence cannot elevate to VerifiedSafeForConsideration
    $nonAssumption = @($evidenceRecords | Where-Object { [string]$_.sourceType -ne 'Assumption' -and [string]$_.quality -ne 'Insufficient' })
    if ($readiness -eq 'VerifiedSafeForConsideration') {
        if ($nonAssumption.Count -eq 0) {
            $readiness = 'MissingEvidence'
            $blockers.Add('VerifiedSafeForConsideration rejected because only Assumption/Insufficient evidence was present.') | Out-Null
        }
        if ($freshnessIssues.Count -gt 0) {
            $readiness = 'MissingEvidence'
            $blockers.Add('Curated safe-for-consideration evidence is stale.') | Out-Null
        }
        if ($contradiction.conflicting) {
            $readiness = 'ConflictingEvidence'
            $blockers.Add('Supporting and contradicting findings both present.') | Out-Null
        }
    }

    if ($readiness -eq 'MissingEvidence') {
        $blockers.Add('Eligible operation lacks sufficient non-assumption dependency evidence.') | Out-Null
    }

    foreach ($id in @($catalogAssessment.affectedCapabilityIds)) { $affectedCaps.Add([string]$id) | Out-Null }
    foreach ($t in @($catalogAssessment.requiredFunctionalTests)) { $requiredTests.Add([string]$t) | Out-Null }
    foreach ($v in @($catalogAssessment.validationSteps)) { $validationSteps.Add([string]$v) | Out-Null }

    # Graph-derived shared deps mentioning Store
    $shared = @($DependencyGraph.edges | Where-Object { $_.kind -eq 'SharedDependency' } | ForEach-Object {
            [pscustomobject]@{ relationshipId = $_.relationshipId; from = $_.from; to = $_.to; phase = $_.phase; evidenceIds = @($_.evidenceIds) }
        })

    $direct = @(
        [pscustomobject]@{
            kind    = 'ResolvedIdentity'
            identity = $exactIdentity
            notes   = @($catalogAssessment.directDependencyNotes)
        }
    )
    $transitive = @(
        [pscustomobject]@{
            kind  = 'CatalogTransitiveNotes'
            notes = @($catalogAssessment.transitiveDependencyNotes)
            complete = $false
        }
    )
    if (@($catalogAssessment.transitiveDependencyNotes).Count -eq 0 -or ($catalogAssessment.transitiveDependencyNotes -join ' ') -match 'not evidenced|incomplete') {
        $uncertainties.Add('Transitive dependency closure is incomplete.') | Out-Null
    }

    # Critical capabilities that are not inventory-proven remain uncertainties for every mutating Eligible op
    foreach ($cap in @($CapabilityInspection.results | Where-Object { $_.critical -and $_.status -ne 'InventoryPatternsObserved' })) {
        if ($cap.status -eq 'NotObservableInProvisionedInventory') {
            $uncertainties.Add(('Critical capability {0} is not fully observable in provisioned inventory.' -f $cap.capabilityId)) | Out-Null
        }
        elseif ($cap.status -eq 'MissingEvidence') {
            $uncertainties.Add(('Critical capability {0} lacks inventory pattern evidence.' -f $cap.capabilityId)) | Out-Null
        }
    }

    [pscustomobject]@{
        operationId             = [string]$Operation.operationId
        manifestRuleId          = [string]$Operation.manifestRuleId
        operationType           = [string]$Operation.operationType
        targetIdentity          = $exactIdentity
        planStatus              = [string]$Operation.status
        readiness               = $readiness
        directDependencies      = $direct
        transitiveDependencies  = $transitive
        sharedDependencies      = $shared
        affectedCapabilities    = @($affectedCaps)
        evidenceRecords         = @($evidenceRecords | ForEach-Object {
                [pscustomobject]@{
                    evidenceId              = $_.evidenceId
                    sourceType              = $_.sourceType
                    sourceReference         = $_.sourceReference
                    quality                 = $_.quality
                    buildApplicability      = $_.buildApplicability
                    editionApplicability    = $_.editionApplicability
                    collectedUtc            = $_.collectedUtc
                    verifiedUtc             = $_.verifiedUtc
                    knownLimitations        = @($_.knownLimitations)
                    supportingFindings      = @($_.supportingFindings)
                    contradictingFindings   = @($_.contradictingFindings)
                }
            })
        uncertainties           = @($uncertainties | Select-Object -Unique)
        validationSteps         = @($validationSteps)
        requiredFunctionalTests = @($requiredTests)
        blockers                = @($blockers | Select-Object -Unique)
        contradiction           = $contradiction
    }
}

function New-XboxOSServicingReadinessAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)]$CompatibilityManifest,
        [Parameter(Mandatory)]$EvidenceCatalog,
        [Parameter(Mandatory)]$CapabilityCatalog,
        $CompatReport = $null,
        [string]$RepoRoot
    )

    Assert-XboxOSExecutionSafetyInvariants

    $trace = Get-XboxOSReportTraceability -RepoRoot $RepoRoot
    $arch = Resolve-XboxOSImageArchitectureMetadata -Inventory $Inventory -CompatReport $CompatReport
    $graph = New-XboxOSDependencyGraph -EvidenceCatalog $EvidenceCatalog -Inventory $Inventory -CapabilityCatalog $CapabilityCatalog
    $capInspection = Get-XboxOSCapabilityInspectionResult -CapabilityCatalog $CapabilityCatalog -Inventory $Inventory -CompatibilityManifest $CompatibilityManifest

    $eligible = @($Plan.operations | Where-Object { [string]$_.status -eq 'Eligible' })
    $assessments = New-Object System.Collections.Generic.List[object]
    foreach ($op in @($Plan.operations)) {
        $assessments.Add((
                Invoke-XboxOSOperationReadinessEvaluation `
                    -Operation $op `
                    -Plan $Plan `
                    -Inventory $Inventory `
                    -CompatibilityManifest $CompatibilityManifest `
                    -EvidenceCatalog $EvidenceCatalog `
                    -CapabilityInspection $capInspection `
                    -DependencyGraph $graph
            )) | Out-Null
    }

    $eligibleAssessments = @($assessments | Where-Object { $_.planStatus -eq 'Eligible' })
    $blockers = New-Object System.Collections.Generic.List[string]
    $criticalUnresolved = @($eligibleAssessments | Where-Object {
            $_.readiness -in @('MissingEvidence', 'ConflictingEvidence', 'KnownUnsafe', 'Unsupported')
        })

    foreach ($a in $criticalUnresolved) {
        $blockers.Add(('Operation {0} readiness={1}' -f $a.operationId, $a.readiness)) | Out-Null
    }

    foreach ($cap in @($capInspection.results | Where-Object { $_.critical -and $_.status -eq 'MissingEvidence' })) {
        $blockers.Add(('Critical capability {0} has MissingEvidence.' -f $cap.capabilityId)) | Out-Null
    }

    # Critical non-observable capabilities are uncertainties, not automatic overall blockers unless an op claims VerifiedSafe without acknowledging them.
    # Overall remains Blocked while any Eligible op is unresolved.
    $decision = if ($criticalUnresolved.Count -gt 0 -or ($blockers | Where-Object { $_ -like 'Critical capability*' }).Count -gt 0) {
        'Blocked'
    }
    elseif (@($eligibleAssessments | Where-Object { $_.readiness -eq 'VerifiedSafeForConsideration' }).Count -eq $eligibleAssessments.Count -and $eligibleAssessments.Count -gt 0) {
        'ReadyForReview'
    }
    elseif ($eligibleAssessments.Count -eq 0) {
        'ReadyForReview'
    }
    else {
        'Blocked'
    }

    # Tighten: ReadyForReview only if ALL eligible are VerifiedSafeForConsideration
    if ($decision -eq 'ReadyForReview' -and $criticalUnresolved.Count -gt 0) {
        $decision = 'Blocked'
    }
    if (@($eligibleAssessments | Where-Object readiness -ne 'VerifiedSafeForConsideration').Count -gt 0) {
        $decision = 'Blocked'
        if ($blockers.Count -eq 0) {
            $blockers.Add('One or more Eligible operations are not VerifiedSafeForConsideration.') | Out-Null
        }
    }

    $buildNumber = $null
    $displayVersion = $null
    $editionName = $null
    $isoSha256 = $null
    $sourceIndex = $null
    if ($Inventory.PSObject.Properties['sourceImage'] -and $Inventory.sourceImage) {
        $si = $Inventory.sourceImage
        if ($si.PSObject.Properties['editionName']) { $editionName = [string]$si.editionName }
        if ($si.PSObject.Properties['buildNumber']) { $buildNumber = [string]$si.buildNumber }
        if ($si.PSObject.Properties['displayVersion']) { $displayVersion = [string]$si.displayVersion }
        if ($si.PSObject.Properties['isoSha256']) { $isoSha256 = [string]$si.isoSha256 }
        if ($si.PSObject.Properties['sourceIndex']) { $sourceIndex = $si.sourceIndex }
    }

    $sourceIndexText = if ($null -eq $sourceIndex) { '' } else { [string]$sourceIndex }
    $assessmentArray = [object[]]@($assessments.ToArray())
    $blockerArray = [string[]]@($blockers.ToArray() | Select-Object -Unique)
    $relKinds = [string[]]@($graph.edges | ForEach-Object { [string]$_.kind } | Select-Object -Unique | Sort-Object)

    [pscustomobject]@{
        reportSchemaVersion                 = [string](Get-XboxOSServicingReadinessReportSchemaVersion)
        engineVersion                       = [string](Get-XboxOSServicingReadinessEngineVersion)
        dependencyEvidenceSchemaVersion     = [string](Get-XboxOSDependencyEvidenceSchemaVersion)
        capabilityRequirementsSchemaVersion = [string](Get-XboxOSCapabilityRequirementsSchemaVersion)
        evidenceQualitySchemaVersion        = [string](Get-XboxOSEvidenceQualitySchemaVersion)
        generatedUtc                        = [string]((Get-Date).ToUniversalTime().ToString('o'))
        decision                            = [string]$decision
        planContentHash                     = [string]$Plan.contentHash
        inventoryFingerprint                = [string]$Inventory.inventoryFingerprint
        sourceImage                         = [pscustomobject]@{
            editionName            = [string]$editionName
            buildNumber            = [string]$buildNumber
            displayVersion         = [string]$displayVersion
            architecture           = [string]$arch.architecture
            architectureSource     = [string]$arch.source
            architectureConfidence = [string]$arch.confidence
            architectureNotes      = [string[]]@($arch.notes)
            isoSha256              = [string]$isoSha256
            sourceIndex            = $sourceIndexText
        }
        git                                 = $trace
        eligibleOperationCount              = [int]$eligible.Count
        operationAssessments                = $assessmentArray
        dependencyGraphSummary              = [pscustomobject]@{
            nodeCount         = [int]$graph.nodeCount
            edgeCount         = [int]$graph.edgeCount
            relationshipKinds = $relKinds
        }
        capabilityInspection                = $capInspection
        blockers                            = $blockerArray
        notes                               = [string[]]@(
            'Milestone 5 servicing-readiness analysis only.',
            'VerifiedSafeForConsideration does not authorize writable DISM.',
            'Synthetic/fixture ControlledTestResult data is not production dependency authorization.',
            'Default workflow uses previously captured inventory evidence; no automatic live DISM.'
        )
        realDismExecutionEnabled            = $false
        modifyingCommandsInvoked            = $false
        executionAuthorized                 = $false
        servicingAuthorized                 = $false
    }
}

function Save-XboxOSServicingReadinessReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Assessment,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$Stem,
        [string]$RepoRoot
    )

    if (-not $RepoRoot) { $RepoRoot = Get-XboxOSRepoRoot }
    $null = Assert-XboxOSServicingPathSafety -Path $OutputDirectory -RepoRoot $RepoRoot -Purpose 'servicing readiness reports'
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    # Refresh git capture at save time
    $Assessment.git = Get-XboxOSReportTraceability -RepoRoot $RepoRoot
    $Assessment.generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $Assessment.realDismExecutionEnabled = $false
    $Assessment.modifyingCommandsInvoked = $false
    $Assessment.executionAuthorized = $false
    $Assessment.servicingAuthorized = $false

    $jsonPath = Join-Path $OutputDirectory ($Stem + '.json')
    $mdPath = Join-Path $OutputDirectory ($Stem + '.md')

    $json = ConvertTo-XboxOSCanonicalJson -Value $Assessment
    Set-Content -LiteralPath $jsonPath -Value $json -Encoding utf8

    $md = New-Object System.Collections.Generic.List[string]
    $null = $md.Add('# XboxOS11 Servicing Readiness (Milestone 5)')
    $null = $md.Add('')
    $null = $md.Add(('- Engine: **{0}**' -f $Assessment.engineVersion))
    $null = $md.Add(('- Report schema: **{0}**' -f $Assessment.reportSchemaVersion))
    $null = $md.Add(('- Decision: **{0}**' -f $Assessment.decision))
    $null = $md.Add(('- Plan content hash: `{0}`' -f $Assessment.planContentHash))
    $null = $md.Add(('- Inventory fingerprint: `{0}`' -f $Assessment.inventoryFingerprint))
    $null = $md.Add(('- Source identity: `{0}` / `{1}` / `{2}`' -f $Assessment.sourceImage.editionName, $Assessment.sourceImage.buildNumber, $Assessment.sourceImage.displayVersion))
    $null = $md.Add(('- Architecture: **{0}** (source: {1})' -f $Assessment.sourceImage.architecture, $Assessment.sourceImage.architectureSource))
    $null = $md.Add(('- Git commit: `{0}`' -f $Assessment.git.gitCommitSha))
    $null = $md.Add(('- Git dirty: **{0}**' -f $Assessment.git.gitDirty))
    $null = $md.Add(('- Eligible operations: **{0}**' -f $Assessment.eligibleOperationCount))
    $null = $md.Add(('- Real DISM execution enabled: **{0}**' -f $Assessment.realDismExecutionEnabled))
    $null = $md.Add(('- Modifying commands invoked: **{0}**' -f $Assessment.modifyingCommandsInvoked))
    $null = $md.Add(('- Execution authorized: **{0}**' -f $Assessment.executionAuthorized))
    $null = $md.Add(('- Servicing authorized: **{0}**' -f $Assessment.servicingAuthorized))
    $null = $md.Add('')
    $null = $md.Add('## Operation assessments')
    $null = $md.Add('')
    foreach ($a in @($Assessment.operationAssessments | Where-Object planStatus -eq 'Eligible')) {
        $null = $md.Add(('### `{0}`' -f $a.operationId))
        $null = $md.Add('')
        $null = $md.Add(('- Target: `{0}`' -f $a.targetIdentity))
        $null = $md.Add(('- Readiness: **{0}**' -f $a.readiness))
        if (@($a.blockers).Count -gt 0) {
            $null = $md.Add(('- Blockers: {0}' -f ($a.blockers -join '; ')))
        }
        if (@($a.uncertainties).Count -gt 0) {
            $null = $md.Add(('- Uncertainties: {0}' -f ($a.uncertainties -join '; ')))
        }
        if (@($a.requiredFunctionalTests).Count -gt 0) {
            $null = $md.Add(('- Required functional tests: {0}' -f ($a.requiredFunctionalTests -join '; ')))
        }
        $null = $md.Add('')
    }
    $null = $md.Add('## Capability inspection')
    $null = $md.Add('')
    foreach ($c in @($Assessment.capabilityInspection.results)) {
        $null = $md.Add(('- `{0}`: **{1}** — {2}' -f $c.capabilityId, $c.status, $c.note))
    }
    $null = $md.Add('')
    $null = $md.Add('## Blockers')
    $null = $md.Add('')
    if (@($Assessment.blockers).Count -eq 0) {
        $null = $md.Add('- None')
    }
    else {
        foreach ($b in @($Assessment.blockers)) { $null = $md.Add(('- {0}' -f $b)) }
    }
    if (@($Assessment.git.warnings).Count -gt 0) {
        $null = $md.Add('')
        $null = $md.Add('## Traceability warnings')
        $null = $md.Add('')
        foreach ($w in @($Assessment.git.warnings)) { $null = $md.Add(('- {0}' -f $w)) }
    }
    if (@($Assessment.sourceImage.architectureNotes).Count -gt 0) {
        $null = $md.Add('')
        $null = $md.Add('## Architecture notes')
        $null = $md.Add('')
        foreach ($n in @($Assessment.sourceImage.architectureNotes)) { $null = $md.Add(('- {0}' -f $n)) }
    }

    Set-Content -LiteralPath $mdPath -Value ($md -join [Environment]::NewLine) -Encoding utf8

    [pscustomobject]@{
        JsonPath = $jsonPath
        MarkdownPath = $mdPath
    }
}
