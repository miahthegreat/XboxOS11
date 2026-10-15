#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'XboxOS11 Milestone 6B isolated lab infrastructure (simulation)' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        Import-Module (Join-Path $repoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force
        $script:RepoRoot = $repoRoot.Path
        $script:TopologyPath = Join-Path $script:RepoRoot 'config\lab-topology.json'
        $script:Topology = Import-XboxOSLabTopologyCatalog -Path $script:TopologyPath
        $script:FvCatalog = Import-XboxOSFunctionalValidationCatalog -Path (Join-Path $script:RepoRoot 'config\functional-validation-matrix.json')
        $script:PlanHash = ('A' * 64)
        $script:ReadinessDigest = ('B' * 64)
        $script:IsoSha = 'BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650'
        $script:TempRoot = Join-Path $env:TEMP ('XboxOS11-m6b-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        Reset-XboxOSLabNonceRegistry

        function script:Copy-LabTopology {
            param([object]$Source = $script:Topology)
            return ($Source | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
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

    It 'reports Milestone 6B engine and schema versions' {
        Get-XboxOSIsolatedLabEngineVersion | Should -Be '6.1.0-b'
        Get-XboxOSLabTopologySchemaVersion | Should -Be 'lab-topology-v1'
        Get-XboxOSLabIsolationSchemaVersion | Should -Be 'lab-isolation-v1'
        Get-XboxOSLabOwnershipSchemaVersion | Should -Be 'lab-ownership-v1'
        Get-XboxOSLabSnapshotSchemaVersion | Should -Be 'lab-snapshot-v1'
        Get-XboxOSLabTransactionSchemaVersion | Should -Be 'lab-transaction-v1'
        Get-XboxOSLabEvidenceSchemaVersion | Should -Be 'lab-evidence-v1'
        Get-XboxOSLabKeyPolicySchemaVersion | Should -Be 'lab-key-policy-v1'
        Get-XboxOSLabRealProvisioningEnabled | Should -BeFalse
        Get-XboxOSLabHypervisorCommandsInvoked | Should -BeFalse
        Get-XboxOSRealDismExecutionEnabled | Should -BeFalse
        Get-XboxOSExperimentalExecutionAuthorized | Should -BeFalse
    }

    It 'loads Hyper-V-oriented Simulation topology without assuming hypervisor installed' {
        $script:Topology.provider.kind | Should -Be 'Simulation'
        $script:Topology.provider.hyperVOriented | Should -BeTrue
        $script:Topology.provider.assumesHypervisorInstalled | Should -BeFalse
        $script:Topology.provider.requiresAdministrator | Should -BeFalse
        $script:Topology.vm.dedicatedDisposable | Should -BeTrue
        $script:Topology.network.productionBridgeAllowed | Should -BeFalse
    }

    It 'rejects unsafe workspace locations' {
        $t = script:Copy-LabTopology
        $t.paths.workspaceRoot = 'C:\Windows\Temp\XboxOSLab'
        $r = Test-XboxOSLabInfrastructureBoundaries -Topology $t -ExpectedIsoSha256 $script:IsoSha
        $r.valid | Should -BeFalse
        ($r.errors -join ' ') | Should -Match 'Windows|reserved'
    }

    It 'rejects OneDrive / cloud-sync workspace roots' {
        $t = script:Copy-LabTopology
        $t.paths.workspaceRoot = 'C:\Users\schmi\OneDrive\WinDev Apps\XboxOS11\LabWork'
        $r = Test-XboxOSLabInfrastructureBoundaries -Topology $t -ExpectedIsoSha256 $script:IsoSha
        $r.valid | Should -BeFalse
        ($r.errors -join ' ') | Should -Match 'OneDrive|cloud-sync'
    }

    It 'rejects junction / reparse-point escapes when path exists' {
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
    }

    It 'rejects overlapping source/output/workspace roots' {
        $t = script:Copy-LabTopology
        $t.paths.evidenceRoot = (Join-Path $t.paths.workspaceRoot 'nested-evidence')
        $r = Test-XboxOSLabInfrastructureBoundaries -Topology $t -ExpectedIsoSha256 $script:IsoSha
        $r.valid | Should -BeFalse
        ($r.errors -join ' ') | Should -Match 'overlap'
    }

    It 'rejects production network exposure in isolation policy' {
        $t = script:Copy-LabTopology
        $t.network.productionBridgeAllowed = $true
        $t.network.hostAdminSharesAllowed = $true
        $iso = Test-XboxOSLabVmIsolationPolicy -Topology $t
        $iso.valid | Should -BeFalse
        ($iso.errors -join ' ') | Should -Match 'Production network bridge'
        ($iso.errors -join ' ') | Should -Match 'administrative shares'
    }

    It 'rejects forged lab ownership tokens and incorrect VM ownership' {
        $own = New-XboxOSLabOwnershipRecord `
            -LabId 'lab-a' -VmId 'vm-a' -WorkspaceId 'ws-a' -OwnerId 'op' `
            -PlanHash $script:PlanHash -ReadinessBindingDigest $script:ReadinessDigest `
            -SourceIsoSha256 $script:IsoSha -WorkspaceRoot 'C:\XboxOS\Lab\Work'
        $own.ownershipToken = ('0' * 64)
        $check = Test-XboxOSLabOwnershipRecord `
            -Record $own -ExpectedLabId 'lab-a' -ExpectedVmId 'vm-a' `
            -ExpectedPlanHash $script:PlanHash -ExpectedReadinessBindingDigest $script:ReadinessDigest `
            -ExpectedSourceIsoSha256 $script:IsoSha
        $check.valid | Should -BeFalse
        ($check.errors -join ' ') | Should -Match 'Forged|ownership token'

        $wrongVm = Test-XboxOSLabOwnershipRecord `
            -Record $own -ExpectedLabId 'lab-a' -ExpectedVmId 'vm-other' `
            -ExpectedPlanHash $script:PlanHash -ExpectedReadinessBindingDigest $script:ReadinessDigest `
            -ExpectedSourceIsoSha256 $script:IsoSha
        $wrongVm.valid | Should -BeFalse
        ($wrongVm.errors -join ' ') | Should -Match 'VM identity'
    }

    It 'rejects missing source hashes on ownership records' {
        $own = New-XboxOSLabOwnershipRecord `
            -LabId 'lab-a' -VmId 'vm-a' -WorkspaceId 'ws-a' -OwnerId 'op' `
            -PlanHash $script:PlanHash -ReadinessBindingDigest $script:ReadinessDigest `
            -SourceIsoSha256 $script:IsoSha -WorkspaceRoot 'C:\XboxOS\Lab\Work'
        $check = Test-XboxOSLabOwnershipRecord `
            -Record $own -ExpectedLabId 'lab-a' -ExpectedVmId 'vm-a' `
            -ExpectedPlanHash $script:PlanHash -ExpectedReadinessBindingDigest $script:ReadinessDigest `
            -ExpectedSourceIsoSha256 ('C' * 64)
        $check.valid | Should -BeFalse
        ($check.errors -join ' ') | Should -Match 'Source ISO hash'
    }

    It 'rejects snapshot mismatch across labs' {
        $own = New-XboxOSLabOwnershipRecord `
            -LabId 'lab-a' -VmId 'vm-a' -WorkspaceId 'ws-a' -OwnerId 'op' `
            -PlanHash $script:PlanHash -ReadinessBindingDigest $script:ReadinessDigest `
            -SourceIsoSha256 $script:IsoSha -WorkspaceRoot 'C:\XboxOS\Lab\Work'
        $snap = New-XboxOSLabSnapshotRecord -Ownership $own -Purpose PreExperimentBaseline
        $other = New-XboxOSLabOwnershipRecord `
            -LabId 'lab-b' -VmId 'vm-b' -WorkspaceId 'ws-b' -OwnerId 'op' `
            -PlanHash $script:PlanHash -ReadinessBindingDigest $script:ReadinessDigest `
            -SourceIsoSha256 $script:IsoSha -WorkspaceRoot 'C:\XboxOS\Lab\Work'
        $bind = Test-XboxOSLabSnapshotBinding -Snapshot $snap -Ownership $other
        $bind.valid | Should -BeFalse
        ($bind.errors -join ' ') | Should -Match 'labId|mismatch'
    }

    It 'rejects approval replay and untrusted production key claims' {
        $n = 'nonce-m6b-replay-1'
        $ok = Test-XboxOSLabKeyPolicy -TrustRootLabel 'test-approval-fixture' -Scope test-only -Nonce $n
        $ok.valid | Should -BeTrue
        $replay = Test-XboxOSLabKeyPolicy -TrustRootLabel 'test-approval-fixture' -Scope test-only -Nonce $n
        $replay.valid | Should -BeFalse
        ($replay.errors -join ' ') | Should -Match 'replay'

        $prod = Test-XboxOSLabKeyPolicy -TrustRootLabel 'test-approval-fixture' -Scope test-only -ClaimProductionTrust
        $prod.valid | Should -BeFalse
        ($prod.errors -join ' ') | Should -Match 'production trust'
        $prod.activatesLayerD | Should -BeFalse
        $prod.grantsWritableMutation | Should -BeFalse

        $sameRole = Test-XboxOSLabKeyPolicy -TrustRootLabel 'lab-root' -Scope lab-only -OperatorRole operator -AuthorizerRole operator
        $sameRole.valid | Should -BeFalse
        ($sameRole.errors -join ' ') | Should -Match 'separated'
    }

    It 'rejects tampered experiment evidence via IsoHashMismatch fail-closed' {
        $report = Invoke-XboxOSIsolatedLabSimulate `
            -Topology $script:Topology `
            -FunctionalValidationCatalog $script:FvCatalog `
            -PlanHash $script:PlanHash `
            -ReadinessBindingDigest $script:ReadinessDigest `
            -SourceIsoSha256 $script:IsoSha `
            -RepoRoot $script:RepoRoot `
            -InjectFailure IsoHashMismatch
        $report.decision | Should -Be 'RecoveryRequired'
        $report.transactionState | Should -Be 'RecoveryRequired'
        ($report.blockers -join ' ') | Should -Match 'ISO hash mismatch'
        $report.layerDActivated | Should -BeFalse
        $report.labRealProvisioningEnabled | Should -BeFalse
    }

    It 'transitions to RecoveryRequired for snapshot mismatch and cleanup failure' {
        foreach ($kind in @('SnapshotMismatch', 'CleanupVerificationFailure', 'EvidenceSubstitution')) {
            Reset-XboxOSLabNonceRegistry
            $report = Invoke-XboxOSIsolatedLabSimulate `
                -Topology $script:Topology `
                -FunctionalValidationCatalog $script:FvCatalog `
                -PlanHash $script:PlanHash `
                -ReadinessBindingDigest $script:ReadinessDigest `
                -SourceIsoSha256 $script:IsoSha `
                -RepoRoot $script:RepoRoot `
                -InjectFailure $kind
            $report.decision | Should -Be 'RecoveryRequired'
            $report.transaction.state | Should -Be 'RecoveryRequired'
            $report.labHypervisorCommandsInvoked | Should -BeFalse
            $report.labRealProvisioningEnabled | Should -BeFalse
        }
    }

    It 'rejects invalid state transitions and unreachable real provisioning' {
        { Assert-XboxOSLabTransactionTransition -From InfrastructurePlanned -To SimulationCompleted } | Should -Throw
        { Assert-XboxOSLabTransactionTransition -From InfrastructurePlanned -To RealProvisioning } | Should -Throw
        { Assert-XboxOSLabTransactionTransition -From SimulationCompleted -To WritableExecution } | Should -Throw
        { Assert-XboxOSLabTransactionTransition -From LabProvisioningBlocked -To LiveMutation } | Should -Throw

        $tx = New-XboxOSLabTransaction -LabId 'lab-trans'
        $null = Set-XboxOSLabTransactionState -Transaction $tx -To ConfigurationValidated -Note 'ok'
        $null = Set-XboxOSLabTransactionState -Transaction $tx -To SimulationReady -Note 'ok'
        $null = Set-XboxOSLabTransactionState -Transaction $tx -To SimulationCompleted -Note 'ok'
        $null = Set-XboxOSLabTransactionState -Transaction $tx -To LabProvisioningBlocked -Note 'block'
        $tx.state | Should -Be 'LabProvisioningBlocked'
        $tx.labRealProvisioningEnabled | Should -BeFalse
        $tx.layerDActivated | Should -BeFalse
    }

    It 'marks GPU/controller/anti-cheat tests EnvironmentLimited, never Passed' {
        $plan = New-XboxOSLabFunctionalTestPlan -FunctionalValidationCatalog $script:FvCatalog -VmEnvironment
        $plan.inventsResults | Should -BeFalse
        $byId = @{}
        foreach ($t in @($plan.tests)) { $byId[$t.testId] = $t }
        $byId['fv-graphics-dx-enum'].plannedStatus | Should -Be 'EnvironmentLimited'
        $byId['fv-controller-usb-bt'].plannedStatus | Should -Be 'EnvironmentLimited'
        $byId['fv-xinput-smoke'].plannedStatus | Should -Be 'EnvironmentLimited'
        $byId['fv-gameinput-smoke'].plannedStatus | Should -Be 'EnvironmentLimited'
        $byId['fv-anticheat-checklist'].plannedStatus | Should -Be 'EnvironmentLimited'
        $byId['fv-xbox-fse-startup'].plannedStatus | Should -Be 'MissingEvidence'
        $byId['fv-store-license-smoke'].plannedStatus | Should -Be 'MissingEvidence'
        foreach ($t in @($plan.tests)) {
            $t.plannedStatus | Should -BeIn @('NotExecuted', 'EnvironmentLimited', 'MissingEvidence')
            $t.claimedPassed | Should -BeFalse
        }
    }

    It 'evidence custody uses m6b namespace and records incomplete coverage' {
        $report = Invoke-XboxOSIsolatedLabSimulate `
            -Topology $script:Topology `
            -FunctionalValidationCatalog $script:FvCatalog `
            -PlanHash $script:PlanHash `
            -ReadinessBindingDigest $script:ReadinessDigest `
            -SourceIsoSha256 $script:IsoSha `
            -RepoRoot $script:RepoRoot `
            -SimulateOperatorReview
        $ev = $report.evidenceManifest
        $ev.reportNamespace | Should -Be 'm6b'
        $ev.preservesPriorBaselines | Should -BeTrue
        $ev.layerDActivated | Should -BeFalse
        @($ev.missingEvidence).Count | Should -BeGreaterThan 0
        @($ev.testCoverage).Count | Should -BeGreaterOrEqual 14
        $ev.cleanupStatus | Should -Match 'Simulation'
    }

    It 'happy-path simulation ends LabProvisioningBlocked with all safety flags False' {
        $report = Invoke-XboxOSIsolatedLabSimulate `
            -Topology $script:Topology `
            -FunctionalValidationCatalog $script:FvCatalog `
            -PlanHash $script:PlanHash `
            -ReadinessBindingDigest $script:ReadinessDigest `
            -SourceIsoSha256 $script:IsoSha `
            -RepoRoot $script:RepoRoot `
            -SimulateOperatorReview
        $report.decision | Should -Be 'LabProvisioningBlocked'
        $report.transactionState | Should -Be 'LabProvisioningBlocked'
        $report.isolation.valid | Should -BeTrue
        $report.boundary.valid | Should -BeTrue
        $report.boundary.planningPermissionOnly | Should -BeTrue
        $report.providerKind | Should -Be 'Simulation'
        foreach ($flag in @(
                'realDismExecutionEnabled', 'modifyingCommandsInvoked', 'executionAuthorized', 'servicingAuthorized',
                'experimentalMutationEnabled', 'experimentalExecutionAuthorized',
                'labRealProvisioningEnabled', 'labHypervisorCommandsInvoked', 'layerDActivated'
            )) {
            $report.$flag | Should -BeFalse
        }
        Assert-XboxOSIsolatedLabSafetyInvariants -Report $report
        # Hypervisor unavailable is informational for Simulation
        if (-not $report.hypervisorAvailable) {
            @($report.hypervisorNotes).Count | Should -BeGreaterThan 0
        }
    }

    It 'records hypervisor unavailable without inventing Passed functional results' {
        $report = Invoke-XboxOSIsolatedLabSimulate `
            -Topology $script:Topology `
            -FunctionalValidationCatalog $script:FvCatalog `
            -PlanHash $script:PlanHash `
            -ReadinessBindingDigest $script:ReadinessDigest `
            -SourceIsoSha256 $script:IsoSha `
            -RepoRoot $script:RepoRoot
        $passed = @($report.functionalTestPlan.tests | Where-Object claimedPassed -eq $true)
        $passed.Count | Should -Be 0
        $report.labHypervisorCommandsInvoked | Should -BeFalse
    }

    It 'works without administrator privileges for Simulation provider' {
        $script:Topology.provider.requiresAdministrator | Should -BeFalse
        # Do not require elevation; simulation must remain usable when not elevated.
        $isAdmin = Test-XboxOSAdministrator
        $report = Invoke-XboxOSIsolatedLabSimulate `
            -Topology $script:Topology `
            -FunctionalValidationCatalog $script:FvCatalog `
            -PlanHash $script:PlanHash `
            -ReadinessBindingDigest $script:ReadinessDigest `
            -SourceIsoSha256 $script:IsoSha `
            -RepoRoot $script:RepoRoot
        $report.decision | Should -Be 'LabProvisioningBlocked'
        if (-not $isAdmin) {
            $report.labRealProvisioningEnabled | Should -BeFalse
        }
    }

    It 'JSON and Markdown reports agree on decision and safety flags' {
        $out = Join-Path $script:TempRoot 'reports'
        $report = Invoke-XboxOSIsolatedLabSimulate `
            -Topology $script:Topology `
            -FunctionalValidationCatalog $script:FvCatalog `
            -PlanHash $script:PlanHash `
            -ReadinessBindingDigest $script:ReadinessDigest `
            -SourceIsoSha256 $script:IsoSha `
            -RepoRoot $script:RepoRoot `
            -SimulateOperatorReview
        $paths = Save-XboxOSIsolatedLabReport -Report $report -OutputDirectory $out -Stem 'XboxOS11-isolated-lab-m6b-test' -RepoRoot $script:RepoRoot
        $json = Get-Content -LiteralPath $paths.JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $md = Get-Content -LiteralPath $paths.MarkdownPath -Raw -Encoding UTF8
        $json.decision | Should -Be $report.decision
        $md | Should -Match ([regex]::Escape([string]$report.decision))
        $md | Should -Match 'labRealProvisioningEnabled'
        $json.layerDActivated | Should -BeFalse
        $json.labRealProvisioningEnabled | Should -BeFalse
        { Save-XboxOSIsolatedLabReport -Report $report -OutputDirectory $out -Stem 'XboxOS11-servicing-readiness-m5' -RepoRoot $script:RepoRoot } | Should -Throw
    }

    It 'CLI script is simulation-only and never activates Layer D' {
        $cli = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts\Test-IsolatedLabReadiness.ps1') -Raw
        $cli | Should -Match 'simulation only'
        $cli | Should -Match 'Get-XboxOSLabRealProvisioningEnabled'
        $cli | Should -Not -Match '(?i)Mount-WindowsImage|Dismount-WindowsImage|New-VM\b|Enable-WindowsOptionalFeature'
        $cli | Should -Match 'exit 2'
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
}
