# Milestone 5.1 — Dependency evidence and servicing readiness (analysis only).
#Requires -Version 5.1
Set-StrictMode -Version Latest

function Get-XboxOSServicingReadinessEngineVersion { '5.1.0' }
function Get-XboxOSDependencyEvidenceSchemaVersion { 'dependency-evidence-v1' }
function Get-XboxOSCapabilityRequirementsSchemaVersion { 'capability-requirements-v1' }
function Get-XboxOSServicingReadinessReportSchemaVersion { 'servicing-readiness-v1' }
function Get-XboxOSEvidenceQualitySchemaVersion { 'evidence-quality-v1' }

$script:XboxOSValidRelationshipKinds = @(
    'Requires', 'Provides', 'ConflictsWith', 'OptionalDependency', 'SharedDependency', 'UnknownRelationship'
)
$script:XboxOSValidSourceTypes = @(
    'AuthoritativeDocumentation', 'DirectlyObserved', 'ControlledTestResult', 'ManifestDeclared', 'Assumption'
)
$script:XboxOSValidReadiness = @(
    'VerifiedSafeForConsideration', 'KnownUnsafe', 'MissingEvidence', 'ConflictingEvidence', 'Unsupported', 'NotApplicable'
)

function Test-XboxOSWildcardMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Pattern
    )
    foreach ($p in @($Pattern -split '\|')) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ($Text -like $p.Trim()) { return $true }
    }
    return $false
}

function New-XboxOSInventoryProvenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Authoritative', 'FixtureDerived', 'Synthetic')]
        [string]$SourceType,
        [Parameter(Mandatory)]
        [ValidateSet('Authoritative', 'Unverified', 'Blocked', 'Synthetic')]
        [string]$VerificationLevel,
        [Parameter(Mandatory)][string]$SourcePath,
        [ValidateSet('None', 'Simulation', 'FailClosed')]
        [string]$FallbackMode = 'None',
        [string[]]$Notes = @()
    )
    [pscustomobject]@{
        sourceType         = $SourceType
        verificationLevel  = $VerificationLevel
        sourcePath         = $SourcePath
        fallbackMode       = $FallbackMode
        notes              = [string[]]@($Notes)
        allowsReadyForReview = ($SourceType -eq 'Authoritative' -and $VerificationLevel -eq 'Authoritative')
    }
}

function Get-XboxOSReportTraceability {
    [CmdletBinding()]
    param([string]$RepoRoot)

    $warnings = New-Object System.Collections.Generic.List[string]
    $commit = 'Unknown'
    $dirty = $null
    $branch = 'Unknown'
    $verified = $false

    try {
        if (-not $RepoRoot) { $RepoRoot = Get-XboxOSRepoRoot }
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            $warnings.Add('Git executable not found; commit traceability is Unknown.') | Out-Null
        }
        else {
            $sha = & git -C $RepoRoot rev-parse HEAD 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$sha)) {
                $commit = ([string]$sha).Trim()
                $verified = $true
            }
            else { $warnings.Add('git rev-parse HEAD failed; commit traceability is Unknown.') | Out-Null }

            $br = & git -C $RepoRoot rev-parse --abbrev-ref HEAD 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$br)) {
                $branch = ([string]$br).Trim()
            }

            $porcelain = & git -C $RepoRoot status --porcelain 2>$null
            if ($LASTEXITCODE -eq 0) {
                $dirty = @($porcelain | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
                if ($dirty) { $warnings.Add('Working tree is dirty; report Git SHA may not match committed content.') | Out-Null }
            }
            else {
                $warnings.Add('git status --porcelain failed; dirty-tree status is Unknown.') | Out-Null
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
        notes        = @($notes.ToArray())
    }
}

function Import-XboxOSDependencyEvidenceCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Dependency evidence catalog not found: $Path" }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$raw.schemaVersion -ne (Get-XboxOSDependencyEvidenceSchemaVersion)) {
        throw ("Unsupported dependency evidence schema '{0}'." -f $raw.schemaVersion)
    }
    $raw
}

function Import-XboxOSCapabilityRequirementsCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Capability requirements catalog not found: $Path" }
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
    if ($EvidenceRecord.PSObject.Properties['stalenessDays']) { $days = [int]$EvidenceRecord.stalenessDays }
    $anchor = $null
    if ($EvidenceRecord.PSObject.Properties['verifiedUtc'] -and $EvidenceRecord.verifiedUtc) {
        $anchor = [datetime]::Parse([string]$EvidenceRecord.verifiedUtc).ToUniversalTime()
    }
    elseif ($EvidenceRecord.PSObject.Properties['collectedUtc'] -and $EvidenceRecord.collectedUtc) {
        $anchor = [datetime]::Parse([string]$EvidenceRecord.collectedUtc).ToUniversalTime()
    }
    if ($null -ne $anchor -and $days -gt 0 -and $AsOfUtc -gt $anchor.AddDays($days)) {
        $stale = $true
        $reason = ('Evidence {0} exceeded stalenessDays={1}.' -f $EvidenceRecord.evidenceId, $days)
    }
    [pscustomobject]@{ evidenceId = [string]$EvidenceRecord.evidenceId; stale = [bool]$stale; reason = $reason }
}

function Test-XboxOSDependencyEvidenceCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$EvidenceCatalog,
        $ExpectedBuild = $null,
        $ExpectedEdition = $null
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $componentIds = @{}
    $evidenceIds = @{}
    $relationshipIds = @{}

    foreach ($c in @($EvidenceCatalog.components)) {
        $id = [string]$c.id
        if ([string]::IsNullOrWhiteSpace($id)) { $errors.Add('Component with empty id.') | Out-Null; continue }
        if ($componentIds.ContainsKey($id)) { $errors.Add(('Duplicate component id: {0}' -f $id)) | Out-Null }
        else { $componentIds[$id] = $true }
    }
    foreach ($ev in @($EvidenceCatalog.evidence)) {
        $id = [string]$ev.evidenceId
        if ([string]::IsNullOrWhiteSpace($id)) { $errors.Add('Evidence with empty evidenceId.') | Out-Null; continue }
        if ($evidenceIds.ContainsKey($id)) { $errors.Add(('Duplicate evidence id: {0}' -f $id)) | Out-Null }
        else { $evidenceIds[$id] = $true }
        if ($script:XboxOSValidSourceTypes -notcontains [string]$ev.sourceType) {
            $errors.Add(('Invalid sourceType on {0}: {1}' -f $id, $ev.sourceType)) | Out-Null
        }
        if (-not ($ev.PSObject.Properties['stalenessDays']) -or [int]$ev.stalenessDays -lt 0) {
            $errors.Add(('Invalid stalenessDays on {0}.' -f $id)) | Out-Null
        }
        foreach ($tsName in @('collectedUtc', 'verifiedUtc')) {
            if ($ev.PSObject.Properties[$tsName] -and $ev.$tsName) {
                try { [void][datetime]::Parse([string]$ev.$tsName) }
                catch { $errors.Add(('Invalid {0} on {1}.' -f $tsName, $id)) | Out-Null }
            }
        }
        if ($ExpectedBuild -and $ev.PSObject.Properties['buildApplicability'] -and $ev.buildApplicability) {
            if ([string]$ev.buildApplicability -ne [string]$ExpectedBuild) {
                $warnings.Add(('Evidence {0} buildApplicability {1} != expected {2}.' -f $id, $ev.buildApplicability, $ExpectedBuild)) | Out-Null
            }
        }
        if ($ExpectedEdition -and $ev.PSObject.Properties['editionApplicability'] -and $ev.editionApplicability) {
            if ([string]$ev.editionApplicability -ne [string]$ExpectedEdition) {
                $warnings.Add(('Evidence {0} editionApplicability {1} != expected {2}.' -f $id, $ev.editionApplicability, $ExpectedEdition)) | Out-Null
            }
        }
    }

    $knownNodes = @{}
    foreach ($k in @($componentIds.Keys)) { $knownNodes[$k] = $true }
    foreach ($capPrefix in @('capability:')) { } # capabilities also added by graph from capability catalog; catalog components must cover relationship endpoints

    foreach ($rel in @($EvidenceCatalog.relationships)) {
        $rid = [string]$rel.relationshipId
        if ([string]::IsNullOrWhiteSpace($rid)) { $errors.Add('Relationship with empty relationshipId.') | Out-Null; continue }
        if ($relationshipIds.ContainsKey($rid)) { $errors.Add(('Duplicate relationship id: {0}' -f $rid)) | Out-Null }
        else { $relationshipIds[$rid] = $true }
        if ($script:XboxOSValidRelationshipKinds -notcontains [string]$rel.kind) {
            $errors.Add(('Invalid relationship kind on {0}: {1}' -f $rid, $rel.kind)) | Out-Null
        }
        foreach ($end in @([string]$rel.from, [string]$rel.to)) {
            if (-not $knownNodes.ContainsKey($end)) {
                $errors.Add(('Dangling graph endpoint on {0}: {1}' -f $rid, $end)) | Out-Null
            }
        }
        if ([string]$rel.from -eq [string]$rel.to -and [string]$rel.kind -eq 'Provides') {
            $errors.Add(('Self-loop Provides is not allowed: {0}' -f $rid)) | Out-Null
        }
        foreach ($eid in @($rel.evidenceIds)) {
            if (-not $evidenceIds.ContainsKey([string]$eid)) {
                $errors.Add(('Relationship {0} references missing evidence {1}.' -f $rid, $eid)) | Out-Null
            }
        }
    }

    $assessmentKeys = @{}
    foreach ($a in @($EvidenceCatalog.operationAssessments)) {
        if ($script:XboxOSValidReadiness -notcontains [string]$a.readiness) {
            $errors.Add(('Unsupported readiness classification: {0} ({1}/{2})' -f $a.readiness, $a.manifestRuleId, $a.operationType)) | Out-Null
        }
        if ([string]::IsNullOrWhiteSpace([string]$a.targetIdentityPattern)) {
            $errors.Add(('Malformed empty targetIdentityPattern for {0}.' -f $a.manifestRuleId)) | Out-Null
        }
        $key = '{0}|{1}|{2}' -f $a.manifestRuleId, $a.operationType, $a.targetIdentityPattern
        if ($assessmentKeys.ContainsKey($key)) {
            $errors.Add(('Conflicting/duplicate operation assessment: {0}' -f $key)) | Out-Null
        }
        else { $assessmentKeys[$key] = $true }
        foreach ($eid in @($a.evidenceIds)) {
            if (-not $evidenceIds.ContainsKey([string]$eid)) {
                $errors.Add(('Operation assessment {0} references missing evidence {1}.' -f $a.manifestRuleId, $eid)) | Out-Null
            }
        }
    }

    $affectsSafety = $errors.Count -gt 0
    [pscustomobject]@{
        valid              = ($errors.Count -eq 0)
        affectsSafety      = [bool]$affectsSafety
        errors             = [string[]]@($errors.ToArray())
        warnings           = [string[]]@($warnings.ToArray())
        componentCount     = $componentIds.Count
        evidenceCount      = $evidenceIds.Count
        relationshipCount  = $relationshipIds.Count
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
    $seen = @{}

    foreach ($c in @($EvidenceCatalog.components)) {
        $id = [string]$c.id
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id] = $true
        $nodes.Add([pscustomobject]@{
                id = $id; kind = [string]$c.kind; displayName = [string]$c.displayName
                origin = 'catalog'; critical = $false; presentInInventory = $false
            }) | Out-Null
    }

    foreach ($name in @($Inventory.appxPackages)) {
        $id = 'appx:{0}' -f $name
        if (-not $seen.ContainsKey($id)) {
            $seen[$id] = $true
            $nodes.Add([pscustomobject]@{
                    id = $id; kind = 'AppX'; displayName = [string]$name
                    origin = 'inventory-observation'; critical = $false; presentInInventory = $true
                }) | Out-Null
        }
        else {
            foreach ($n in $nodes) {
                if ($n.id -eq $id) { $n.presentInInventory = $true; break }
            }
        }
        # Family alias for Store Provides edge resolution
        if ($name -like 'Microsoft.WindowsStore*') {
            $fam = 'appx:Microsoft.WindowsStore'
            if ($seen.ContainsKey($fam)) {
                foreach ($n in $nodes) {
                    if ($n.id -eq $fam) { $n.presentInInventory = $true; break }
                }
            }
        }
    }

    foreach ($f in @($Inventory.features)) {
        $fname = if ($f.PSObject.Properties['Name']) { [string]$f.Name } elseif ($f.PSObject.Properties['FeatureName']) { [string]$f.FeatureName } else { [string]$f }
        $id = 'feature:{0}' -f $fname
        if ($seen.ContainsKey($id)) {
            foreach ($n in $nodes) { if ($n.id -eq $id) { $n.presentInInventory = $true; break } }
        }
        else {
            $seen[$id] = $true
            $nodes.Add([pscustomobject]@{
                    id = $id; kind = 'Feature'; displayName = $fname
                    origin = 'inventory-observation'; critical = $false; presentInInventory = $true
                }) | Out-Null
        }
    }

    foreach ($cap in @($CapabilityCatalog.capabilities)) {
        $id = 'capability:{0}' -f $cap.id
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id] = $true
        $nodes.Add([pscustomobject]@{
                id = $id; kind = 'Capability'; displayName = [string]$cap.label
                origin = 'capability-catalog'; critical = [bool]$cap.critical; presentInInventory = $false
            }) | Out-Null
    }

    # Curated edges only — no synthetic self-loop Provides.
    foreach ($rel in @($EvidenceCatalog.relationships)) {
        $edges.Add([pscustomobject]@{
                relationshipId = [string]$rel.relationshipId
                from           = [string]$rel.from
                to             = [string]$rel.to
                kind           = [string]$rel.kind
                phase          = [string]$rel.phase
                evidenceIds    = @($rel.evidenceIds | ForEach-Object { [string]$_ })
                notes          = @(if ($rel.PSObject.Properties['notes'] -and $null -ne $rel.notes) { @($rel.notes | ForEach-Object { [string]$_ }) } else { @() })
            }) | Out-Null
    }

    [pscustomobject]@{
        graphSchemaVersion = 'dependency-graph-v1'
        nodeCount          = [int]$nodes.Count
        edgeCount          = [int]$edges.Count
        nodes              = @($nodes.ToArray())
        edges              = @($edges.ToArray())
    }
}

function Resolve-XboxOSOperationComponentNodeId {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Operation)
    if ([string]$Operation.operationType -eq 'RemoveProvisionedAppx') {
        return ('appx:{0}' -f [string]$Operation.targetIdentity)
    }
    if ([string]$Operation.operationType -eq 'DisableOptionalFeature') {
        return ('feature:{0}' -f [string]$Operation.targetIdentity)
    }
    return ('unknown:{0}' -f [string]$Operation.targetIdentity)
}

function Get-XboxOSOperationDependencyClosure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Operation,
        [Parameter(Mandatory)]$DependencyGraph
    )

    $rootId = Resolve-XboxOSOperationComponentNodeId -Operation $Operation
    $nodeSet = @{}
    foreach ($n in @($DependencyGraph.nodes)) { $nodeSet[[string]$n.id] = $n }

    $direct = New-Object System.Collections.Generic.List[object]
    $transitive = New-Object System.Collections.Generic.List[object]
    $shared = New-Object System.Collections.Generic.List[object]
    $unknown = New-Object System.Collections.Generic.List[object]
    $paths = New-Object System.Collections.Generic.List[string]
    $unresolved = New-Object System.Collections.Generic.List[string]
    $cycles = New-Object System.Collections.Generic.List[string]
    $capabilityPaths = New-Object System.Collections.Generic.List[object]

    if (-not $nodeSet.ContainsKey($rootId)) {
        $unresolved.Add(('Component node not found in graph: {0}' -f $rootId)) | Out-Null
        return [pscustomobject]@{
            rootNodeId           = $rootId
            completeness         = 'Incomplete'
            directDependencies   = @()
            transitiveDependencies = @()
            sharedDependencies   = @()
            unknownRelationships = @()
            capabilityPaths      = @()
            paths                = @()
            unresolvedEndpoints  = @($unresolved.ToArray())
            cyclesDetected       = @()
            notes                = @('Absence of known edges is not proof of independence.')
        }
    }

    # Direct edges touching the root
    foreach ($e in @($DependencyGraph.edges)) {
        $touches = ($e.from -eq $rootId -or $e.to -eq $rootId)
        if (-not $touches) { continue }
        if ($e.kind -eq 'SharedDependency') {
            # Only operation-scoped when root participates.
            $shared.Add($e) | Out-Null
            $paths.Add(('{0} -[{1}/{2}]-> {3}' -f $e.from, $e.kind, $e.relationshipId, $e.to)) | Out-Null
            continue
        }
        if ($e.kind -eq 'UnknownRelationship') {
            $unknown.Add($e) | Out-Null
            $paths.Add(('{0} -[{1}/{2}]-> {3}' -f $e.from, $e.kind, $e.relationshipId, $e.to)) | Out-Null
        }
        if ($e.kind -in @('Requires', 'Provides', 'OptionalDependency', 'ConflictsWith', 'UnknownRelationship')) {
            $direct.Add($e) | Out-Null
            $paths.Add(('{0} -[{1}/{2}]-> {3}' -f $e.from, $e.kind, $e.relationshipId, $e.to)) | Out-Null
        }
    }

    # BFS transitive over Requires/OptionalDependency/Provides (excluding pure SharedDependency unless already on root)
    $queue = New-Object System.Collections.Generic.Queue[string]
    $visited = @{}
    $stackPath = @{}
    $queue.Enqueue($rootId)
    $visited[$rootId] = $true
    $stackPath[$rootId] = @($rootId)

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        foreach ($e in @($DependencyGraph.edges)) {
            if ($e.kind -eq 'SharedDependency') { continue }
            $next = $null
            if ($e.from -eq $current) { $next = [string]$e.to }
            elseif ($e.to -eq $current -and $e.kind -eq 'Provides') { $next = [string]$e.from }
            elseif ($e.to -eq $current -and $e.kind -eq 'Requires') { $next = [string]$e.from }
            if ($null -eq $next) { continue }

            if (-not $nodeSet.ContainsKey($next)) {
                $unresolved.Add(('Unresolved endpoint {0} via {1}' -f $next, $e.relationshipId)) | Out-Null
                continue
            }

            $pathList = @($stackPath[$current] + $next)
            if ($visited.ContainsKey($next)) {
                if ($stackPath.ContainsKey($next) -and ($stackPath[$current] -contains $next)) {
                    $cycles.Add(($pathList -join ' -> ')) | Out-Null
                }
                continue
            }

            $visited[$next] = $true
            $stackPath[$next] = $pathList
            if ($current -ne $rootId -or $e.from -ne $rootId) {
                if ($e.from -eq $rootId -or $e.to -eq $rootId) {
                    # already counted as direct
                }
                else {
                    $transitive.Add($e) | Out-Null
                    $paths.Add(($pathList -join ' -> ')) | Out-Null
                }
            }
            else {
                # first hop already in direct
            }

            if ($next -like 'capability:*') {
                $capabilityPaths.Add([pscustomobject]@{
                        capabilityId = $next
                        path         = ($pathList -join ' -> ')
                        viaKind      = [string]$e.kind
                        relationshipId = [string]$e.relationshipId
                    }) | Out-Null
            }

            if ($e.kind -in @('Requires', 'OptionalDependency', 'Provides', 'UnknownRelationship')) {
                $queue.Enqueue($next)
            }
        }
    }

    # Completeness: Incomplete unless no unknown edges, no unresolved endpoints, and at least one evidenced Requires/Provides closure statement.
    # Absence of edges is NOT complete.
    $completeness = 'Incomplete'
    $notes = New-Object System.Collections.Generic.List[string]
    $notes.Add('Absence of known edges is not proof of independence.') | Out-Null
    if ($unknown.Count -gt 0) {
        $notes.Add('UnknownRelationship edges touch this component; dependency closure cannot be complete.') | Out-Null
    }
    if ($unresolved.Count -gt 0) {
        $notes.Add('Unresolved graph endpoints prevent complete closure.') | Out-Null
    }
    if ($direct.Count -eq 0 -and $transitive.Count -eq 0) {
        $notes.Add('No operation-scoped Requires/Provides edges found; closure incomplete by fail-closed policy.') | Out-Null
    }
    # Complete only when there are no Unknown/unresolved and every direct edge has evidence ids (still conservative: never mark Complete in M5.1 without explicit Requires closure proof)
    # Keep Incomplete always for M5.1 unless we have Provides/Requires with evidence and zero Unknown — still treat as Incomplete if no positive independence proof.
    if ($unknown.Count -eq 0 -and $unresolved.Count -eq 0 -and $cycles.Count -eq 0) {
        $hasDocumentedRequires = @($direct + $transitive | Where-Object { $_.kind -eq 'Requires' }).Count -gt 0
        if ($hasDocumentedRequires) {
            $completeness = 'Partial'
            $notes.Add('Requires edges present; Partial closure only (transitive uncertainty may remain).') | Out-Null
        }
        else {
            $completeness = 'Incomplete'
        }
    }

    [pscustomobject]@{
        rootNodeId             = $rootId
        completeness           = $completeness
        directDependencies     = @($direct.ToArray())
        transitiveDependencies = @($transitive.ToArray())
        sharedDependencies     = @($shared.ToArray())
        unknownRelationships   = @($unknown.ToArray())
        capabilityPaths        = @($capabilityPaths.ToArray())
        paths                  = [string[]]@($paths.ToArray() | Select-Object -Unique)
        unresolvedEndpoints    = [string[]]@($unresolved.ToArray())
        cyclesDetected         = [string[]]@($cycles.ToArray())
        notes                  = [string[]]@($notes.ToArray())
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
        return [pscustomobject]@{ conflicting = $true; matches = $matches }
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
            if ([string]$ev.evidenceId -eq [string]$id) { $out.Add($ev) | Out-Null; break }
        }
    }
    [pscustomobject]@{ records = [object[]]@($out.ToArray()) }
}

function Test-XboxOSEvidenceContradiction {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$EvidenceRecords = @(),
        [string]$OperationId = '',
        [string]$TargetIdentity = '',
        [string[]]$ComponentIds = @()
    )

    $related = New-Object System.Collections.Generic.List[object]
    foreach ($ev in @($EvidenceRecords)) {
        if ($null -eq $ev) { continue }
        $comp = if ($ev.PSObject.Properties['componentIdentity']) { [string]$ev.componentIdentity } else { '' }
        $ops = @()
        if ($ev.PSObject.Properties['relatedOperationIds'] -and $null -ne $ev.relatedOperationIds) {
            $ops = @($ev.relatedOperationIds | ForEach-Object { [string]$_ })
        }
        $applies = $false
        if ($OperationId -and ($ops -contains $OperationId)) { $applies = $true }
        if ($TargetIdentity -and $comp -and ($comp -like ('*{0}*' -f $TargetIdentity) -or $TargetIdentity -like ('*{0}*' -f ($comp -replace '^(appx|feature|capability|runtime):', '')))) { $applies = $true }
        foreach ($cid in @($ComponentIds)) {
            if ($cid -and $comp -eq $cid) { $applies = $true }
        }
        # Policy / inventory records with empty relatedOperationIds apply only when explicitly listed for the operation assessment (already filtered into EvidenceRecords).
        if ($ops.Count -eq 0 -and [string]::IsNullOrWhiteSpace($OperationId) -eq $false) {
            # Included because the assessment referenced this evidence id — treat as related for that assessment scope.
            $applies = $true
        }
        if ($applies) { $related.Add($ev) | Out-Null }
    }

    $conflictIds = New-Object System.Collections.Generic.List[string]
    $support = New-Object System.Collections.Generic.List[string]
    $contra = New-Object System.Collections.Generic.List[string]

    $relatedArr = [object[]]@($related.ToArray())
    foreach ($ev in $relatedArr) {
        $s = @(); $c = @()
        if ($ev.PSObject.Properties['supportingFindings'] -and $null -ne $ev.supportingFindings) { $s = @($ev.supportingFindings) }
        if ($ev.PSObject.Properties['contradictingFindings'] -and $null -ne $ev.contradictingFindings) { $c = @($ev.contradictingFindings) }
        if ($s.Count -gt 0 -and $c.Count -gt 0) {
            $conflictIds.Add([string]$ev.evidenceId) | Out-Null
            foreach ($x in $s) { if ($x) { $support.Add([string]$x) | Out-Null } }
            foreach ($x in $c) { if ($x) { $contra.Add([string]$x) | Out-Null } }
        }
    }

    # Cross-record: same componentIdentity among related, one supports and another contradicts
    $byComp = @{}
    foreach ($ev in $relatedArr) {
        $comp = if ($ev.PSObject.Properties['componentIdentity']) { [string]$ev.componentIdentity } else { '' }
        if ([string]::IsNullOrWhiteSpace($comp)) { continue }
        if (-not $byComp.ContainsKey($comp)) { $byComp[$comp] = New-Object System.Collections.Generic.List[object] }
        $byComp[$comp].Add($ev) | Out-Null
    }
    foreach ($comp in @($byComp.Keys)) {
        $group = [object[]]@($byComp[$comp].ToArray())
        $hasS = $false; $hasC = $false
        $idsS = New-Object System.Collections.Generic.List[string]
        $idsC = New-Object System.Collections.Generic.List[string]
        foreach ($ev in $group) {
            if ($ev.PSObject.Properties['supportingFindings'] -and @($ev.supportingFindings).Count -gt 0) {
                $hasS = $true
                $idsS.Add([string]$ev.evidenceId) | Out-Null
            }
            if ($ev.PSObject.Properties['contradictingFindings'] -and @($ev.contradictingFindings).Count -gt 0) {
                $hasC = $true
                $idsC.Add([string]$ev.evidenceId) | Out-Null
            }
        }
        if ($hasS -and $hasC) {
            foreach ($id in @($idsS.ToArray() + $idsC.ToArray() | Select-Object -Unique)) {
                $conflictIds.Add([string]$id) | Out-Null
            }
        }
    }

    [pscustomobject]@{
        conflicting            = [bool]($conflictIds.Count -gt 0)
        conflictingEvidenceIds = [string[]]@($conflictIds.ToArray() | Select-Object -Unique)
        supportingFindings     = [string[]]@($support.ToArray())
        contradictingFindings  = [string[]]@($contra.ToArray())
        relatedEvidenceCount   = [int]$related.Count
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
        [Parameter(Mandatory)]$DependencyGraph,
        [Parameter(Mandatory)]$InventoryProvenance,
        [Parameter(Mandatory)]$CatalogValidation,
        [string]$ExpectedBuild = '',
        [string]$ExpectedEdition = ''
    )

    $uncertainties = New-Object System.Collections.Generic.List[string]
    $blockers = New-Object System.Collections.Generic.List[string]
    $validationSteps = New-Object System.Collections.Generic.List[string]
    $requiredTests = New-Object System.Collections.Generic.List[string]
    $affectedCaps = New-Object System.Collections.Generic.List[string]
    $catalogCandidate = $null

    $base = {
        param($readiness)
        [pscustomobject]@{
            operationId             = [string]$Operation.operationId
            manifestRuleId          = [string]$Operation.manifestRuleId
            operationType           = [string]$Operation.operationType
            targetIdentity          = [string]$Operation.targetIdentity
            planStatus              = [string]$Operation.status
            readiness               = $readiness
            catalogCandidateReadiness = $catalogCandidate
            directDependencies      = @()
            transitiveDependencies  = @()
            sharedDependencies      = @()
            affectedCapabilities    = @()
            evidenceRecords         = @()
            dependencyClosure       = $null
            uncertainties           = @($uncertainties.ToArray())
            validationSteps         = @($validationSteps.ToArray())
            requiredFunctionalTests = @($requiredTests.ToArray())
            blockers                = @($blockers.ToArray() | Select-Object -Unique)
            contradiction           = $null
        }
    }

    if ([string]$Operation.status -ne 'Eligible') {
        $uncertainties.Add('Operation is not Eligible in the Milestone 2 plan.') | Out-Null
        return (& $base 'NotApplicable')
    }

    $exactIdentity = [string]$Operation.targetIdentity
    $closure = Get-XboxOSOperationDependencyClosure -Operation $Operation -DependencyGraph $DependencyGraph

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
        $r = & $base 'KnownUnsafe'
        $r.dependencyClosure = $closure
        $r.sharedDependencies = @($closure.sharedDependencies)
        $r.affectedCapabilities = @($CapabilityInspection.results | Where-Object critical | ForEach-Object { $_.capabilityId })
        $r.evidenceRecords = @((Get-XboxOSRelatedEvidenceRecords -EvidenceIds @('ev-compat-protected-patterns') -EvidenceCatalog $EvidenceCatalog).records)
        return $r
    }

    if (-not [bool]$CatalogValidation.valid) {
        $blockers.Add('Catalog validation failed; positive readiness forbidden.') | Out-Null
        foreach ($err in @($CatalogValidation.errors | Select-Object -First 5)) { $blockers.Add(('Catalog: {0}' -f $err)) | Out-Null }
    }

    $catalogAssessment = Resolve-XboxOSCatalogOperationAssessment -Operation $Operation -EvidenceCatalog $EvidenceCatalog
    if ($null -eq $catalogAssessment) {
        $blockers.Add('Missing curated dependency evidence for Eligible operation.') | Out-Null
        $r = & $base 'MissingEvidence'
        $r.dependencyClosure = $closure
        $r.evidenceRecords = @((Get-XboxOSRelatedEvidenceRecords -EvidenceIds @('ev-consumer-appx-missing-removal-contract') -EvidenceCatalog $EvidenceCatalog).records)
        return $r
    }
    if ($catalogAssessment.PSObject.Properties['conflicting'] -and $catalogAssessment.conflicting) {
        $blockers.Add('Conflicting curated assessments') | Out-Null
        $r = & $base 'ConflictingEvidence'
        $r.dependencyClosure = $closure
        return $r
    }

    $catalogCandidate = [string]$catalogAssessment.readiness
    $evidenceRecords = @((Get-XboxOSRelatedEvidenceRecords -EvidenceIds @($catalogAssessment.evidenceIds) -EvidenceCatalog $EvidenceCatalog).records)
    $missingEvidenceIds = @($catalogAssessment.evidenceIds | Where-Object { $id = $_; -not (@($evidenceRecords | Where-Object { $_.evidenceId -eq $id })) })
    if ($missingEvidenceIds.Count -gt 0) {
        $blockers.Add(('Missing evidence records: {0}' -f ($missingEvidenceIds -join ', '))) | Out-Null
    }

    $freshnessIssues = @()
    foreach ($ev in $evidenceRecords) {
        $fr = Test-XboxOSEvidenceFreshness -EvidenceRecord $ev
        if ($fr.stale) { $freshnessIssues += $fr.reason; $uncertainties.Add($fr.reason) | Out-Null }
        if ($ExpectedBuild -and $ev.buildApplicability -and [string]$ev.buildApplicability -ne [string]$ExpectedBuild) {
            $uncertainties.Add(('Evidence {0} buildApplicability mismatch.' -f $ev.evidenceId)) | Out-Null
        }
        if ($ExpectedEdition -and $ev.editionApplicability -and [string]$ev.editionApplicability -ne [string]$ExpectedEdition) {
            $uncertainties.Add(('Evidence {0} editionApplicability mismatch.' -f $ev.evidenceId)) | Out-Null
        }
    }

    $contradiction = Test-XboxOSEvidenceContradiction `
        -EvidenceRecords $evidenceRecords `
        -OperationId ([string]$Operation.operationId) `
        -TargetIdentity $exactIdentity `
        -ComponentIds @($closure.rootNodeId)

    foreach ($id in @($catalogAssessment.affectedCapabilityIds)) { $affectedCaps.Add([string]$id) | Out-Null }
    foreach ($t in @($catalogAssessment.requiredFunctionalTests)) { $requiredTests.Add([string]$t) | Out-Null }
    foreach ($v in @($catalogAssessment.validationSteps)) { $validationSteps.Add([string]$v) | Out-Null }

    $readiness = [string]$catalogCandidate
    if ($readiness -notin @('MissingEvidence', 'KnownUnsafe', 'ConflictingEvidence', 'Unsupported', 'VerifiedSafeForConsideration')) {
        $readiness = 'MissingEvidence'
    }

    # Start from catalog candidate, then apply hard gates for VerifiedSafeForConsideration
    if ($readiness -eq 'VerifiedSafeForConsideration') {
        $gates = New-Object System.Collections.Generic.List[string]
        if ($InventoryProvenance.sourceType -ne 'Authoritative' -or $InventoryProvenance.verificationLevel -ne 'Authoritative') {
            $gates.Add('Authoritative applicable inventory required.') | Out-Null
        }
        if (-not [bool]$CatalogValidation.valid) { $gates.Add('Catalog validation errors present.') | Out-Null }
        if ($missingEvidenceIds.Count -gt 0) { $gates.Add('Evidence references unresolved.') | Out-Null }
        if ($evidenceRecords.Count -eq 0) { $gates.Add('No evidence records resolved.') | Out-Null }
        $nonAssumption = @($evidenceRecords | Where-Object {
                [string]$_.sourceType -in @('AuthoritativeDocumentation', 'DirectlyObserved', 'ManifestDeclared') -and
                [string]$_.quality -in @('High', 'Medium')
            })
        if ($nonAssumption.Count -eq 0) { $gates.Add('Insufficient provenance (Assumption/Insufficient cannot elevate).') | Out-Null }
        if ($freshnessIssues.Count -gt 0) { $gates.Add('Stale evidence.') | Out-Null }
        if ($contradiction.conflicting) { $gates.Add(('Contradictory evidence: {0}' -f ($contradiction.conflictingEvidenceIds -join ', '))) | Out-Null }
        if ($closure.completeness -ne 'Complete') {
            $gates.Add(('Dependency closure completeness is {0}; VerifiedSafeForConsideration requires Complete closure.' -f $closure.completeness)) | Out-Null
        }
        if (@($closure.unknownRelationships).Count -gt 0) {
            $gates.Add('Unresolved UnknownRelationship edges on operation graph.') | Out-Null
        }
        if (@($closure.unresolvedEndpoints).Count -gt 0) {
            $gates.Add('Unresolved graph endpoints.') | Out-Null
        }
        if (@($closure.capabilityPaths | Where-Object { $_.viaKind -eq 'UnknownRelationship' }).Count -gt 0) {
            $gates.Add('Critical/unknown capability graph paths unresolved.') | Out-Null
        }
        # Protected capability regression: capability paths via ConflictsWith
        if (@($closure.capabilityPaths | Where-Object { $_.viaKind -eq 'ConflictsWith' }).Count -gt 0) {
            $gates.Add('ConflictsWith path to a capability.') | Out-Null
            $readiness = 'KnownUnsafe'
        }

        if ($gates.Count -gt 0 -and $readiness -eq 'VerifiedSafeForConsideration') {
            $readiness = 'MissingEvidence'
            foreach ($g in $gates) { $blockers.Add($g) | Out-Null }
            $uncertainties.Add('Catalog candidate VerifiedSafeForConsideration downgraded; dependency safety not established.') | Out-Null
        }
        elseif ($gates.Count -gt 0 -and $readiness -eq 'KnownUnsafe') {
            foreach ($g in $gates) { $blockers.Add($g) | Out-Null }
        }
    }

    if ($readiness -eq 'MissingEvidence') {
        $blockers.Add('Eligible operation lacks sufficient operation-specific dependency evidence.') | Out-Null
    }

    foreach ($n in @($closure.notes)) { $uncertainties.Add([string]$n) | Out-Null }

    [pscustomobject]@{
        operationId               = [string]$Operation.operationId
        manifestRuleId            = [string]$Operation.manifestRuleId
        operationType             = [string]$Operation.operationType
        targetIdentity            = $exactIdentity
        planStatus                = [string]$Operation.status
        readiness                 = $readiness
        catalogCandidateReadiness = $catalogCandidate
        directDependencies        = @($closure.directDependencies)
        transitiveDependencies    = @($closure.transitiveDependencies)
        sharedDependencies        = @($closure.sharedDependencies)
        affectedCapabilities      = @($affectedCaps.ToArray())
        evidenceRecords           = @($evidenceRecords | ForEach-Object {
                [pscustomobject]@{
                    evidenceId            = $_.evidenceId
                    sourceType            = $_.sourceType
                    sourceReference       = $_.sourceReference
                    quality               = $_.quality
                    componentIdentity     = $(if ($_.PSObject.Properties['componentIdentity']) { $_.componentIdentity } else { $null })
                    buildApplicability    = $_.buildApplicability
                    editionApplicability  = $_.editionApplicability
                    collectedUtc          = $_.collectedUtc
                    verifiedUtc           = $_.verifiedUtc
                    knownLimitations      = @($_.knownLimitations)
                    supportingFindings    = @($_.supportingFindings)
                    contradictingFindings = @($_.contradictingFindings)
                }
            })
        dependencyClosure         = $closure
        uncertainties             = [string[]]@($uncertainties.ToArray() | Select-Object -Unique)
        validationSteps           = [string[]]@($validationSteps.ToArray())
        requiredFunctionalTests   = [string[]]@($requiredTests.ToArray())
        blockers                  = [string[]]@($blockers.ToArray() | Select-Object -Unique)
        contradiction             = $contradiction
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
        [Parameter(Mandatory)]$InventoryProvenance,
        $CompatReport = $null,
        [string]$RepoRoot
    )

    Assert-XboxOSExecutionSafetyInvariants

    $editionName = $null; $buildNumber = $null; $displayVersion = $null; $isoSha256 = $null; $sourceIndex = $null
    if ($Inventory.PSObject.Properties['sourceImage'] -and $Inventory.sourceImage) {
        $si = $Inventory.sourceImage
        if ($si.PSObject.Properties['editionName']) { $editionName = [string]$si.editionName }
        if ($si.PSObject.Properties['buildNumber']) { $buildNumber = [string]$si.buildNumber }
        if ($si.PSObject.Properties['displayVersion']) { $displayVersion = [string]$si.displayVersion }
        if ($si.PSObject.Properties['isoSha256']) { $isoSha256 = [string]$si.isoSha256 }
        if ($si.PSObject.Properties['sourceIndex']) { $sourceIndex = $si.sourceIndex }
    }

    $catalogValidation = Test-XboxOSDependencyEvidenceCatalog `
        -EvidenceCatalog $EvidenceCatalog `
        -ExpectedBuild $buildNumber `
        -ExpectedEdition $editionName

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
                    -DependencyGraph $graph `
                    -InventoryProvenance $InventoryProvenance `
                    -CatalogValidation $catalogValidation `
                    -ExpectedBuild $(if ($buildNumber) { $buildNumber } else { '' }) `
                    -ExpectedEdition $(if ($editionName) { $editionName } else { '' })
            )) | Out-Null
    }

    $eligibleAssessments = @($assessments | Where-Object { $_.planStatus -eq 'Eligible' })
    $blockers = New-Object System.Collections.Generic.List[string]
    foreach ($err in @($catalogValidation.errors)) { $blockers.Add(('Catalog validation: {0}' -f $err)) | Out-Null }

    $criticalUnresolved = @($eligibleAssessments | Where-Object {
            $_.readiness -in @('MissingEvidence', 'ConflictingEvidence', 'KnownUnsafe', 'Unsupported')
        })
    foreach ($a in $criticalUnresolved) {
        $blockers.Add(('Operation {0} readiness={1}' -f $a.operationId, $a.readiness)) | Out-Null
    }
    foreach ($cap in @($capInspection.results | Where-Object { $_.critical -and $_.status -eq 'MissingEvidence' })) {
        $blockers.Add(('Critical capability {0} has MissingEvidence.' -f $cap.capabilityId)) | Out-Null
    }

    $decision = 'Blocked'
    if (-not [bool]$catalogValidation.valid) {
        $decision = 'Failed'
        $blockers.Add('Catalog integrity errors prevent a positive readiness decision.') | Out-Null
    }
    elseif (@($eligibleAssessments | Where-Object readiness -ne 'VerifiedSafeForConsideration').Count -eq 0 -and $eligibleAssessments.Count -gt 0) {
        if ([bool]$InventoryProvenance.allowsReadyForReview) {
            $decision = 'ReadyForReview'
        }
        else {
            $decision = 'Blocked'
            $blockers.Add(('Inventory sourceType {0} / verification {1} forbids production ReadyForReview.' -f $InventoryProvenance.sourceType, $InventoryProvenance.verificationLevel)) | Out-Null
        }
    }
    else {
        $decision = 'Blocked'
    }

    # Never allow ReadyForReview from fixture/synthetic
    if ($decision -eq 'ReadyForReview' -and -not [bool]$InventoryProvenance.allowsReadyForReview) {
        $decision = 'Blocked'
    }

    $sourceIndexText = if ($null -eq $sourceIndex) { '' } else { [string]$sourceIndex }
    $incompleteClosures = @($eligibleAssessments | Where-Object {
            $_.dependencyClosure -and $_.dependencyClosure.completeness -ne 'Complete'
        }).Count

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
        inventoryProvenance                 = $InventoryProvenance
        catalogValidation                   = $catalogValidation
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
        operationAssessments                = [object[]]@($assessments.ToArray())
        dependencyGraphSummary              = [pscustomobject]@{
            nodeCount              = [int]$graph.nodeCount
            edgeCount              = [int]$graph.edgeCount
            relationshipKinds      = [string[]]@($graph.edges | ForEach-Object { [string]$_.kind } | Select-Object -Unique | Sort-Object)
            incompleteClosureCount = [int]$incompleteClosures
        }
        capabilityInspection                = $capInspection
        blockers                            = [string[]]@($blockers.ToArray() | Select-Object -Unique)
        notes                               = [string[]]@(
            'Milestone 5.1 servicing-readiness analysis only.',
            'VerifiedSafeForConsideration does not authorize writable DISM.',
            'FixtureDerived/Synthetic inventory cannot produce production ReadyForReview.',
            'Catalog candidate readiness is an input; engine gates may downgrade.',
            'Prior M1/M4 reports are read-only and never rewritten.'
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

    $Assessment.git = Get-XboxOSReportTraceability -RepoRoot $RepoRoot
    $Assessment.generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $Assessment.realDismExecutionEnabled = $false
    $Assessment.modifyingCommandsInvoked = $false
    $Assessment.executionAuthorized = $false
    $Assessment.servicingAuthorized = $false

    $jsonPath = Join-Path $OutputDirectory ($Stem + '.json')
    $mdPath = Join-Path $OutputDirectory ($Stem + '.md')
    Set-Content -LiteralPath $jsonPath -Value (ConvertTo-XboxOSCanonicalJson -Value $Assessment) -Encoding utf8

    $md = New-Object System.Collections.Generic.List[string]
    $null = $md.Add('# XboxOS11 Servicing Readiness (Milestone 5.1)')
    $null = $md.Add('')
    $null = $md.Add(('- Engine: **{0}**' -f $Assessment.engineVersion))
    $null = $md.Add(('- Decision: **{0}**' -f $Assessment.decision))
    $null = $md.Add(('- Inventory source: **{0}** / verification **{1}**' -f $Assessment.inventoryProvenance.sourceType, $Assessment.inventoryProvenance.verificationLevel))
    $null = $md.Add(('- Inventory path: `{0}`' -f $Assessment.inventoryProvenance.sourcePath))
    $null = $md.Add(('- Fallback mode: **{0}**' -f $Assessment.inventoryProvenance.fallbackMode))
    $null = $md.Add(('- Catalog validation: **{0}** (errors: {1})' -f $Assessment.catalogValidation.valid, @($Assessment.catalogValidation.errors).Count))
    $null = $md.Add(('- Plan content hash: `{0}`' -f $Assessment.planContentHash))
    $null = $md.Add(('- Inventory fingerprint: `{0}`' -f $Assessment.inventoryFingerprint))
    $null = $md.Add(('- Source identity: `{0}` / `{1}` / `{2}`' -f $Assessment.sourceImage.editionName, $Assessment.sourceImage.buildNumber, $Assessment.sourceImage.displayVersion))
    $null = $md.Add(('- Architecture: **{0}** (source: {1})' -f $Assessment.sourceImage.architecture, $Assessment.sourceImage.architectureSource))
    $null = $md.Add(('- Git commit: `{0}`' -f $Assessment.git.gitCommitSha))
    $null = $md.Add(('- Git dirty: **{0}**' -f $Assessment.git.gitDirty))
    $null = $md.Add(('- Incomplete dependency closures: **{0}**' -f $Assessment.dependencyGraphSummary.incompleteClosureCount))
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
        if ($a.PSObject.Properties['catalogCandidateReadiness'] -and $a.catalogCandidateReadiness) {
            $null = $md.Add(('- Catalog candidate: **{0}**' -f $a.catalogCandidateReadiness))
        }
        if ($a.dependencyClosure) {
            $null = $md.Add(('- Dependency closure: **{0}**' -f $a.dependencyClosure.completeness))
            if (@($a.dependencyClosure.paths).Count -gt 0) {
                $null = $md.Add(('- Graph paths: {0}' -f (($a.dependencyClosure.paths | Select-Object -First 5) -join '; ')))
            }
        }
        if (@($a.blockers).Count -gt 0) { $null = $md.Add(('- Blockers: {0}' -f ($a.blockers -join '; '))) }
        $null = $md.Add('')
    }
    if (@($Assessment.catalogValidation.errors).Count -gt 0) {
        $null = $md.Add('## Catalog validation errors')
        $null = $md.Add('')
        foreach ($e in @($Assessment.catalogValidation.errors)) { $null = $md.Add(('- {0}' -f $e)) }
        $null = $md.Add('')
    }
    $null = $md.Add('## Blockers')
    $null = $md.Add('')
    if (@($Assessment.blockers).Count -eq 0) { $null = $md.Add('- None') }
    else { foreach ($b in @($Assessment.blockers)) { $null = $md.Add(('- {0}' -f $b)) } }

    Set-Content -LiteralPath $mdPath -Value ($md -join [Environment]::NewLine) -Encoding utf8
    [pscustomobject]@{ JsonPath = $jsonPath; MarkdownPath = $mdPath }
}
