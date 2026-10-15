#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'XboxOS11 Milestone 5.1 dependency evidence hardening' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        Import-Module (Join-Path $repoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force
        $script:RepoRoot = $repoRoot.Path
        $script:Fixtures = Join-Path $script:RepoRoot 'tests\Fixtures'
        $script:RemoveApps = Import-XboxOSManifest -Path (Join-Path $script:RepoRoot 'config\remove-apps.json')
        $script:DisableFeatures = Import-XboxOSManifest -Path (Join-Path $script:RepoRoot 'config\disable-features.json')
        $script:Compatibility = Import-XboxOSManifest -Path (Join-Path $script:RepoRoot 'config\compatibility.json')
        $script:DepCatalog = Import-XboxOSDependencyEvidenceCatalog -Path (Join-Path $script:RepoRoot 'config\dependency-evidence.json')
        $script:CapCatalog = Import-XboxOSCapabilityRequirementsCatalog -Path (Join-Path $script:RepoRoot 'config\capability-requirements.json')

        $appx = @(ConvertFrom-XboxOSDismProvisionedAppxListOutput -Output (Get-Content (Join-Path $script:Fixtures 'dism-get-appx-26300.9457.txt')) | ForEach-Object { $_.PackageName })
        $features = @(ConvertFrom-XboxOSDismFeatureListOutput -Output (Get-Content (Join-Path $script:Fixtures 'dism-get-features-26300.9457.txt')))
        $packages = @(ConvertFrom-XboxOSDismPackageListOutput -Output (Get-Content (Join-Path $script:Fixtures 'dism-get-packages-26300.9457.txt')))
        # Inventory snapshot verification Authoritative enables M2 planning; readiness provenance separately labels FixtureDerived.
        $script:FixtureInventory = New-XboxOSInventorySnapshot `
            -AppxAvailability Available `
            -FeatureAvailability Available `
            -AppxPackages $appx `
            -Features $features `
            -Packages $packages `
            -Source 'tests/Fixtures/dism-get-*-26300.9457.txt' `
            -VerificationStatus Authoritative `
            -Notes @('Fixture transcript inventory for tests; readiness provenance is FixtureDerived.') `
            -SourceImage ([pscustomobject]@{
                    editionName    = 'Windows 11 Pro'
                    sourceIndex    = 6
                    buildNumber    = '26300.9457'
                    displayVersion = '26H2'
                    isoSha256      = 'BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650'
                })
        $script:FixtureProvenance = New-XboxOSInventoryProvenance `
            -SourceType FixtureDerived `
            -VerificationLevel Unverified `
            -SourcePath 'tests/Fixtures/dism-get-*-26300.9457.txt' `
            -FallbackMode Simulation `
            -Notes @('Pester fixture inventory; not production evidence.')

        $script:AuthInventory = $null
        $script:AuthProvenance = $null
        $script:AuthCompat = $null
        $authPath = 'C:\XboxOS\Logs\DISM-Compatibility-20261014-2.json'
        if (Test-Path -LiteralPath $authPath) {
            $script:AuthInventory = Import-XboxOSInventoryFromCompatReport -Path $authPath
            $script:AuthCompat = Get-Content -LiteralPath $authPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:AuthProvenance = New-XboxOSInventoryProvenance `
                -SourceType Authoritative `
                -VerificationLevel Authoritative `
                -SourcePath $authPath `
                -FallbackMode None
        }

        $script:Plan = New-XboxOSServicingPlan `
            -Inventory $script:FixtureInventory `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        $script:CompatReport = [pscustomobject]@{
            exportMeta      = @([pscustomobject]@{ Index = 1; Name = 'Windows 11 Pro'; Architecture = $null })
            sourceSelection = [pscustomobject]@{ Index = 6; Name = 'Windows 11 Pro'; Architecture = $null }
        }
        $script:TempRoot = Join-Path $env:TEMP ('XboxOS11-m51-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports Milestone 5.1 engine version' {
        Get-XboxOSServicingReadinessEngineVersion | Should -Be '5.1.0'
    }

    It 'resolves eight Eligible operations with exact identities' {
        $eligible = @($script:Plan.operations | Where-Object status -eq 'Eligible')
        $eligible.Count | Should -Be 8
        foreach ($op in $eligible) {
            $op.targetIdentity | Should -Not -Match '\*'
        }
    }

    It 'builds a graph without self-loop Provides and with curated Provides/Shared/Unknown edges' {
        $graph = New-XboxOSDependencyGraph -EvidenceCatalog $script:DepCatalog -Inventory $script:FixtureInventory -CapabilityCatalog $script:CapCatalog
        @($graph.edges | Where-Object { $_.kind -eq 'Provides' -and $_.from -eq $_.to }).Count | Should -Be 0
        @($graph.edges | Where-Object kind -eq 'Provides').Count | Should -BeGreaterThan 0
        @($graph.edges | Where-Object kind -eq 'SharedDependency').Count | Should -BeGreaterThan 0
        @($graph.edges | Where-Object kind -eq 'UnknownRelationship').Count | Should -BeGreaterThan 0
    }

    It 'traverses operation-scoped closure and detects UnknownRelationship for WorkFolders' {
        $op = $script:Plan.operations | Where-Object operationId -eq 'feature:WorkFolders:WorkFolders-Client'
        $graph = New-XboxOSDependencyGraph -EvidenceCatalog $script:DepCatalog -Inventory $script:FixtureInventory -CapabilityCatalog $script:CapCatalog
        $closure = Get-XboxOSOperationDependencyClosure -Operation $op -DependencyGraph $graph
        $closure.rootNodeId | Should -Be 'feature:WorkFolders-Client'
        $closure.completeness | Should -Be 'Incomplete'
        @($closure.unknownRelationships).Count | Should -BeGreaterThan 0
        @($closure.paths).Count | Should -BeGreaterThan 0
        # Unrelated shared Store edge must not appear as WorkFolders shared dep
        @($closure.sharedDependencies | Where-Object { $_.relationshipId -eq 'rel-store-shared-modern-apps' }).Count | Should -Be 0
    }

    It 'detects cycles in a synthetic graph' {
        $catalog = [pscustomobject]@{
            schemaVersion = 'dependency-evidence-v1'
            components = @(
                [pscustomobject]@{ id = 'feature:A'; kind = 'Feature'; displayName = 'A' }
                [pscustomobject]@{ id = 'feature:B'; kind = 'Feature'; displayName = 'B' }
            )
            evidence = @(
                [pscustomobject]@{
                    evidenceId = 'ev-cycle'; sourceType = 'ManifestDeclared'; sourceReference = 't'
                    componentIdentity = 'feature:A'; relatedOperationIds = @()
                    buildApplicability = '26300.9457'; editionApplicability = 'Windows 11 Pro'
                    collectedUtc = '2026-10-15T00:00:00Z'; verifiedUtc = '2026-10-15T00:00:00Z'
                    quality = 'High'; stalenessDays = 30
                    knownLimitations = @(); supportingFindings = @('x'); contradictingFindings = @()
                }
            )
            relationships = @(
                [pscustomobject]@{ relationshipId = 'r1'; from = 'feature:A'; to = 'feature:B'; kind = 'Requires'; phase = 'Runtime'; evidenceIds = @('ev-cycle') }
                [pscustomobject]@{ relationshipId = 'r2'; from = 'feature:B'; to = 'feature:A'; kind = 'Requires'; phase = 'Runtime'; evidenceIds = @('ev-cycle') }
            )
            operationAssessments = @()
        }
        $inv = New-XboxOSInventorySnapshot -AppxAvailability Empty -FeatureAvailability Available -AppxPackages @() -Features @([pscustomobject]@{ Name = 'A'; State = 'Enabled' }) -Source t -VerificationStatus Unverified
        $graph = New-XboxOSDependencyGraph -EvidenceCatalog $catalog -Inventory $inv -CapabilityCatalog $script:CapCatalog
        $op = [pscustomobject]@{ operationType = 'DisableOptionalFeature'; targetIdentity = 'A'; operationId = 'feature:t:A'; manifestRuleId = 't'; status = 'Eligible' }
        $closure = Get-XboxOSOperationDependencyClosure -Operation $op -DependencyGraph $graph
        @($closure.cyclesDetected).Count | Should -BeGreaterThan 0
    }

    It 'validates catalog integrity and rejects duplicates / dangling endpoints' {
        $ok = Test-XboxOSDependencyEvidenceCatalog -EvidenceCatalog $script:DepCatalog -ExpectedBuild '26300.9457' -ExpectedEdition 'Windows 11 Pro'
        $ok.valid | Should -BeTrue

        $bad = Get-Content -Raw (Join-Path $script:RepoRoot 'config\dependency-evidence.json') | ConvertFrom-Json
        $bad.components += [pscustomobject]@{ id = 'feature:WorkFolders-Client'; kind = 'Feature'; displayName = 'dup' }
        $bad.relationships += [pscustomobject]@{
            relationshipId = 'rel-dangling'; from = 'feature:Missing'; to = 'capability:MicrosoftStore'
            kind = 'Requires'; phase = 'Runtime'; evidenceIds = @('ev-missing')
        }
        $v = Test-XboxOSDependencyEvidenceCatalog -EvidenceCatalog $bad
        $v.valid | Should -BeFalse
        ($v.errors -join ' ') | Should -Match 'Duplicate component'
        ($v.errors -join ' ') | Should -Match 'Dangling'
        ($v.errors -join ' ') | Should -Match 'missing evidence'
    }

    It 'scopes contradictions to related component/operation identities' {
        $unrelated = Test-XboxOSEvidenceContradiction -EvidenceRecords @(
            [pscustomobject]@{
                evidenceId = 'a'; componentIdentity = 'feature:X'; relatedOperationIds = @()
                supportingFindings = @('ok'); contradictingFindings = @()
            }
            [pscustomobject]@{
                evidenceId = 'b'; componentIdentity = 'feature:Y'; relatedOperationIds = @()
                supportingFindings = @(); contradictingFindings = @('bad')
            }
        ) -OperationId 'feature:WorkFolders:WorkFolders-Client' -TargetIdentity 'WorkFolders-Client' -ComponentIds @('feature:WorkFolders-Client')
        # Both apply via empty relatedOperationIds assessment-scope rule — still different components, no same-comp conflict
        # Empty relatedOperationIds marks applies=true for each when OperationId set — cross-comp shouldn't conflict
        $unrelated.conflicting | Should -BeFalse

        $same = Test-XboxOSEvidenceContradiction -EvidenceRecords @(
            [pscustomobject]@{
                evidenceId = 'c'; componentIdentity = 'feature:WorkFolders-Client'; relatedOperationIds = @('feature:WorkFolders:WorkFolders-Client')
                supportingFindings = @('safe'); contradictingFindings = @()
            }
            [pscustomobject]@{
                evidenceId = 'd'; componentIdentity = 'feature:WorkFolders-Client'; relatedOperationIds = @('feature:WorkFolders:WorkFolders-Client')
                supportingFindings = @(); contradictingFindings = @('unsafe')
            }
        ) -OperationId 'feature:WorkFolders:WorkFolders-Client' -TargetIdentity 'WorkFolders-Client' -ComponentIds @('feature:WorkFolders-Client')
        $same.conflicting | Should -BeTrue
        $same.conflictingEvidenceIds | Should -Contain 'c'
        $same.conflictingEvidenceIds | Should -Contain 'd'
    }

    It 'rejects fixture-driven ReadyForReview and labels FixtureDerived provenance' {
        $assessment = New-XboxOSServicingReadinessAssessment `
            -Plan $script:Plan `
            -Inventory $script:FixtureInventory `
            -CompatibilityManifest $script:Compatibility `
            -EvidenceCatalog $script:DepCatalog `
            -CapabilityCatalog $script:CapCatalog `
            -CompatReport $script:CompatReport `
            -InventoryProvenance $script:FixtureProvenance `
            -RepoRoot $script:RepoRoot
        $assessment.inventoryProvenance.sourceType | Should -Be 'FixtureDerived'
        $assessment.decision | Should -Not -Be 'ReadyForReview'
        $assessment.executionAuthorized | Should -BeFalse
        $assessment.servicingAuthorized | Should -BeFalse
    }

    It 'downgrades WorkFolders catalog candidate when closure is incomplete' {
        $inv = if ($script:AuthInventory) { $script:AuthInventory } else { $script:FixtureInventory }
        $prov = if ($script:AuthProvenance) { $script:AuthProvenance } else { $script:FixtureProvenance }
        $plan = New-XboxOSServicingPlan -Inventory $inv -RemoveAppsManifest $script:RemoveApps -DisableFeaturesManifest $script:DisableFeatures -CompatibilityManifest $script:Compatibility
        $assessment = New-XboxOSServicingReadinessAssessment `
            -Plan $plan -Inventory $inv -CompatibilityManifest $script:Compatibility `
            -EvidenceCatalog $script:DepCatalog -CapabilityCatalog $script:CapCatalog `
            -CompatReport $(if ($script:AuthCompat) { $script:AuthCompat } else { $script:CompatReport }) `
            -InventoryProvenance $prov -RepoRoot $script:RepoRoot
        $wf = $assessment.operationAssessments | Where-Object operationId -eq 'feature:WorkFolders:WorkFolders-Client'
        $wf.catalogCandidateReadiness | Should -Be 'VerifiedSafeForConsideration'
        $wf.readiness | Should -Be 'MissingEvidence'
        $wf.dependencyClosure.completeness | Should -Be 'Incomplete'
        ($wf.blockers -join ' ') | Should -Match 'closure'
    }

    It 'keeps seven consumer AppX removals MissingEvidence' {
        $assessment = New-XboxOSServicingReadinessAssessment `
            -Plan $script:Plan -Inventory $script:FixtureInventory -CompatibilityManifest $script:Compatibility `
            -EvidenceCatalog $script:DepCatalog -CapabilityCatalog $script:CapCatalog `
            -CompatReport $script:CompatReport -InventoryProvenance $script:FixtureProvenance -RepoRoot $script:RepoRoot
        $appx = @($assessment.operationAssessments | Where-Object { $_.planStatus -eq 'Eligible' -and $_.operationType -eq 'RemoveProvisionedAppx' })
        $appx.Count | Should -Be 7
        foreach ($a in $appx) { $a.readiness | Should -Be 'MissingEvidence' }
    }

    It 'evaluates all eight Eligible operations with graph closure fields' {
        $assessment = New-XboxOSServicingReadinessAssessment `
            -Plan $script:Plan -Inventory $script:FixtureInventory -CompatibilityManifest $script:Compatibility `
            -EvidenceCatalog $script:DepCatalog -CapabilityCatalog $script:CapCatalog `
            -CompatReport $script:CompatReport -InventoryProvenance $script:FixtureProvenance -RepoRoot $script:RepoRoot
        $eligible = @($assessment.operationAssessments | Where-Object planStatus -eq 'Eligible')
        $eligible.Count | Should -Be 8
        foreach ($a in $eligible) {
            $a.dependencyClosure | Should -Not -BeNullOrEmpty
            $a.dependencyClosure.rootNodeId | Should -Not -BeNullOrEmpty
        }
    }

    It 'reports architecture Unknown without assuming x64' {
        $arch = Resolve-XboxOSImageArchitectureMetadata -Inventory $script:FixtureInventory -CompatReport $script:CompatReport
        $arch.architecture | Should -Be 'Unknown'
    }

    It 'writes JSON/Markdown agreeing on decision, provenance, and safety flags' {
        $assessment = New-XboxOSServicingReadinessAssessment `
            -Plan $script:Plan -Inventory $script:FixtureInventory -CompatibilityManifest $script:Compatibility `
            -EvidenceCatalog $script:DepCatalog -CapabilityCatalog $script:CapCatalog `
            -CompatReport $script:CompatReport -InventoryProvenance $script:FixtureProvenance -RepoRoot $script:RepoRoot
        $paths = Save-XboxOSServicingReadinessReport -Assessment $assessment -OutputDirectory $script:TempRoot -Stem 'm51' -RepoRoot $script:RepoRoot
        $json = Get-Content -Raw $paths.JsonPath | ConvertFrom-Json
        $md = Get-Content -Raw $paths.MarkdownPath
        $json.decision | Should -Be 'Blocked'
        $md | Should -Match 'Decision: \*\*Blocked\*\*'
        $json.inventoryProvenance.sourceType | Should -Be 'FixtureDerived'
        $md | Should -Match 'Inventory source: \*\*FixtureDerived\*\*'
        $json.executionAuthorized | Should -BeFalse
        $json.servicingAuthorized | Should -BeFalse
        $json.realDismExecutionEnabled | Should -BeFalse
        $json.modifyingCommandsInvoked | Should -BeFalse
        $json.catalogValidation.valid | Should -BeTrue
        $json.sourceImage.architecture | Should -Be 'Unknown'
    }

    It 'rejects Assumption-only elevation even if catalog says VerifiedSafe' {
        $catalog = Get-Content -Raw (Join-Path $script:RepoRoot 'config\dependency-evidence.json') | ConvertFrom-Json
        foreach ($a in @($catalog.operationAssessments)) {
            if ($a.manifestRuleId -eq 'WorkFolders') {
                $a.evidenceIds = @('ev-consumer-appx-missing-removal-contract')
            }
        }
        # Fix catalog components for validation - use original components
        $prov = New-XboxOSInventoryProvenance -SourceType Authoritative -VerificationLevel Authoritative -SourcePath 'unit' -FallbackMode None
        $assessment = New-XboxOSServicingReadinessAssessment `
            -Plan $script:Plan -Inventory $script:FixtureInventory -CompatibilityManifest $script:Compatibility `
            -EvidenceCatalog $catalog -CapabilityCatalog $script:CapCatalog `
            -CompatReport $script:CompatReport -InventoryProvenance $prov -RepoRoot $script:RepoRoot
        $wf = $assessment.operationAssessments | Where-Object operationId -eq 'feature:WorkFolders:WorkFolders-Client'
        $wf.readiness | Should -Be 'MissingEvidence'
    }

    It 'marks protected package removal KnownUnsafe' {
        $graph = New-XboxOSDependencyGraph -EvidenceCatalog $script:DepCatalog -Inventory $script:FixtureInventory -CapabilityCatalog $script:CapCatalog
        $insp = Get-XboxOSCapabilityInspectionResult -CapabilityCatalog $script:CapCatalog -Inventory $script:FixtureInventory -CompatibilityManifest $script:Compatibility
        $catVal = Test-XboxOSDependencyEvidenceCatalog -EvidenceCatalog $script:DepCatalog
        $fakeOp = [pscustomobject]@{
            operationId = 'appx:XboxTCUI:Microsoft.Xbox.TCUI_1.0.0.0_neutral_~_8wekyb3d8bbwe'
            manifestRuleId = 'XboxTCUI'; operationType = 'RemoveProvisionedAppx'
            targetIdentity = 'Microsoft.Xbox.TCUI_1.0.0.0_neutral_~_8wekyb3d8bbwe'; status = 'Eligible'
        }
        $eval = Invoke-XboxOSOperationReadinessEvaluation `
            -Operation $fakeOp -Plan $script:Plan -Inventory $script:FixtureInventory `
            -CompatibilityManifest $script:Compatibility -EvidenceCatalog $script:DepCatalog `
            -CapabilityInspection $insp -DependencyGraph $graph `
            -InventoryProvenance $script:FixtureProvenance -CatalogValidation $catVal
        $eval.readiness | Should -Be 'KnownUnsafe'
    }
}
