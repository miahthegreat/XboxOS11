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

    It 'reports Milestone 6A engine and schema versions' {
        Get-XboxOSExperimentPlanEngineVersion | Should -Be '6.0.0-a'
        Get-XboxOSExperimentPlanSchemaVersion | Should -Be 'experiment-plan-v1'
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
            -RepoRoot $script:RepoRoot `
            -ProposedWorkspaceRoot (Join-Path $script:TempRoot 'ws') `
            -PrivateKeyPemPath $script:PrivKey `
            -PublicKeyPemPath $script:PubKey `
            -SimulateOperatorConsent `
            -SimulateRiskAcceptance

        $report.decision | Should -Be 'BlockedForExecution'
        $report.transactionState | Should -Be 'BlockedForExecution'
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
        }
    }

    It 'produces deterministic experiment plan content hashes' {
        $allow = Test-XboxOSExperimentOperationAllowlist `
            -Plan $script:Plan `
            -ReadinessAssessment $script:Readiness `
            -RequestedOperationIds $script:EligibleIds
        $ws = Test-XboxOSExperimentWorkspaceConstraints `
            -ProposedWorkspaceRoot (Join-Path $script:TempRoot 'ws-hash') `
            -SourceIsoPath 'C:\XboxOS\Sources\Windows11_Client_x64_en-us_26300_9457.iso'
        $p1 = New-XboxOSExperimentPlan -Plan $script:Plan -ReadinessAssessment $script:Readiness -AllowlistResult $allow -WorkspaceConstraints $ws -FunctionalValidationCatalog $script:FvCatalog -RepoRoot $script:RepoRoot
        $p2 = New-XboxOSExperimentPlan -Plan $script:Plan -ReadinessAssessment $script:Readiness -AllowlistResult $allow -WorkspaceConstraints $ws -FunctionalValidationCatalog $script:FvCatalog -RepoRoot $script:RepoRoot
        $p1.contentHash | Should -Be $p2.contentHash
        $p1.contentHash | Should -Match '^[0-9A-F]{64}$'
    }

    It 'rejects unknown operations and wildcards' {
        $r1 = Test-XboxOSExperimentOperationAllowlist -Plan $script:Plan -ReadinessAssessment $script:Readiness -RequestedOperationIds @('appx:DoesNotExist:Fake')
        $r1.valid | Should -BeFalse
        $r1.errors -join ' ' | Should -Match 'Unknown operation'

        $r2 = Test-XboxOSExperimentOperationAllowlist -Plan $script:Plan -ReadinessAssessment $script:Readiness -RequestedOperationIds @('appx:*')
        $r2.valid | Should -BeFalse
        $r2.errors -join ' ' | Should -Match 'Wildcard'
    }

    It 'rejects protected Xbox/Gaming Services style selections when plan status is Protected' {
        $protected = @($script:Plan.operations | Where-Object status -eq 'Protected' | Select-Object -First 1)
        if ($protected.Count -eq 0) {
            Set-ItResult -Skipped -Because 'No Protected operations in fixture plan'
            return
        }
        $r = Test-XboxOSExperimentOperationAllowlist `
            -Plan $script:Plan `
            -ReadinessAssessment $script:Readiness `
            -RequestedOperationIds @([string]$protected[0].operationId)
        $r.valid | Should -BeFalse
        $r.errors -join ' ' | Should -Match 'Protected'
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
        $onedrive.errors -join ' ' | Should -Match 'OneDrive'

        $trav = Test-XboxOSExperimentWorkspaceConstraints `
            -ProposedWorkspaceRoot 'C:\XboxOS\Work\..\..\Windows\System32' `
            -SourceIsoPath 'C:\XboxOS\Sources\test.iso'
        $trav.valid | Should -BeFalse
        $trav.errors -join ' ' | Should -Match 'traversal'

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
            -RepoRoot $script:RepoRoot `
            -ProposedWorkspaceRoot (Join-Path $script:TempRoot 'ws-report') `
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
}
