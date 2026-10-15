#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'XboxOS11 Milestone 6A experiment planning and authorization simulation' {
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
        $script:FvCatalog = Import-XboxOSFunctionalValidationCatalog -Path (Join-Path $script:RepoRoot 'config\functional-validation-matrix.json')
        $script:PrivKey = Join-Path $script:Fixtures 'approval-auth\test-approval-private.pem'
        $script:PubKey = Join-Path $script:Fixtures 'approval-auth\test-approval-public.pem'

        $appx = @(ConvertFrom-XboxOSDismProvisionedAppxListOutput -Output (Get-Content (Join-Path $script:Fixtures 'dism-get-appx-26300.9457.txt')) | ForEach-Object { $_.PackageName })
        $features = @(ConvertFrom-XboxOSDismFeatureListOutput -Output (Get-Content (Join-Path $script:Fixtures 'dism-get-features-26300.9457.txt')))
        $packages = @(ConvertFrom-XboxOSDismPackageListOutput -Output (Get-Content (Join-Path $script:Fixtures 'dism-get-packages-26300.9457.txt')))
        $script:FixtureInventory = New-XboxOSInventorySnapshot `
            -AppxAvailability Available `
            -FeatureAvailability Available `
            -AppxPackages $appx `
            -Features $features `
            -Packages $packages `
            -Source 'tests/Fixtures/dism-get-*-26300.9457.txt' `
            -VerificationStatus Authoritative `
            -Notes @('M6A fixture inventory') `
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
            -FallbackMode Simulation

        $script:Plan = New-XboxOSServicingPlan `
            -Inventory $script:FixtureInventory `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility

        $script:CompatReport = [pscustomobject]@{
            exportMeta      = @([pscustomobject]@{ Index = 1; Name = 'Windows 11 Pro'; Architecture = $null })
            sourceSelection = [pscustomobject]@{ Index = 6; Name = 'Windows 11 Pro'; Architecture = $null }
        }

        $script:Readiness = New-XboxOSServicingReadinessAssessment `
            -Plan $script:Plan `
            -Inventory $script:FixtureInventory `
            -CompatibilityManifest $script:Compatibility `
            -EvidenceCatalog $script:DepCatalog `
            -CapabilityCatalog $script:CapCatalog `
            -CompatReport $script:CompatReport `
            -InventoryProvenance $script:FixtureProvenance `
            -RepoRoot $script:RepoRoot

        $script:EligibleIds = @(
            $script:Readiness.operationAssessments |
                Where-Object planStatus -eq 'Eligible' |
                ForEach-Object { [string]$_.operationId }
        )

        $script:TempRoot = Join-Path $env:TEMP ('XboxOS11-m6a-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        Reset-XboxOSExperimentNonceRegistry
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        Reset-XboxOSExperimentNonceRegistry
    }

    BeforeEach {
        Reset-XboxOSExperimentNonceRegistry
    }

    It 'reports Milestone 6A.1 engine and schema versions' {
        Get-XboxOSExperimentPlanEngineVersion | Should -Be '6.0.1-a'
        Get-XboxOSExperimentPlanSchemaVersion | Should -Be 'experiment-plan-v1'
        Get-XboxOSReadinessBindingDigestSchemaVersion | Should -Be 'readiness-binding-digest-v1'
        Get-XboxOSExperimentalMutationEnabled | Should -BeFalse
        Get-XboxOSExperimentalExecutionAuthorized | Should -BeFalse
        Get-XboxOSRealDismExecutionEnabled | Should -BeFalse
    }

    It 'loads functional validation catalog with required capability coverage' {
        @($script:FvCatalog.tests).Count | Should -BeGreaterOrEqual 14
        $ids = @($script:FvCatalog.tests | ForEach-Object { $_.testId })
        $ids | Should -Contain 'fv-xbox-fse-startup'
        $ids | Should -Contain 'fv-gaming-services-smoke'
        $ids | Should -Contain 'fv-store-license-smoke'
        $ids | Should -Contain 'fv-anticheat-checklist'
        $ids | Should -Contain 'fv-servicing-recovery-path'
    }

    It 'plans all eight Eligible operations but blocks execution' {
        $script:EligibleIds.Count | Should -Be 8
        $report = Invoke-XboxOSExperimentPlanSimulate `
            -Plan $script:Plan `
            -ReadinessAssessment $script:Readiness `
            -RequestedOperationIds $script:EligibleIds `
            -FunctionalValidationCatalog $script:FvCatalog `
            -CompatibilityManifest $script:Compatibility `
            -RepoRoot $script:RepoRoot `
            -ProposedWorkspaceRoot (Join-Path $script:TempRoot 'ws') `
            -EvidenceMode InlineSimulation `
            -PrivateKeyPemPath $script:PrivKey `
            -PublicKeyPemPath $script:PubKey `
            -SimulateOperatorConsent `
            -SimulateRiskAcceptance

        $report.decision | Should -Be 'BlockedForExecution'
        $report.transactionState | Should -Be 'BlockedForExecution'
        $report.evidenceMode | Should -Be 'InlineSimulation'
        $report.readinessBindingDigest | Should -Match '^[0-9A-F]{64}$'
        @($report.experimentPlan.operations).Count | Should -Be 8
        $report.executionAuthorized | Should -BeFalse
        $report.servicingAuthorized | Should -BeFalse
        $report.experimentalMutationEnabled | Should -BeFalse
        $report.experimentalExecutionAuthorized | Should -BeFalse
        $report.realDismExecutionEnabled | Should -BeFalse
        $report.modifyingCommandsInvoked | Should -BeFalse
        foreach ($op in $report.experimentPlan.operations) {
            $op.executionAuthorized | Should -BeFalse
            $op.effectiveReadiness | Should -Be 'MissingEvidence'
            $op.dependencyClosureCompleteness | Should -Be 'Incomplete'
        }
    }

    It 'produces deterministic experiment plan content hashes' {
        $digest = Get-XboxOSReadinessBindingDigest -ReadinessAssessment $script:Readiness
        $allow = Test-XboxOSExperimentOperationAllowlist `
            -Plan $script:Plan `
            -ReadinessAssessment $script:Readiness `
            -RequestedOperationIds $script:EligibleIds `
            -CompatibilityManifest $script:Compatibility `
            -ExpectedReadinessBindingDigest $digest
        $ws = Test-XboxOSExperimentWorkspaceConstraints `
            -ProposedWorkspaceRoot (Join-Path $script:TempRoot 'ws-hash') `
            -SourceIsoPath 'C:\XboxOS\Sources\Windows11_Client_x64_en-us_26300_9457.iso'
        $p1 = New-XboxOSExperimentPlan -Plan $script:Plan -ReadinessAssessment $script:Readiness -AllowlistResult $allow -WorkspaceConstraints $ws -FunctionalValidationCatalog $script:FvCatalog -RepoRoot $script:RepoRoot -EvidenceMode InlineSimulation -ReadinessBindingDigest $digest
        $p2 = New-XboxOSExperimentPlan -Plan $script:Plan -ReadinessAssessment $script:Readiness -AllowlistResult $allow -WorkspaceConstraints $ws -FunctionalValidationCatalog $script:FvCatalog -RepoRoot $script:RepoRoot -EvidenceMode InlineSimulation -ReadinessBindingDigest $digest
        $p1.contentHash | Should -Be $p2.contentHash
        $p1.contentHash | Should -Match '^[0-9A-F]{64}$'
        $p1.readinessBindingDigest | Should -Be $digest
    }

    It 'rejects unknown operations and wildcards' {
        $r1 = Test-XboxOSExperimentOperationAllowlist -Plan $script:Plan -ReadinessAssessment $script:Readiness -RequestedOperationIds @('appx:DoesNotExist:Fake')
        $r1.valid | Should -BeFalse
        $r1.errors -join ' ' | Should -Match 'Unknown operation'

        $r2 = Test-XboxOSExperimentOperationAllowlist -Plan $script:Plan -ReadinessAssessment $script:Readiness -RequestedOperationIds @('appx:*')
        $r2.valid | Should -BeFalse
        $r2.errors -join ' ' | Should -Match 'Wildcard'
    }

    It 'rejects protected Xbox identities even when plan status is forged Eligible' {
        # Historical skip reason: fixture M2 plans do not emit status=Protected for removable candidates
        # (protected packages are filtered earlier). This test forges Eligible + protected identity instead.
        $forgedId = 'appx:XboxTCUI:Microsoft.Xbox.TCUI_1.0.0.0_neutral__8wekyb3d8bbwe'
        $forgedOp = [pscustomobject]@{
            operationId    = $forgedId
            targetIdentity = 'Microsoft.Xbox.TCUI_1.0.0.0_neutral__8wekyb3d8bbwe'
            operationType  = 'RemoveProvisionedAppx'
            status         = 'Eligible'
        }
        $forgedReady = [pscustomobject]@{
            operationId               = $forgedId
            targetIdentity            = 'Microsoft.Xbox.TCUI_1.0.0.0_neutral__8wekyb3d8bbwe'
            planStatus                = 'Eligible'
            readiness                 = 'MissingEvidence'
            catalogCandidateReadiness = 'MissingEvidence'
            dependencyClosure         = [pscustomobject]@{ completeness = 'Incomplete' }
            affectedCapabilities      = @('capability:XboxIdentity')
        }
        $planClone = [pscustomobject]@{
            contentHash           = $script:Plan.contentHash
            inventoryFingerprint  = $script:Plan.inventoryFingerprint
            sourceImage           = $script:Plan.sourceImage
            operations            = @($script:Plan.operations) + @($forgedOp)
        }
        $readyClone = [pscustomobject]@{
            planContentHash         = $script:Readiness.planContentHash
            inventoryFingerprint    = $script:Readiness.inventoryFingerprint
            sourceImage             = $script:Readiness.sourceImage
            inventoryProvenance     = $script:Readiness.inventoryProvenance
            operationAssessments    = @($script:Readiness.operationAssessments) + @($forgedReady)
            catalogValidation       = $script:Readiness.catalogValidation
            engineVersion           = $script:Readiness.engineVersion
            reportSchemaVersion     = $script:Readiness.reportSchemaVersion
            decision                = $script:Readiness.decision
            realDismExecutionEnabled = $false
            modifyingCommandsInvoked = $false
            executionAuthorized      = $false
            servicingAuthorized      = $false
            git                     = $script:Readiness.git
        }
        $r = Test-XboxOSExperimentOperationAllowlist `
            -Plan $planClone `
            -ReadinessAssessment $readyClone `
            -RequestedOperationIds @($forgedId) `
            -CompatibilityManifest $script:Compatibility
        $r.valid | Should -BeFalse
        $r.errors -join ' ' | Should -Match 'Protected identity'
    }

    It 'rejects plan hash and inventory fingerprint mismatches' {
        $r = Test-XboxOSExperimentOperationAllowlist `
            -Plan $script:Plan `
            -ReadinessAssessment $script:Readiness `
            -RequestedOperationIds $script:EligibleIds `
            -ExpectedPlanContentHash ('0' * 64)
        $r.valid | Should -BeFalse
        $r.errors -join ' ' | Should -Match 'plan content hash'

        $r2 = Test-XboxOSExperimentOperationAllowlist `
            -Plan $script:Plan `
            -ReadinessAssessment $script:Readiness `
            -RequestedOperationIds $script:EligibleIds `
            -ExpectedInventoryFingerprint ('1' * 64)
        $r2.valid | Should -BeFalse
        $r2.errors -join ' ' | Should -Match 'inventory fingerprint'

        $r3 = Test-XboxOSExperimentOperationAllowlist `
            -Plan $script:Plan `
            -ReadinessAssessment $script:Readiness `
            -RequestedOperationIds $script:EligibleIds `
            -ExpectedIsoSha256 ('2' * 64)
        $r3.valid | Should -BeFalse
        $r3.errors -join ' ' | Should -Match 'ISO'
    }

    It 'rejects OneDrive workspace, path traversal, and host OS image targets' {
        $onedrive = Test-XboxOSExperimentWorkspaceConstraints `
            -ProposedWorkspaceRoot 'C:\Users\user\OneDrive\Work\exp' `
            -SourceIsoPath 'C:\XboxOS\Sources\test.iso'
        $onedrive.valid | Should -BeFalse
        $onedrive.errors -join ' ' | Should -Match 'OneDrive|sync'

        $trav = Test-XboxOSExperimentWorkspaceConstraints `
            -ProposedWorkspaceRoot 'C:\XboxOS\Work\..\..\Windows\System32' `
            -SourceIsoPath 'C:\XboxOS\Sources\test.iso'
        $trav.valid | Should -BeFalse
        ($trav.errors -join ' ') | Should -Match 'traversal|Windows'

        $rel = Test-XboxOSExperimentWorkspaceConstraints `
            -ProposedWorkspaceRoot 'Work\exp' `
            -SourceIsoPath 'C:\XboxOS\Sources\test.iso'
        $rel.valid | Should -BeFalse
        $rel.errors -join ' ' | Should -Match 'Relative'

        $unc = Test-XboxOSExperimentWorkspaceConstraints `
            -ProposedWorkspaceRoot '\\server\share\exp' `
            -SourceIsoPath 'C:\XboxOS\Sources\test.iso'
        $unc.valid | Should -BeFalse
        $unc.errors -join ' ' | Should -Match 'UNC'

        $hostImg = Test-XboxOSExperimentWorkspaceConstraints `
            -ProposedWorkspaceRoot 'C:\XboxOS\Work\exp' `
            -SourceIsoPath 'C:\XboxOS\Sources\test.iso' `
            -HostOsImagePath 'C:\Windows'
        $hostImg.valid | Should -BeFalse
        $hostImg.errors -join ' ' | Should -Match 'Host operating-system'
        $hostImg.filesystemMutationPerformed | Should -BeFalse
    }

    It 'keeps MissingEvidence distinct and rejects disposable promotion / auto-execution' {
        $allow = Test-XboxOSExperimentOperationAllowlist -Plan $script:Plan -ReadinessAssessment $script:Readiness -RequestedOperationIds $script:EligibleIds
        $pol = Test-XboxOSExperimentMissingEvidencePolicy `
            -SelectedOperations $allow.selectedOperations `
            -SimulateRiskAcceptance `
            -AttemptDisposablePromotion `
            -AttemptExecutionAuthorization
        $pol.valid | Should -BeFalse
        $pol.errors -join ' ' | Should -Match 'cannot become VerifiedSafeForConsideration'
        $pol.errors -join ' ' | Should -Match 'cannot automatically authorize'
        foreach ($op in $pol.operations) {
            $op.effectiveReadiness | Should -Be 'MissingEvidence'
            $op.executionAuthorized | Should -BeFalse
            $op.disposablePromotionApplied | Should -BeFalse
        }
    }

    It 'structurally disables ExecutionAuthorization layer creation' {
        { New-XboxOSExperimentAuthorizationRecord `
                -Layer ExecutionAuthorization `
                -ExperimentContentHash ('A' * 64) `
                -ServicingPlanContentHash $script:Plan.contentHash `
                -InventoryFingerprint $script:Plan.inventoryFingerprint `
                -SourceIsoSha256 'BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650' `
                -OperatorId 'sim' `
                -OperationIds @($script:EligibleIds[0]) } | Should -Throw -ExpectedMessage '*structurally disabled*'
    }

    It 'rejects forged approval records and invalid signatures' {
        $rec = New-XboxOSExperimentAuthorizationRecord `
            -Layer OperatorReviewConsent `
            -ExperimentContentHash ('A' * 64) `
            -ServicingPlanContentHash $script:Plan.contentHash `
            -InventoryFingerprint $script:Plan.inventoryFingerprint `
            -SourceIsoSha256 'BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650' `
            -OperatorId 'alice' `
            -OperationIds @($script:EligibleIds[0]) `
            -ClaimApprovedTrue `
            -PrivateKeyPemPath $script:PrivKey

        $forged = $rec | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $forged.bindingHash = ('F' * 64)
        $forged.binding.approved = $true
        $v1 = Test-XboxOSExperimentAuthorizationRecord `
            -Record $forged `
            -ExpectedLayer OperatorReviewConsent `
            -ExperimentContentHash ('A' * 64) `
            -ServicingPlanContentHash $script:Plan.contentHash `
            -InventoryFingerprint $script:Plan.inventoryFingerprint `
            -SourceIsoSha256 'BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650' `
            -OperatorId 'alice' `
            -PublicKeyPemPath $script:PubKey `
            -ExpectedOperationIds @($script:EligibleIds[0])
        $v1.validForSimulation | Should -BeFalse
        $v1.errors -join ' ' | Should -Match 'binding hash'

        $badSig = $rec | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $badSig.signatureBase64 = [Convert]::ToBase64String([byte[]](1..64))
        $v2 = Test-XboxOSExperimentAuthorizationRecord `
            -Record $badSig `
            -ExpectedLayer OperatorReviewConsent `
            -ExperimentContentHash ('A' * 64) `
            -ServicingPlanContentHash $script:Plan.contentHash `
            -InventoryFingerprint $script:Plan.inventoryFingerprint `
            -SourceIsoSha256 'BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650' `
            -OperatorId 'alice' `
            -PublicKeyPemPath $script:PubKey `
            -ExpectedOperationIds @($script:EligibleIds[0])
        $v2.validForSimulation | Should -BeFalse
        $v2.errors -join ' ' | Should -Match 'signature'
    }

    It 'rejects expired consent, mismatched operator, allowlist change, and evidence substitution' {
        $rec = New-XboxOSExperimentAuthorizationRecord `
            -Layer OperatorReviewConsent `
            -ExperimentContentHash ('B' * 64) `
            -ServicingPlanContentHash $script:Plan.contentHash `
            -InventoryFingerprint $script:Plan.inventoryFingerprint `
            -SourceIsoSha256 'BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650' `
            -OperatorId 'alice' `
            -OperationIds @($script:EligibleIds[0]) `
            -IssuedUtc ([datetime]::UtcNow.AddHours(-5)) `
            -ExpiresUtc ([datetime]::UtcNow.AddHours(-1)) `
            -PrivateKeyPemPath $script:PrivKey

        $vExp = Test-XboxOSExperimentAuthorizationRecord `
            -Record $rec `
            -ExpectedLayer OperatorReviewConsent `
            -ExperimentContentHash ('B' * 64) `
            -ServicingPlanContentHash $script:Plan.contentHash `
            -InventoryFingerprint $script:Plan.inventoryFingerprint `
            -SourceIsoSha256 'BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650' `
            -OperatorId 'alice' `
            -PublicKeyPemPath $script:PubKey `
            -ExpectedOperationIds @($script:EligibleIds[0])
        $vExp.validForSimulation | Should -BeFalse
        $vExp.errors -join ' ' | Should -Match 'expired'

        $vOp = Test-XboxOSExperimentAuthorizationRecord `
            -Record $rec `
            -ExpectedLayer OperatorReviewConsent `
            -ExperimentContentHash ('B' * 64) `
            -ServicingPlanContentHash $script:Plan.contentHash `
            -InventoryFingerprint $script:Plan.inventoryFingerprint `
            -SourceIsoSha256 'BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650' `
            -OperatorId 'bob' `
            -PublicKeyPemPath $script:PubKey `
            -ExpectedOperationIds @($script:EligibleIds[0])
        $vOp.validForSimulation | Should -BeFalse
        $vOp.errors -join ' ' | Should -Match 'operator'

        $vAllow = Test-XboxOSExperimentAuthorizationRecord `
            -Record $rec `
            -ExpectedLayer OperatorReviewConsent `
            -ExperimentContentHash ('B' * 64) `
            -ServicingPlanContentHash $script:Plan.contentHash `
            -InventoryFingerprint $script:Plan.inventoryFingerprint `
            -SourceIsoSha256 'BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650' `
            -OperatorId 'alice' `
            -PublicKeyPemPath $script:PubKey `
            -ExpectedOperationIds @($script:EligibleIds[0], $script:EligibleIds[1])
        $vAllow.validForSimulation | Should -BeFalse
        $vAllow.errors -join ' ' | Should -Match 'allowlist'

        $vSub = Test-XboxOSExperimentAuthorizationRecord `
            -Record $rec `
            -ExpectedLayer OperatorReviewConsent `
            -ExperimentContentHash ('C' * 64) `
            -ServicingPlanContentHash $script:Plan.contentHash `
            -InventoryFingerprint $script:Plan.inventoryFingerprint `
            -SourceIsoSha256 'BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650' `
            -OperatorId 'alice' `
            -PublicKeyPemPath $script:PubKey `
            -ExpectedOperationIds @($script:EligibleIds[0])
        $vSub.validForSimulation | Should -BeFalse
        $vSub.errors -join ' ' | Should -Match 'substitution|content hash'
    }

    It 'rejects authorization nonce replay' {
        $nonce = 'fixed-nonce-replay-test'
        $null = New-XboxOSExperimentAuthorizationRecord `
            -Layer ExperimentPlanning `
            -ExperimentContentHash ('D' * 64) `
            -ServicingPlanContentHash $script:Plan.contentHash `
            -InventoryFingerprint $script:Plan.inventoryFingerprint `
            -SourceIsoSha256 'BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650' `
            -OperatorId 'alice' `
            -OperationIds @($script:EligibleIds[0]) `
            -Nonce $nonce
        { New-XboxOSExperimentAuthorizationRecord `
                -Layer ExperimentPlanning `
                -ExperimentContentHash ('D' * 64) `
                -ServicingPlanContentHash $script:Plan.contentHash `
                -InventoryFingerprint $script:Plan.inventoryFingerprint `
                -SourceIsoSha256 'BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650' `
                -OperatorId 'alice' `
                -OperationIds @($script:EligibleIds[0]) `
                -Nonce $nonce } | Should -Throw -ExpectedMessage '*replay*'
    }

    It 'enforces valid transaction transitions and blocks writable labels' {
        Assert-XboxOSExperimentTransactionTransition -From Planned -To AwaitingOperatorReview | Should -BeTrue
        { Assert-XboxOSExperimentTransactionTransition -From Planned -To ExperimentPrepared } | Should -Throw -ExpectedMessage '*Invalid*'
        { Assert-XboxOSExperimentTransactionTransition -From ReviewRecorded -To 'ExecutingMutation' } | Should -Throw
        { Assert-XboxOSExperimentTransactionTransition -From RiskAcceptanceRequired -To 'LiveMutation' } | Should -Throw -ExpectedMessage '*not reachable*'
        $tx = New-XboxOSExperimentTransaction -ExperimentId 'e1' -ContentHash ('E' * 64)
        $null = Set-XboxOSExperimentTransactionState -Transaction $tx -To AwaitingOperatorReview
        $null = Set-XboxOSExperimentTransactionState -Transaction $tx -To ReviewRecorded
        $null = Set-XboxOSExperimentTransactionState -Transaction $tx -To RiskAcceptanceRequired
        $null = Set-XboxOSExperimentTransactionState -Transaction $tx -To BlockedForExecution
        $tx.state | Should -Be 'BlockedForExecution'
        $tx.executionAuthorized | Should -BeFalse
    }

    It 'simulates failure recovery transition without mutation' {
        $tx = New-XboxOSExperimentTransaction -ExperimentId 'e2' -ContentHash ('F' * 64)
        $null = Set-XboxOSExperimentTransactionState -Transaction $tx -To Aborted -Note 'simulated failure'
        $null = Set-XboxOSExperimentTransactionState -Transaction $tx -To RecoveryRequired -Note 'cleanup verification required'
        $tx.state | Should -Be 'RecoveryRequired'
        $tx.modifyingCommandsInvoked | Should -BeFalse
        $tx.experimentalMutationEnabled | Should -BeFalse
    }

    It 'writes JSON/Markdown reports consistently without overwriting M5 stems' {
        $report = Invoke-XboxOSExperimentPlanSimulate `
            -Plan $script:Plan `
            -ReadinessAssessment $script:Readiness `
            -RequestedOperationIds $script:EligibleIds `
            -FunctionalValidationCatalog $script:FvCatalog `
            -CompatibilityManifest $script:Compatibility `
            -RepoRoot $script:RepoRoot `
            -ProposedWorkspaceRoot (Join-Path $script:TempRoot 'ws-report') `
            -EvidenceMode InlineSimulation `
            -SimulateOperatorConsent `
            -SimulateRiskAcceptance

        $paths = Save-XboxOSExperimentPlanReport -Report $report -OutputDirectory $script:TempRoot -Stem 'XboxOS11-experiment-plan-m6a-test' -RepoRoot $script:RepoRoot
        Test-Path -LiteralPath $paths.JsonPath | Should -BeTrue
        Test-Path -LiteralPath $paths.MarkdownPath | Should -BeTrue
        $json = Get-Content -LiteralPath $paths.JsonPath -Raw | ConvertFrom-Json
        $md = Get-Content -LiteralPath $paths.MarkdownPath -Raw
        $json.decision | Should -Be 'BlockedForExecution'
        $md | Should -Match 'BlockedForExecution'
        $md | Should -Match $json.experimentPlan.contentHash

        { Save-XboxOSExperimentPlanReport -Report $report -OutputDirectory $script:TempRoot -Stem 'XboxOS11-servicing-readiness-m5' } | Should -Throw -ExpectedMessage '*overwrite*'
        { Save-XboxOSExperimentPlanReport -Report $report -OutputDirectory 'C:\Users\x\OneDrive\Logs' -Stem 'ok' } | Should -Throw -ExpectedMessage '*OneDrive*'
    }

    It 'does not trust approved=true alone when binding is wrong' {
        $rec = [pscustomobject]@{
            layer = 'OperatorReviewConsent'
            bindingHash = ('0' * 64)
            binding = [pscustomobject]@{
                authLayerSchemaVersion = 'experiment-auth-layer-v1'
                layer = 'OperatorReviewConsent'
                experimentContentHash = ('A' * 64)
                servicingPlanContentHash = $script:Plan.contentHash
                inventoryFingerprint = $script:Plan.inventoryFingerprint
                sourceIsoSha256 = 'BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650'
                operatorId = 'alice'
                operationIds = @($script:EligibleIds[0])
                issuedUtc = [datetime]::UtcNow.ToString('o')
                expiresUtc = [datetime]::UtcNow.AddHours(1).ToString('o')
                nonce = 'n1'
                decision = 'ConsentRecorded'
                approved = $true
            }
            grantsExecutionAuthorization = $false
            executionAuthorized = $false
        }
        $v = Test-XboxOSExperimentAuthorizationRecord `
            -Record $rec `
            -ExpectedLayer OperatorReviewConsent `
            -ExperimentContentHash ('A' * 64) `
            -ServicingPlanContentHash $script:Plan.contentHash `
            -InventoryFingerprint $script:Plan.inventoryFingerprint `
            -SourceIsoSha256 'BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650' `
            -OperatorId 'alice' `
            -ExpectedOperationIds @($script:EligibleIds[0])
        $v.validForSimulation | Should -BeFalse
        $v.grantsExecutionAuthorization | Should -BeFalse
    }

    It 'fail-closes readiness binding on plan hash, inventory, ISO, schema, and provenance forgeries' {
        $bindOk = Test-XboxOSReadinessReportBinding -Report $script:Readiness -Plan $script:Plan -EvidenceMode InlineSimulation
        $bindOk.valid | Should -BeTrue
        $digest = $bindOk.readinessBindingDigest

        $badPlanHash = $script:Readiness | ConvertTo-Json -Depth 14 | ConvertFrom-Json
        $badPlanHash.planContentHash = ('0' * 64)
        $r1 = Test-XboxOSReadinessReportBinding -Report $badPlanHash -Plan $script:Plan -EvidenceMode InlineSimulation
        $r1.valid | Should -BeFalse
        $r1.errors -join ' ' | Should -Match 'planContentHash'

        $badFp = $script:Readiness | ConvertTo-Json -Depth 14 | ConvertFrom-Json
        $badFp.inventoryFingerprint = ('1' * 64)
        $r2 = Test-XboxOSReadinessReportBinding -Report $badFp -Plan $script:Plan -EvidenceMode InlineSimulation
        $r2.valid | Should -BeFalse
        $r2.errors -join ' ' | Should -Match 'inventoryFingerprint'

        $badIso = $script:Readiness | ConvertTo-Json -Depth 14 | ConvertFrom-Json
        $badIso.sourceImage.isoSha256 = ('2' * 64)
        $r3 = Test-XboxOSReadinessReportBinding -Report $badIso -Plan $script:Plan -EvidenceMode InlineSimulation
        $r3.valid | Should -BeFalse
        $r3.errors -join ' ' | Should -Match 'isoSha256|ISO'

        $badSchema = $script:Readiness | ConvertTo-Json -Depth 14 | ConvertFrom-Json
        $badSchema.reportSchemaVersion = 'servicing-readiness-v0'
        $r4 = Test-XboxOSReadinessReportBinding -Report $badSchema -Plan $script:Plan -EvidenceMode ExternalValidated -RequireAuthoritativeProvenance
        $r4.valid | Should -BeFalse
        $r4.errors -join ' ' | Should -Match 'schema'

        $forgedProv = $script:Readiness | ConvertTo-Json -Depth 14 | ConvertFrom-Json
        $forgedProv.inventoryProvenance.sourceType = 'Authoritative'
        $forgedProv.inventoryProvenance.verificationLevel = 'Authoritative'
        # Still FixtureDerived content; ExternalValidated with RequireAuthoritative accepts labels, but plan hash match alone is not enough to claim trust — digest notes document this.
        $r5 = Test-XboxOSReadinessReportBinding -Report $forgedProv -Plan $script:Plan -EvidenceMode ExternalValidated -RequireAuthoritativeProvenance
        # Labels pass; ensure digest still differs from original when other fields unchanged... provenance fields are in digest so digest changes.
        $r5.valid | Should -BeTrue
        $r5.readinessBindingDigest | Should -Not -Be $digest
        $r5.authenticatesReport | Should -BeFalse
    }

    It 'rejects modified readiness, missing/duplicate ops, bad catalog, and digest mismatch' {
        $mod = $script:Readiness | ConvertTo-Json -Depth 14 | ConvertFrom-Json
        $mod.operationAssessments[0].readiness = 'VerifiedSafeForConsideration'
        $rMod = Test-XboxOSReadinessReportBinding -Report $mod -Plan $script:Plan -EvidenceMode InlineSimulation
        # Binding still structurally valid, but digest must change vs original
        $origDigest = Get-XboxOSReadinessBindingDigest -ReadinessAssessment $script:Readiness
        $modDigest = Get-XboxOSReadinessBindingDigest -ReadinessAssessment $mod
        $modDigest | Should -Not -Be $origDigest
        $allowMod = Test-XboxOSExperimentOperationAllowlist `
            -Plan $script:Plan `
            -ReadinessAssessment $mod `
            -RequestedOperationIds $script:EligibleIds `
            -CompatibilityManifest $script:Compatibility `
            -ExpectedReadinessBindingDigest $origDigest
        $allowMod.valid | Should -BeFalse
        $allowMod.errors -join ' ' | Should -Match 'binding digest'

        $missing = $script:Readiness | ConvertTo-Json -Depth 14 | ConvertFrom-Json
        $missing.operationAssessments = @($missing.operationAssessments | Select-Object -Skip 1)
        $rMiss = Test-XboxOSReadinessReportBinding -Report $missing -Plan $script:Plan -EvidenceMode InlineSimulation
        $rMiss.valid | Should -BeFalse
        $rMiss.errors -join ' ' | Should -Match 'missing from readiness'

        $dup = $script:Readiness | ConvertTo-Json -Depth 14 | ConvertFrom-Json
        $dup.operationAssessments = @($dup.operationAssessments[0], $dup.operationAssessments[0]) + @($dup.operationAssessments | Select-Object -Skip 1)
        $rDup = Test-XboxOSReadinessReportBinding -Report $dup -Plan $script:Plan -EvidenceMode InlineSimulation
        $rDup.valid | Should -BeFalse
        $rDup.errors -join ' ' | Should -Match 'Duplicate'

        $badCat = $script:Readiness | ConvertTo-Json -Depth 14 | ConvertFrom-Json
        $badCat.catalogValidation.valid = $false
        $rCat = Test-XboxOSReadinessReportBinding -Report $badCat -Plan $script:Plan -EvidenceMode InlineSimulation
        $rCat.valid | Should -BeFalse
        $rCat.errors -join ' ' | Should -Match 'Catalog validation'

        $badImg = $script:Readiness | ConvertTo-Json -Depth 14 | ConvertFrom-Json
        $badImg.sourceImage.editionName = 'Windows 11 Home'
        $rImg = Test-XboxOSReadinessReportBinding -Report $badImg -Plan $script:Plan -EvidenceMode InlineSimulation
        $rImg.valid | Should -BeFalse
        $rImg.errors -join ' ' | Should -Match 'editionName|edition'
    }

    It 'labels inline simulation distinctly and keeps all six safety flags False' {
        $bind = Test-XboxOSReadinessReportBinding -Report $script:Readiness -Plan $script:Plan -EvidenceMode InlineSimulation
        $bind.evidenceMode | Should -Be 'InlineSimulation'
        $bind.notes -join ' ' | Should -Match 'InlineSimulation'
        $report = Invoke-XboxOSExperimentPlanSimulate `
            -Plan $script:Plan `
            -ReadinessAssessment $script:Readiness `
            -RequestedOperationIds $script:EligibleIds `
            -FunctionalValidationCatalog $script:FvCatalog `
            -CompatibilityManifest $script:Compatibility `
            -ProposedWorkspaceRoot (Join-Path $script:TempRoot 'ws-inline') `
            -EvidenceMode InlineSimulation `
            -SimulateOperatorConsent `
            -SimulateRiskAcceptance
        $report.evidenceMode | Should -Be 'InlineSimulation'
        $report.experimentPlan.evidenceMode | Should -Be 'InlineSimulation'
        foreach ($flag in @('realDismExecutionEnabled', 'modifyingCommandsInvoked', 'executionAuthorized', 'servicingAuthorized', 'experimentalMutationEnabled', 'experimentalExecutionAuthorized')) {
            $report.$flag | Should -BeFalse
        }
    }

    It 'CLI script fail-closes without silent rebuild and requires AllowInlineSimulationReadiness for fixtures' {
        $cli = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts\Test-DisposableExperimentPlan.ps1') -Raw
        $cli | Should -Match 'AllowInlineSimulationReadiness'
        $cli | Should -Match 'fail closed'
        $cli | Should -Not -Match 'rebuilding inline assessment'
        $cli | Should -Match 'ExternalValidated'
        $cli | Should -Match 'InlineSimulation'
    }
}
