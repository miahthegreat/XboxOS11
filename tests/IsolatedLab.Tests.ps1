#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'XboxOS11 Milestone 6B.1 isolated lab evidence and isolation hardening' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        Import-Module (Join-Path $repoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force
        $script:RepoRoot = $repoRoot.Path
        $script:TopologyPath = Join-Path $script:RepoRoot 'config\lab-topology.json'
        $script:Topology = Import-XboxOSLabTopologyCatalog -Path $script:TopologyPath
        $script:FvCatalog = Import-XboxOSFunctionalValidationCatalog -Path (Join-Path $script:RepoRoot 'config\functional-validation-matrix.json')
        $script:RemoveApps = Import-XboxOSManifest -Path (Join-Path $script:RepoRoot 'config\remove-apps.json')
        $script:DisableFeatures = Import-XboxOSManifest -Path (Join-Path $script:RepoRoot 'config\disable-features.json')
        $script:Compatibility = Import-XboxOSManifest -Path (Join-Path $script:RepoRoot 'config\compatibility.json')
        $script:PlanHash = ('A' * 64)
        $script:ReadinessDigest = ('B' * 64)
        $script:ExperimentHash = ('C' * 64)
        $script:InventoryFp = ('D' * 64)
        $script:IsoSha = 'BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650'
        $script:TempRoot = Join-Path $env:TEMP ('XboxOS11-m6b1-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        $script:AuthCompat = 'C:\XboxOS\Logs\DISM-Compatibility-20261014-2.json'
        $script:AuthReady = 'C:\XboxOS\Logs\XboxOS11-servicing-readiness-m5.json'
        $script:AuthExp = 'C:\XboxOS\Logs\XboxOS11-experiment-plan-m6a-auth.json'
        $script:HasAuthEvidence = (Test-Path -LiteralPath $script:AuthCompat) -and (Test-Path -LiteralPath $script:AuthReady) -and (Test-Path -LiteralPath $script:AuthExp)
        Reset-XboxOSLabNonceRegistry

        function script:Copy-LabTopology {
            param([object]$Source = $script:Topology)
            return ($Source | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
        }

        function script:Invoke-LabSim {
            param(
                [string]$InjectFailure = '',
                [switch]$SimulateOperatorReview,
                [object]$Topology = $script:Topology
            )
            $params = @{
                Topology                     = $Topology
                FunctionalValidationCatalog  = $script:FvCatalog
                PlanHash                     = $script:PlanHash
                ReadinessBindingDigest       = $script:ReadinessDigest
                SourceIsoSha256              = $script:IsoSha
                ExperimentPlanHash           = $script:ExperimentHash
                InventoryFingerprint         = $script:InventoryFp
                RepoRoot                     = $script:RepoRoot
                EvidenceMode                 = 'InlineSimulation'
            }
            if ($InjectFailure) { $params.InjectFailure = $InjectFailure }
            if ($SimulateOperatorReview) { $params.SimulateOperatorReview = $true }
            return Invoke-XboxOSIsolatedLabSimulate @params
        }

        function script:Skip-UnlessAuthEvidence {
            if (-not $script:HasAuthEvidence) {
                Set-ItResult -Skipped -Because 'Authoritative C:\XboxOS\Logs M1/M4+M5+M6A reports are not present on this host'
            }
        }
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        Reset-XboxOSLabNonceRegistry
    }

    BeforeEach {
        Reset-XboxOSLabNonceRegistry
    }

    It 'reports Milestone 6B.1 engine and schema versions' {
        Get-XboxOSIsolatedLabEngineVersion | Should -Be '6.1.1-b'
        Get-XboxOSLabIsolationSchemaVersion | Should -Be 'lab-isolation-v1.1'
        Get-XboxOSLabOwnershipSchemaVersion | Should -Be 'lab-ownership-v1.1'
        Get-XboxOSLabEvidenceSchemaVersion | Should -Be 'lab-evidence-v1.1'
        Get-XboxOSLabEvidenceChainSchemaVersion | Should -Be 'lab-evidence-chain-v1'
        Get-XboxOSLabEvidenceLabel -EvidenceMode ExternalValidated | Should -Be 'ExternalValidatedEvidence'
        Get-XboxOSLabEvidenceLabel -EvidenceMode InlineSimulation | Should -Be 'InlineSimulationEvidence'
        Get-XboxOSLabEvidenceLabel -EvidenceMode NotValidated | Should -Be 'NotValidated'
        Get-XboxOSLabRealProvisioningEnabled | Should -BeFalse
        Get-XboxOSExperimentalExecutionAuthorized | Should -BeFalse
    }

    It 'rejects missing M1/M4, M5, or M6A reports in evidence chain' {
        $placeholderReady = Join-Path $script:TempRoot 'placeholder-m5.json'
        $placeholderExp = Join-Path $script:TempRoot 'placeholder-m6a.json'
        $placeholderCompat = Join-Path $script:TempRoot 'placeholder-compat.json'
        '{}' | Set-Content -LiteralPath $placeholderReady -Encoding UTF8
        '{}' | Set-Content -LiteralPath $placeholderExp -Encoding UTF8
        '{}' | Set-Content -LiteralPath $placeholderCompat -Encoding UTF8

        $missingCompat = Test-XboxOSLabEvidenceChain `
            -CompatJsonPath (Join-Path $script:TempRoot 'missing-compat.json') `
            -ReadinessJsonPath $placeholderReady `
            -ExperimentPlanJsonPath $placeholderExp `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        $missingCompat.valid | Should -BeFalse
        ($missingCompat.errors -join ' ') | Should -Match 'CompatJsonPath|Missing required'

        $missingReady = Test-XboxOSLabEvidenceChain `
            -CompatJsonPath $placeholderCompat `
            -ReadinessJsonPath (Join-Path $script:TempRoot 'missing-m5.json') `
            -ExperimentPlanJsonPath $placeholderExp `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        $missingReady.valid | Should -BeFalse
        ($missingReady.errors -join ' ') | Should -Match 'ReadinessJsonPath|Missing required'

        $missingExp = Test-XboxOSLabEvidenceChain `
            -CompatJsonPath $placeholderCompat `
            -ReadinessJsonPath $placeholderReady `
            -ExperimentPlanJsonPath (Join-Path $script:TempRoot 'missing-m6a.json') `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        $missingExp.valid | Should -BeFalse
        ($missingExp.errors -join ' ') | Should -Match 'ExperimentPlanJsonPath|Missing required'
    }

    It 'validates authoritative evidence chain when reports exist' {
        script:Skip-UnlessAuthEvidence
        $chain = Test-XboxOSLabEvidenceChain `
            -CompatJsonPath $script:AuthCompat `
            -ReadinessJsonPath $script:AuthReady `
            -ExperimentPlanJsonPath $script:AuthExp `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility `
            -EvidenceMode ExternalValidated
        $chain.valid | Should -BeTrue
        $chain.evidenceLabel | Should -Be 'ExternalValidatedEvidence'
        $chain.planHash | Should -Match '^[0-9A-F]{64}$'
        $chain.experimentPlanHash | Should -Match '^[0-9A-F]{64}$'
        $chain.activatesLayerD | Should -BeFalse
        $chain.activatesProvisioning | Should -BeFalse
    }

    It 'rejects altered M6A plan hash and M5 readiness digest' {
        script:Skip-UnlessAuthEvidence
        $tamperedExp = Join-Path $script:TempRoot 'tampered-m6a.json'
        $exp = Get-Content -LiteralPath $script:AuthExp -Raw -Encoding UTF8 | ConvertFrom-Json
        $exp.experimentPlan.contentHash = ('E' * 64)
        ($exp | ConvertTo-Json -Depth 14) | Set-Content -LiteralPath $tamperedExp -Encoding UTF8
        $badHash = Test-XboxOSLabEvidenceChain `
            -CompatJsonPath $script:AuthCompat `
            -ReadinessJsonPath $script:AuthReady `
            -ExperimentPlanJsonPath $tamperedExp `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        $badHash.valid | Should -BeFalse
        ($badHash.errors -join ' ') | Should -Match 'contentHash|canonical hash'

        $tamperedReady = Join-Path $script:TempRoot 'tampered-m5.json'
        $ready = Get-Content -LiteralPath $script:AuthReady -Raw -Encoding UTF8 | ConvertFrom-Json
        $ready.inventoryFingerprint = ('F' * 64)
        ($ready | ConvertTo-Json -Depth 14) | Set-Content -LiteralPath $tamperedReady -Encoding UTF8
        $badReady = Test-XboxOSLabEvidenceChain `
            -CompatJsonPath $script:AuthCompat `
            -ReadinessJsonPath $tamperedReady `
            -ExperimentPlanJsonPath $script:AuthExp `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        $badReady.valid | Should -BeFalse
        ($badReady.errors -join ' ') | Should -Match 'inventoryFingerprint|M5 readiness'
    }

    It 'rejects contradictory ISO identity and forged operation assessments' {
        script:Skip-UnlessAuthEvidence
        $tamperedExp = Join-Path $script:TempRoot 'bad-iso-m6a.json'
        $exp = Get-Content -LiteralPath $script:AuthExp -Raw -Encoding UTF8 | ConvertFrom-Json
        $exp.experimentPlan.sourceIsoSha256 = ('0' * 64)
        ($exp | ConvertTo-Json -Depth 14) | Set-Content -LiteralPath $tamperedExp -Encoding UTF8
        $badIso = Test-XboxOSLabEvidenceChain `
            -CompatJsonPath $script:AuthCompat `
            -ReadinessJsonPath $script:AuthReady `
            -ExperimentPlanJsonPath $tamperedExp `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        $badIso.valid | Should -BeFalse
        ($badIso.errors -join ' ') | Should -Match 'ISO|iso'

        $tamperedOps = Join-Path $script:TempRoot 'forged-ops-m6a.json'
        $exp2 = Get-Content -LiteralPath $script:AuthExp -Raw -Encoding UTF8 | ConvertFrom-Json
        $ops = @($exp2.experimentPlan.operations)
        $ops += [pscustomobject]@{
            operationId                   = 'forged-op-not-in-plan'
            targetIdentity                = 'Evil.Package'
            operationType                 = 'RemoveAppx'
            planStatus                    = 'Eligible'
            catalogCandidateReadiness     = 'MissingEvidence'
            effectiveReadiness            = 'MissingEvidence'
            dependencyClosureCompleteness = 'Incomplete'
        }
        $exp2.experimentPlan.operations = $ops
        ($exp2 | ConvertTo-Json -Depth 14) | Set-Content -LiteralPath $tamperedOps -Encoding UTF8
        $forged = Test-XboxOSLabEvidenceChain `
            -CompatJsonPath $script:AuthCompat `
            -ReadinessJsonPath $script:AuthReady `
            -ExperimentPlanJsonPath $tamperedOps `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        $forged.valid | Should -BeFalse
        ($forged.errors -join ' ') | Should -Match 'Forged|non-Eligible|contentHash'
    }

    It 'rejects missing evidence provenance on M6A plan' {
        script:Skip-UnlessAuthEvidence
        $path = Join-Path $script:TempRoot 'no-git-m6a.json'
        $exp = Get-Content -LiteralPath $script:AuthExp -Raw -Encoding UTF8 | ConvertFrom-Json
        $exp.experimentPlan.git = [pscustomobject]@{ gitCommitSha = 'Unknown'; gitDirty = 'False' }
        ($exp | ConvertTo-Json -Depth 14) | Set-Content -LiteralPath $path -Encoding UTF8
        $chain = Test-XboxOSLabEvidenceChain `
            -CompatJsonPath $script:AuthCompat `
            -ReadinessJsonPath $script:AuthReady `
            -ExperimentPlanJsonPath $path `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        $chain.valid | Should -BeFalse
        ($chain.errors -join ' ') | Should -Match 'provenance|git'
    }

    It 'supports explicit simulation-only fallback labeling' {
        $report = script:Invoke-LabSim -SimulateOperatorReview
        $report.evidenceMode | Should -Be 'InlineSimulation'
        $report.evidenceLabel | Should -Be 'InlineSimulationEvidence'
        $report.decision | Should -Be 'LabProvisioningBlocked'
        $report.labRealProvisioningEnabled | Should -BeFalse
        $report.layerDActivated | Should -BeFalse
    }

    It 'CLI refuses synthetic evidence without both simulation switches' {
        $cli = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts\Test-IsolatedLabReadiness.ps1') -Raw
        $cli | Should -Match 'AllowInlineSimulationReadiness requires -Simulation'
        $cli | Should -Match 'never falls back to synthetic evidence'
        $cli | Should -Match 'ExternalValidatedEvidence'
        $cli | Should -Match 'InlineSimulationEvidence'
    }

    It 'separates PolicyValidated from actual isolation verification' {
        $iso = Test-XboxOSLabVmIsolationPolicy -Topology $script:Topology
        $iso.valid | Should -BeTrue
        $iso.policyValidationStatus | Should -Be 'PolicyValidated'
        $iso.configurationStatus | Should -Be 'ConfigurationDeclared'
        $iso.hypervisorInspectionStatus | Should -Be 'HypervisorNotInspected'
        $iso.networkIsolationVerificationStatus | Should -Be 'NetworkIsolationNotVerified'
        $iso.environmentLimitationStatus | Should -Be 'EnvironmentLimited'
        $iso.actualIsolationVerified | Should -BeFalse
        $iso.declaredIsolationMode | Should -Be 'IsolatedSwitch'
        $iso.futureEvidenceSlots.vmEvidence | Should -BeNullOrEmpty
        $iso.futureEvidenceSlots.virtualSwitchEvidence | Should -BeNullOrEmpty
    }

    It 'does not treat declared IsolatedSwitch as proven network isolation' {
        $report = script:Invoke-LabSim -SimulateOperatorReview
        $report.isolation.declaredIsolationMode | Should -Be 'IsolatedSwitch'
        $report.isolation.actualIsolationVerified | Should -BeFalse
        $report.isolation.networkIsolationVerificationStatus | Should -Be 'NetworkIsolationNotVerified'
        $report.hypervisorInspectionStatus | Should -Be 'HypervisorNotInspected'
        $report.labHypervisorCommandsInvoked | Should -BeFalse
    }

    It 'rejects invalid ownership and snapshot/lab identity mismatch' {
        $own = New-XboxOSLabOwnershipRecord `
            -LabId 'lab-a' -VmId 'vm-a' -WorkspaceId 'ws-a' -OwnerId 'op' `
            -PlanHash $script:PlanHash -ReadinessBindingDigest $script:ReadinessDigest `
            -SourceIsoSha256 $script:IsoSha -WorkspaceRoot 'C:\XboxOS\Lab\Work' `
            -ExperimentPlanHash $script:ExperimentHash -InventoryFingerprint $script:InventoryFp
        $own.ownershipToken = ('0' * 64)
        $check = Test-XboxOSLabOwnershipRecord `
            -Record $own -ExpectedLabId 'lab-a' -ExpectedVmId 'vm-a' `
            -ExpectedPlanHash $script:PlanHash -ExpectedReadinessBindingDigest $script:ReadinessDigest `
            -ExpectedSourceIsoSha256 $script:IsoSha `
            -ExpectedExperimentPlanHash $script:ExperimentHash `
            -ExpectedInventoryFingerprint $script:InventoryFp
        $check.valid | Should -BeFalse
        ($check.errors -join ' ') | Should -Match 'Forged|ownership token'

        $good = New-XboxOSLabOwnershipRecord `
            -LabId 'lab-a' -VmId 'vm-a' -WorkspaceId 'ws-a' -OwnerId 'op' `
            -PlanHash $script:PlanHash -ReadinessBindingDigest $script:ReadinessDigest `
            -SourceIsoSha256 $script:IsoSha -WorkspaceRoot 'C:\XboxOS\Lab\Work' `
            -ExperimentPlanHash $script:ExperimentHash -InventoryFingerprint $script:InventoryFp
        $snap = New-XboxOSLabSnapshotRecord -Ownership $good -Purpose PreExperimentBaseline
        $other = New-XboxOSLabOwnershipRecord `
            -LabId 'lab-b' -VmId 'vm-b' -WorkspaceId 'ws-b' -OwnerId 'op' `
            -PlanHash $script:PlanHash -ReadinessBindingDigest $script:ReadinessDigest `
            -SourceIsoSha256 $script:IsoSha -WorkspaceRoot 'C:\XboxOS\Lab\Work' `
            -ExperimentPlanHash $script:ExperimentHash -InventoryFingerprint $script:InventoryFp
        $bind = Test-XboxOSLabSnapshotBinding -Snapshot $snap -Ownership $other
        $bind.valid | Should -BeFalse
        ($bind.errors -join ' ') | Should -Match 'labId|mismatch'
        $good.ownershipIsAuthorization | Should -BeFalse
    }

    It 'marks no functional-test Passed without runtime evidence' {
        $plan = New-XboxOSLabFunctionalTestPlan -FunctionalValidationCatalog $script:FvCatalog -VmEnvironment
        foreach ($t in @($plan.tests)) {
            $t.plannedStatus | Should -BeIn @('NotExecuted', 'EnvironmentLimited', 'MissingEvidence')
            $t.claimedPassed | Should -BeFalse
        }
        $report = script:Invoke-LabSim
        @($report.functionalTestPlan.tests | Where-Object { $_.plannedStatus -eq 'Passed' -or $_.claimedPassed }).Count | Should -Be 0
    }

    It 'keeps all mutation and provisioning flags False' {
        $report = script:Invoke-LabSim -SimulateOperatorReview
        foreach ($flag in @(
                'realDismExecutionEnabled', 'modifyingCommandsInvoked', 'executionAuthorized', 'servicingAuthorized',
                'experimentalMutationEnabled', 'experimentalExecutionAuthorized',
                'labRealProvisioningEnabled', 'labHypervisorCommandsInvoked', 'layerDActivated'
            )) {
            $report.$flag | Should -BeFalse
        }
    }

    It 'RecoveryRequired on injected fail-closed cases' {
        foreach ($kind in @('SnapshotMismatch', 'CleanupVerificationFailure', 'EvidenceSubstitution', 'IsoHashMismatch')) {
            Reset-XboxOSLabNonceRegistry
            $report = script:Invoke-LabSim -InjectFailure $kind
            $report.decision | Should -Be 'RecoveryRequired'
            $report.layerDActivated | Should -BeFalse
        }
    }

    It 'JSON and Markdown agree on decision, evidence label, and isolation verification' {
        $out = Join-Path $script:TempRoot 'reports'
        $report = script:Invoke-LabSim -SimulateOperatorReview
        $paths = Save-XboxOSIsolatedLabReport -Report $report -OutputDirectory $out -Stem 'XboxOS11-isolated-lab-m6b1-test' -RepoRoot $script:RepoRoot
        $json = Get-Content -LiteralPath $paths.JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $md = Get-Content -LiteralPath $paths.MarkdownPath -Raw -Encoding UTF8
        $json.decision | Should -Be $report.decision
        $json.evidenceLabel | Should -Be 'InlineSimulationEvidence'
        $md | Should -Match ([regex]::Escape([string]$report.decision))
        $md | Should -Match 'NetworkIsolationNotVerified'
        $md | Should -Match 'HypervisorNotInspected'
        $json.isolation.actualIsolationVerified | Should -BeFalse
    }

    It 'rejects unsafe workspace, production network, and OneDrive roots' {
        $t = script:Copy-LabTopology
        $t.paths.workspaceRoot = 'C:\Windows\Temp\XboxOSLab'
        (Test-XboxOSLabInfrastructureBoundaries -Topology $t -ExpectedIsoSha256 $script:IsoSha).valid | Should -BeFalse

        $t2 = script:Copy-LabTopology
        $t2.paths.workspaceRoot = 'C:\Users\schmi\OneDrive\WinDev Apps\XboxOS11\LabWork'
        (Test-XboxOSLabInfrastructureBoundaries -Topology $t2 -ExpectedIsoSha256 $script:IsoSha).valid | Should -BeFalse

        $t3 = script:Copy-LabTopology
        $t3.network.productionBridgeAllowed = $true
        (Test-XboxOSLabVmIsolationPolicy -Topology $t3).valid | Should -BeFalse
    }

    It 'rejects junction/reparse-point escapes and overlapping path roots' {
        $junction = Join-Path $script:TempRoot 'junction-ws'
        $target = Join-Path $script:TempRoot 'junction-target'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        if (Test-Path -LiteralPath $junction) { Remove-Item -LiteralPath $junction -Force -Recurse -ErrorAction SilentlyContinue }
        cmd /c mklink /J "$junction" "$target" | Out-Null
        $t = script:Copy-LabTopology
        $t.paths.workspaceRoot = $junction
        $t.paths.evidenceRoot = (Join-Path $script:TempRoot 'ev')
        $t.paths.virtualDiskRoot = (Join-Path $script:TempRoot 'vhd')
        $r = Test-XboxOSLabInfrastructureBoundaries -Topology $t -ExpectedIsoSha256 $script:IsoSha
        $r.valid | Should -BeFalse
        ($r.errors -join ' ') | Should -Match 'reparse|junction|symlink'

        $t2 = script:Copy-LabTopology
        $t2.paths.evidenceRoot = (Join-Path $t2.paths.workspaceRoot 'nested-evidence')
        $overlap = Test-XboxOSLabInfrastructureBoundaries -Topology $t2 -ExpectedIsoSha256 $script:IsoSha
        $overlap.valid | Should -BeFalse
        ($overlap.errors -join ' ') | Should -Match 'overlap'
    }

    It 'rejects approval replay, untrusted production key claims, and role collapse' {
        $n = 'nonce-m6b-closure-replay-1'
        $ok = Test-XboxOSLabKeyPolicy -TrustRootLabel 'test-approval-fixture' -Scope test-only -Nonce $n
        $ok.valid | Should -BeTrue
        $replay = Test-XboxOSLabKeyPolicy -TrustRootLabel 'test-approval-fixture' -Scope test-only -Nonce $n
        $replay.valid | Should -BeFalse
        ($replay.errors -join ' ') | Should -Match 'replay'
        $prod = Test-XboxOSLabKeyPolicy -TrustRootLabel 'test-approval-fixture' -Scope test-only -ClaimProductionTrust
        $prod.valid | Should -BeFalse
        $prod.activatesLayerD | Should -BeFalse
        $same = Test-XboxOSLabKeyPolicy -TrustRootLabel 'lab-root' -Scope lab-only -OperatorRole operator -AuthorizerRole operator
        $same.valid | Should -BeFalse
    }

    It 'rejects invalid state transitions and unreachable real provisioning' {
        { Assert-XboxOSLabTransactionTransition -From InfrastructurePlanned -To SimulationCompleted } | Should -Throw
        { Assert-XboxOSLabTransactionTransition -From InfrastructurePlanned -To RealProvisioning } | Should -Throw
        { Assert-XboxOSLabTransactionTransition -From SimulationCompleted -To WritableExecution } | Should -Throw
        $tx = New-XboxOSLabTransaction -LabId 'lab-trans'
        $null = Set-XboxOSLabTransactionState -Transaction $tx -To ConfigurationValidated -Note 'ok'
        $null = Set-XboxOSLabTransactionState -Transaction $tx -To SimulationReady -Note 'ok'
        $null = Set-XboxOSLabTransactionState -Transaction $tx -To SimulationCompleted -Note 'ok'
        $null = Set-XboxOSLabTransactionState -Transaction $tx -To LabProvisioningBlocked -Note 'block'
        $tx.state | Should -Be 'LabProvisioningBlocked'
        $tx.labRealProvisioningEnabled | Should -BeFalse
        $tx.layerDActivated | Should -BeFalse
    }

    It 'records m6b evidence custody and Simulation provider without admin assumption' {
        $report = script:Invoke-LabSim -SimulateOperatorReview
        $report.evidenceManifest.reportNamespace | Should -Be 'm6b'
        $report.evidenceManifest.preservesPriorBaselines | Should -BeTrue
        $report.providerKind | Should -Be 'Simulation'
        $script:Topology.provider.requiresAdministrator | Should -BeFalse
        $script:Topology.provider.assumesHypervisorInstalled | Should -BeFalse
        @($report.evidenceManifest.missingEvidence).Count | Should -BeGreaterThan 0
    }

    It 'simulated failure helper never performs global DISM cleanup' {
        $tx = New-XboxOSLabTransaction -LabId 'lab-fail'
        $null = Set-XboxOSLabTransactionState -Transaction $tx -To ConfigurationValidated
        $fail = Invoke-XboxOSLabSimulatedFailure -Transaction $tx -FailureKind InterruptedExperiment
        $fail.state | Should -Be 'RecoveryRequired'
        $fail.globalDismCleanupPerformed | Should -BeFalse
        $fail.unrelatedHiveUnloadPerformed | Should -BeFalse
        $fail.realProvisioningAttempted | Should -BeFalse
    }

    It 'marks GPU/controller/anti-cheat EnvironmentLimited specifically' {
        $plan = New-XboxOSLabFunctionalTestPlan -FunctionalValidationCatalog $script:FvCatalog -VmEnvironment
        $byId = @{}
        foreach ($t in @($plan.tests)) { $byId[$t.testId] = $t }
        $byId['fv-graphics-dx-enum'].plannedStatus | Should -Be 'EnvironmentLimited'
        $byId['fv-controller-usb-bt'].plannedStatus | Should -Be 'EnvironmentLimited'
        $byId['fv-anticheat-checklist'].plannedStatus | Should -Be 'EnvironmentLimited'
        $byId['fv-xbox-fse-startup'].plannedStatus | Should -Be 'MissingEvidence'
    }
}
