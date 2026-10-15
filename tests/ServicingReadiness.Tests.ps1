#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'XboxOS11 Milestone 5 dependency evidence and servicing readiness' {
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
        $script:Inventory = New-XboxOSInventorySnapshot `
            -AppxAvailability Available `
            -FeatureAvailability Available `
            -AppxPackages $appx `
            -Features $features `
            -Packages $packages `
            -Source 'tests/Fixtures/dism-get-*-26300.9457.txt' `
            -VerificationStatus Authoritative `
            -SourceImage ([pscustomobject]@{
                    editionName    = 'Windows 11 Pro'
                    sourceIndex    = 6
                    buildNumber    = '26300.9457'
                    displayVersion = '26H2'
                    isoSha256      = 'BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650'
                })
        $script:Plan = New-XboxOSServicingPlan `
            -Inventory $script:Inventory `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        $script:CompatReport = [pscustomobject]@{
            exportMeta      = @([pscustomobject]@{ Index = 1; Name = 'Windows 11 Pro'; Architecture = $null })
            sourceSelection = [pscustomobject]@{ Index = 6; Name = 'Windows 11 Pro'; Architecture = $null }
        }
        $script:TempRoot = Join-Path $env:TEMP ('XboxOS11-m5-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports Milestone 5 engine and schema versions' {
        Get-XboxOSServicingReadinessEngineVersion | Should -Be '5.0.0'
        Get-XboxOSDependencyEvidenceSchemaVersion | Should -Be 'dependency-evidence-v1'
        Get-XboxOSCapabilityRequirementsSchemaVersion | Should -Be 'capability-requirements-v1'
        Get-XboxOSServicingReadinessReportSchemaVersion | Should -Be 'servicing-readiness-v1'
        Get-XboxOSEvidenceQualitySchemaVersion | Should -Be 'evidence-quality-v1'
    }

    It 'resolves exact Eligible component identities (eight baseline ops)' {
        $eligible = @($script:Plan.operations | Where-Object status -eq 'Eligible')
        $eligible.Count | Should -Be 8
        foreach ($op in $eligible) {
            $op.targetIdentity | Should -Not -BeNullOrEmpty
            $op.targetIdentity | Should -Not -Match '\*'
            $op.operationId | Should -Match '^(appx|feature):'
        }
    }

    It 'builds a dependency graph with direct observation edges and curated relationships' {
        $graph = New-XboxOSDependencyGraph -EvidenceCatalog $script:DepCatalog -Inventory $script:Inventory -CapabilityCatalog $script:CapCatalog
        $graph.nodeCount | Should -BeGreaterThan 50
        $graph.edgeCount | Should -BeGreaterThan 10
        @($graph.edges | Where-Object kind -eq 'Provides').Count | Should -BeGreaterThan 0
        @($graph.edges | Where-Object kind -eq 'SharedDependency').Count | Should -BeGreaterThan 0
        @($graph.edges | Where-Object kind -eq 'UnknownRelationship').Count | Should -BeGreaterThan 0
    }

    It 'marks unknown/non-observable capabilities without calling them absent' {
        $insp = Get-XboxOSCapabilityInspectionResult -CapabilityCatalog $script:CapCatalog -Inventory $script:Inventory -CompatibilityManifest $script:Compatibility
        $fse = $insp.results | Where-Object capabilityId -eq 'XboxFullScreenExperience'
        $fse.status | Should -Be 'NotObservableInProvisionedInventory'
        $anti = $insp.results | Where-Object capabilityId -eq 'AntiCheatCompatibility'
        $anti.status | Should -Be 'NotObservableInProvisionedInventory'
        $store = $insp.results | Where-Object capabilityId -eq 'MicrosoftStore'
        $store.status | Should -Be 'InventoryPatternsObserved'
        $store.note | Should -Match 'not proof'
    }

    It 'fails closed with MissingEvidence for Eligible consumer AppX without authoritative contracts' {
        $assessment = New-XboxOSServicingReadinessAssessment `
            -Plan $script:Plan `
            -Inventory $script:Inventory `
            -CompatibilityManifest $script:Compatibility `
            -EvidenceCatalog $script:DepCatalog `
            -CapabilityCatalog $script:CapCatalog `
            -CompatReport $script:CompatReport `
            -RepoRoot $script:RepoRoot

        $clip = $assessment.operationAssessments | Where-Object operationId -like 'appx:Clipchamp:*'
        $clip.readiness | Should -Be 'MissingEvidence'
        $assessment.decision | Should -Be 'Blocked'
        $assessment.executionAuthorized | Should -BeFalse
        $assessment.servicingAuthorized | Should -BeFalse
        $assessment.realDismExecutionEnabled | Should -BeFalse
        $assessment.modifyingCommandsInvoked | Should -BeFalse
    }

    It 'classifies WorkFolders as VerifiedSafeForConsideration without authorizing execution' {
        $assessment = New-XboxOSServicingReadinessAssessment `
            -Plan $script:Plan `
            -Inventory $script:Inventory `
            -CompatibilityManifest $script:Compatibility `
            -EvidenceCatalog $script:DepCatalog `
            -CapabilityCatalog $script:CapCatalog `
            -CompatReport $script:CompatReport `
            -RepoRoot $script:RepoRoot

        $wf = $assessment.operationAssessments | Where-Object operationId -eq 'feature:WorkFolders:WorkFolders-Client'
        $wf.readiness | Should -Be 'VerifiedSafeForConsideration'
        $wf.evidenceRecords | Where-Object sourceType -eq 'AuthoritativeDocumentation' | Should -Not -BeNullOrEmpty
        $assessment.executionAuthorized | Should -BeFalse
        $assessment.decision | Should -Be 'Blocked'
    }

    It 'classifies protected package removal as KnownUnsafe' {
        $fakeOp = [pscustomobject]@{
            operationId      = 'appx:XboxTCUI:Microsoft.Xbox.TCUI_1.0.0.0_neutral_~_8wekyb3d8bbwe'
            manifestRuleId   = 'XboxTCUI'
            operationType    = 'RemoveProvisionedAppx'
            targetIdentity   = 'Microsoft.Xbox.TCUI_1.0.0.0_neutral_~_8wekyb3d8bbwe'
            status           = 'Eligible'
        }
        $graph = New-XboxOSDependencyGraph -EvidenceCatalog $script:DepCatalog -Inventory $script:Inventory -CapabilityCatalog $script:CapCatalog
        $insp = Get-XboxOSCapabilityInspectionResult -CapabilityCatalog $script:CapCatalog -Inventory $script:Inventory -CompatibilityManifest $script:Compatibility
        $eval = Invoke-XboxOSOperationReadinessEvaluation `
            -Operation $fakeOp `
            -Plan $script:Plan `
            -Inventory $script:Inventory `
            -CompatibilityManifest $script:Compatibility `
            -EvidenceCatalog $script:DepCatalog `
            -CapabilityInspection $insp `
            -DependencyGraph $graph
        $eval.readiness | Should -Be 'KnownUnsafe'
    }

    It 'detects conflicting evidence and stale evidence' {
        $stale = [pscustomobject]@{
            evidenceId     = 'ev-stale'
            sourceType     = 'AuthoritativeDocumentation'
            sourceReference = 'test'
            quality        = 'High'
            verifiedUtc    = ([datetime]::UtcNow.AddDays(-400)).ToString('o')
            collectedUtc   = ([datetime]::UtcNow.AddDays(-400)).ToString('o')
            stalenessDays  = 30
            supportingFindings = @('ok')
            contradictingFindings = @()
            knownLimitations = @()
        }
        $fr = Test-XboxOSEvidenceFreshness -EvidenceRecord $stale
        $fr.stale | Should -BeTrue

        $conflict = Test-XboxOSEvidenceContradiction -EvidenceRecords @(
            [pscustomobject]@{ supportingFindings = @('a'); contradictingFindings = @() }
            [pscustomobject]@{ supportingFindings = @(); contradictingFindings = @('b') }
        )
        $conflict.conflicting | Should -BeTrue
    }

    It 'rejects Assumption-only elevation to VerifiedSafeForConsideration' {
        $catalog = Get-Content -Raw (Join-Path $script:RepoRoot 'config\dependency-evidence.json') | ConvertFrom-Json
        foreach ($a in @($catalog.operationAssessments)) {
            if ($a.manifestRuleId -eq 'Clipchamp') {
                $a.readiness = 'VerifiedSafeForConsideration'
                $a.evidenceIds = @('ev-consumer-appx-missing-removal-contract')
            }
        }
        $assessment = New-XboxOSServicingReadinessAssessment `
            -Plan $script:Plan `
            -Inventory $script:Inventory `
            -CompatibilityManifest $script:Compatibility `
            -EvidenceCatalog $catalog `
            -CapabilityCatalog $script:CapCatalog `
            -CompatReport $script:CompatReport `
            -RepoRoot $script:RepoRoot
        $clip = $assessment.operationAssessments | Where-Object operationId -like 'appx:Clipchamp:*'
        $clip.readiness | Should -Be 'MissingEvidence'
    }

    It 'reports architecture Unknown when DISM Architecture is null (no x64 assumption)' {
        $arch = Resolve-XboxOSImageArchitectureMetadata -Inventory $script:Inventory -CompatReport $script:CompatReport
        $arch.architecture | Should -Be 'Unknown'
        $arch.source | Should -Be 'unknown'
        ($arch.notes -join ' ') | Should -Match 'not assuming x64'
    }

    It 'uses trustworthy DISM Architecture when present' {
        $report = [pscustomobject]@{
            exportMeta = @([pscustomobject]@{ Architecture = 'x64' })
        }
        $arch = Resolve-XboxOSImageArchitectureMetadata -Inventory $script:Inventory -CompatReport $report
        $arch.architecture | Should -Be 'x64'
        $arch.source | Should -Match 'Architecture'
        $arch.confidence | Should -Be 'High'
    }

    It 'captures Git commit traceability or Unknown with warning' {
        $trace = Get-XboxOSReportTraceability -RepoRoot $script:RepoRoot
        $trace.gitCommitSha | Should -Not -BeNullOrEmpty
        if ($trace.gitVerified) {
            $trace.gitCommitSha | Should -Match '^[0-9a-f]{40}$'
        }
        else {
            $trace.gitCommitSha | Should -Be 'Unknown'
            @($trace.warnings).Count | Should -BeGreaterThan 0
        }
    }

    It 'produces deterministic readiness for identical inputs' {
        $a1 = New-XboxOSServicingReadinessAssessment `
            -Plan $script:Plan -Inventory $script:Inventory -CompatibilityManifest $script:Compatibility `
            -EvidenceCatalog $script:DepCatalog -CapabilityCatalog $script:CapCatalog `
            -CompatReport $script:CompatReport -RepoRoot $script:RepoRoot
        $a2 = New-XboxOSServicingReadinessAssessment `
            -Plan $script:Plan -Inventory $script:Inventory -CompatibilityManifest $script:Compatibility `
            -EvidenceCatalog $script:DepCatalog -CapabilityCatalog $script:CapCatalog `
            -CompatReport $script:CompatReport -RepoRoot $script:RepoRoot

        $a1.decision | Should -Be $a2.decision
        $a1.planContentHash | Should -Be $a2.planContentHash
        $ids1 = @($a1.operationAssessments | Where-Object planStatus -eq 'Eligible' | ForEach-Object { '{0}:{1}' -f $_.operationId, $_.readiness } | Sort-Object)
        $ids2 = @($a2.operationAssessments | Where-Object planStatus -eq 'Eligible' | ForEach-Object { '{0}:{1}' -f $_.operationId, $_.readiness } | Sort-Object)
        $ids1 | Should -Be $ids2
    }

    It 'writes JSON/Markdown reports that agree on decision, flags, and Eligible readiness' {
        $assessment = New-XboxOSServicingReadinessAssessment `
            -Plan $script:Plan -Inventory $script:Inventory -CompatibilityManifest $script:Compatibility `
            -EvidenceCatalog $script:DepCatalog -CapabilityCatalog $script:CapCatalog `
            -CompatReport $script:CompatReport -RepoRoot $script:RepoRoot
        $paths = Save-XboxOSServicingReadinessReport -Assessment $assessment -OutputDirectory $script:TempRoot -Stem 'm5-readiness' -RepoRoot $script:RepoRoot
        Test-Path -LiteralPath $paths.JsonPath | Should -BeTrue
        Test-Path -LiteralPath $paths.MarkdownPath | Should -BeTrue
        $json = Get-Content -Raw $paths.JsonPath | ConvertFrom-Json
        $md = Get-Content -Raw $paths.MarkdownPath
        $json.decision | Should -Be 'Blocked'
        $md | Should -Match 'Decision: \*\*Blocked\*\*'
        $json.executionAuthorized | Should -BeFalse
        $md | Should -Match 'Execution authorized: \*\*False\*\*'
        $json.servicingAuthorized | Should -BeFalse
        $json.sourceImage.architecture | Should -Be 'Unknown'
        $md | Should -Match 'Architecture: \*\*Unknown\*\*'
        $json.git.gitCommitSha | Should -Not -BeNullOrEmpty
        $eligible = @($json.operationAssessments | Where-Object planStatus -eq 'Eligible')
        $eligible.Count | Should -Be 8
        ($md -split "`n" | Where-Object { $_ -match 'Readiness:' }).Count | Should -BeGreaterOrEqual 8
    }

    It 'prioritizes protected components over candidate removals' {
        $protected = @(Get-XboxOSProtectedAppxPatterns -CompatibilityManifest $script:Compatibility)
        $xboxPkg = @($script:Inventory.appxPackages | Where-Object { Test-XboxOSPackageProtected -PackageName $_ -ProtectedPatterns $protected } | Select-Object -First 1)
        $xboxPkg.Count | Should -Be 1
        Test-XboxOSPackageProtected -PackageName $xboxPkg[0] -ProtectedPatterns $protected | Should -BeTrue
        $disabledXboxCandidate = @($script:RemoveApps.candidates | Where-Object { $_.id -eq 'XboxTCUI' })
        $disabledXboxCandidate.Count | Should -Be 1
        [bool]$disabledXboxCandidate[0].enabled | Should -BeFalse
        $planWithDisabled = New-XboxOSServicingPlan `
            -Inventory $script:Inventory `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility `
            -IncludeDisabledManifestCandidates
        $planProtected = @($planWithDisabled.operations | Where-Object status -eq 'Protected')
        $planProtected.Count | Should -BeGreaterThan 0
    }

    It 'records shared-dependency impacts for Store without treating presence as operation safety' {
        $assessment = New-XboxOSServicingReadinessAssessment `
            -Plan $script:Plan -Inventory $script:Inventory -CompatibilityManifest $script:Compatibility `
            -EvidenceCatalog $script:DepCatalog -CapabilityCatalog $script:CapCatalog `
            -CompatReport $script:CompatReport -RepoRoot $script:RepoRoot
        $anyShared = @($assessment.operationAssessments | Where-Object planStatus -eq 'Eligible' | ForEach-Object { $_.sharedDependencies }) 
        @($anyShared).Count | Should -BeGreaterThan 0
        $storeCap = $assessment.capabilityInspection.results | Where-Object capabilityId -eq 'MicrosoftStore'
        $storeCap.status | Should -Be 'InventoryPatternsObserved'
        $assessment.decision | Should -Be 'Blocked'
    }
}
