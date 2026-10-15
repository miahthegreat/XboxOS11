#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'XboxOS11 Milestone 6C read-only host lab discovery (mocked)' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        Import-Module (Join-Path $repoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force
        $script:RepoRoot = $repoRoot.Path
        $script:Allowlist = Import-XboxOSHostDiscoveryAllowlistCatalog -Path (Join-Path $script:RepoRoot 'config\host-discovery-allowlist.json')
        $script:TempRoot = Join-Path $env:TEMP ('XboxOS11-m6c-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        $script:GitSha = 'fixture-git-sha-for-simulation'
        Reset-XboxOSHostDiscoveryNonceRegistry
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        Reset-XboxOSHostDiscoveryNonceRegistry
    }

    BeforeEach {
        Reset-XboxOSHostDiscoveryNonceRegistry
    }

    It 'reports Milestone 6C engine and schema versions' {
        Get-XboxOSHostDiscoveryEngineVersion | Should -Be '6.2.0-c'
        Get-XboxOSHostDiscoveryApprovalSchemaVersion | Should -Be 'host-discovery-approval-v1'
        Get-XboxOSHostDiscoveryAllowlistSchemaVersion | Should -Be 'host-discovery-allowlist-v1'
        Get-XboxOSHostDiscoveryIsolationSchemaVersion | Should -Be 'host-discovery-isolation-v1'
        Get-XboxOSHostDiscoveryRealHostCommandsInvoked | Should -BeFalse
        Get-XboxOSLabRealProvisioningEnabled | Should -BeFalse
        Get-XboxOSExperimentalExecutionAuthorized | Should -BeFalse
        Get-XboxOSRealDismExecutionEnabled | Should -BeFalse
    }

    It 'defaults to HostDiscoveryBlocked without approval' {
        $report = Invoke-XboxOSHostLabDiscoverySimulate -Allowlist $script:Allowlist -RepoRoot $script:RepoRoot -ExpectedGitCommitSha $script:GitSha
        $report.decision | Should -Be 'HostDiscoveryBlocked'
        $report.approvalValid | Should -BeFalse
        $report.hostDiscoveryRealHostCommandsInvoked | Should -BeFalse
        $report.realHostInspectionEnabled | Should -BeFalse
        $report.layerDActivated | Should -BeFalse
    }

    It 'rejects missing, expired, replayed, wrong-host, wrong-git, and wrong-scope approvals' {
        $hostId = New-XboxOSHostIdentity -Fixture
        $scope = New-XboxOSHostDiscoveryScope
        $approval = New-XboxOSHostDiscoveryApprovalRecord `
            -OperatorId 'op' -HostIdentity $hostId -DiscoveryScope $scope `
            -GitCommitSha $script:GitSha -ApprovedCategories @($scope.categories) -ReadOnlyAcknowledged

        $expired = Invoke-XboxOSHostLabDiscoverySimulate -Allowlist $script:Allowlist -HostIdentity $hostId -DiscoveryScope $scope `
            -Approval $approval -ExpectedGitCommitSha $script:GitSha -InjectFailure ExpiredApproval
        $expired.decision | Should -Be 'RecoveryRequired'
        ($expired.blockers -join ' ') | Should -Match 'expired'

        Reset-XboxOSHostDiscoveryNonceRegistry
        $approval2 = New-XboxOSHostDiscoveryApprovalRecord `
            -OperatorId 'op' -HostIdentity $hostId -DiscoveryScope $scope `
            -GitCommitSha $script:GitSha -ApprovedCategories @($scope.categories) -ReadOnlyAcknowledged
        $replay = Invoke-XboxOSHostLabDiscoverySimulate -Allowlist $script:Allowlist -HostIdentity $hostId -DiscoveryScope $scope `
            -Approval $approval2 -ExpectedGitCommitSha $script:GitSha -InjectFailure ReplayApproval
        ($replay.blockers -join ' ') | Should -Match 'replay'

        Reset-XboxOSHostDiscoveryNonceRegistry
        $approval3 = New-XboxOSHostDiscoveryApprovalRecord `
            -OperatorId 'op' -HostIdentity $hostId -DiscoveryScope $scope `
            -GitCommitSha $script:GitSha -ApprovedCategories @($scope.categories) -ReadOnlyAcknowledged
        foreach ($kind in @('WrongHostIdentity', 'WrongGitSha', 'WrongScope')) {
            Reset-XboxOSHostDiscoveryNonceRegistry
            $a = New-XboxOSHostDiscoveryApprovalRecord `
                -OperatorId 'op' -HostIdentity $hostId -DiscoveryScope $scope `
                -GitCommitSha $script:GitSha -ApprovedCategories @($scope.categories) -ReadOnlyAcknowledged
            $r = Invoke-XboxOSHostLabDiscoverySimulate -Allowlist $script:Allowlist -HostIdentity $hostId -DiscoveryScope $scope `
                -Approval $a -ExpectedGitCommitSha $script:GitSha -InjectFailure $kind
            $r.decision | Should -Be 'RecoveryRequired'
            $r.approvalValid | Should -BeFalse
        }
    }

    It 'rejects reuse of M6A consent, M6B trust policy, or Layer D claims' {
        $hostId = New-XboxOSHostIdentity -Fixture
        $scope = New-XboxOSHostDiscoveryScope
        { New-XboxOSHostDiscoveryApprovalRecord -OperatorId 'op' -HostIdentity $hostId -DiscoveryScope $scope -GitCommitSha $script:GitSha -ApprovedCategories @('OsInformation') -ReadOnlyAcknowledged -ClaimReuseM6aConsent } | Should -Throw
        { New-XboxOSHostDiscoveryApprovalRecord -OperatorId 'op' -HostIdentity $hostId -DiscoveryScope $scope -GitCommitSha $script:GitSha -ApprovedCategories @('OsInformation') -ReadOnlyAcknowledged -ClaimReuseM6bTrustPolicy } | Should -Throw
        { New-XboxOSHostDiscoveryApprovalRecord -OperatorId 'op' -HostIdentity $hostId -DiscoveryScope $scope -GitCommitSha $script:GitSha -ApprovedCategories @('OsInformation') -ReadOnlyAcknowledged -ClaimLayerD } | Should -Throw
        { New-XboxOSHostDiscoveryApprovalRecord -OperatorId 'op' -HostIdentity $hostId -DiscoveryScope $scope -GitCommitSha $script:GitSha -ApprovedCategories @('OsInformation') } | Should -Throw
    }

    It 'rejects non-allowlisted commands and denied side-effect patterns' {
        $deny = Test-XboxOSHostDiscoveryCommandAllowed -Allowlist $script:Allowlist -OperationId 'New-VM'
        $deny.allowed | Should -BeFalse
        $adapter = New-XboxOSMockHostDiscoveryAdapter -Allowlist $script:Allowlist
        { Invoke-XboxOSHostDiscoveryAdapterOperation -Adapter $adapter -OperationId 'Enable-WindowsOptionalFeature' } | Should -Throw
        $report = Invoke-XboxOSHostLabDiscoverySimulate -Allowlist $script:Allowlist -ExpectedGitCommitSha $script:GitSha -InjectFailure NonAllowlistedCommand
        ($report.blockers -join ' ') | Should -Match 'Non-allowlisted|allowlist|Denied'
    }

    It 'represents unavailable Hyper-V cmdlets as Unavailable without inventing empty VM inventory' {
        $report = Invoke-XboxOSHostLabDiscoverySimulate -Allowlist $script:Allowlist -ExpectedGitCommitSha $script:GitSha -SimulateHyperVUnavailable
        $report.vmInventory.availability | Should -Be 'Unavailable'
        $report.vmInventory.vms | Should -BeNullOrEmpty
        ($report.vmInventory.notes -join ' ') | Should -Match 'Unavailable|empty'
        $report.switchInventory.availability | Should -Be 'Unavailable'
    }

    It 'treats insufficient privileges as Unavailable observations' {
        $hostId = New-XboxOSHostIdentity -Fixture
        $scope = New-XboxOSHostDiscoveryScope
        $approval = New-XboxOSHostDiscoveryApprovalRecord `
            -OperatorId 'op' -HostIdentity $hostId -DiscoveryScope $scope `
            -GitCommitSha $script:GitSha -ApprovedCategories @($scope.categories) -ReadOnlyAcknowledged
        $report = Invoke-XboxOSHostLabDiscoverySimulate -Allowlist $script:Allowlist -HostIdentity $hostId -DiscoveryScope $scope `
            -Approval $approval -ExpectedGitCommitSha $script:GitSha -SimulateInsufficientPrivileges
        $os = @($report.operationResults | Where-Object operationId -eq 'Get-OsInfo' | Select-Object -First 1)
        $os.status | Should -Be 'Unavailable'
        $report.hostDiscoveryRealHostCommandsInvoked | Should -BeFalse
    }

    It 'does not verify isolation from IsolatedSwitch name or Private/Internal type alone' {
        $byName = Test-XboxOSHostDiscoveryIsolationObservations -ProposedSwitchName 'IsolatedSwitch' -SwitchInventoryAvailability Unavailable -ObservationSource MockFixture
        $byName.actualIsolationVerified | Should -BeFalse
        ($byName.notes -join ' ') | Should -Match 'not proof'

        $private = Test-XboxOSHostDiscoveryIsolationObservations `
            -ProposedSwitchName 'LabSwitch' `
            -ObservedSwitches @([pscustomobject]@{ name = 'LabSwitch'; type = 'Private' }) `
            -ObservedVms @() `
            -SwitchInventoryAvailability Available `
            -ObservationSource MockFixture
        $private.actualIsolationVerified | Should -BeFalse
        ($private.criteria | Where-Object id -eq 'switch-type').state | Should -Be 'Unverified'
    }

    It 'flags network bridge conflicts and production VM sharing as Unsafe' {
        $bridge = Test-XboxOSHostDiscoveryIsolationObservations `
            -ProposedSwitchName 'LabSwitch' `
            -ObservedSwitches @([pscustomobject]@{ name = 'LabSwitch'; type = 'External' }) `
            -ObservedVms @([pscustomobject]@{ name = 'prod-vm'; productionTagged = $true; sharesLabSwitchWithProduction = $true }) `
            -SwitchInventoryAvailability Available `
            -ProductionBridgeObserved `
            -ObservationSource MockFixture
        ($bridge.criteria | Where-Object id -eq 'switch-type').state | Should -Be 'Unsafe'
        ($bridge.criteria | Where-Object id -eq 'production-bridge').state | Should -Be 'Unsafe'
        ($bridge.criteria | Where-Object id -eq 'production-vm-sharing').state | Should -Be 'Unsafe'
        $bridge.actualIsolationVerified | Should -BeFalse
    }

    It 'keeps unknown firewall state Unavailable and rejects fixture production verification' {
        $fw = Test-XboxOSHostDiscoveryIsolationObservations -ProposedSwitchName 'IsolatedSwitch' -SwitchInventoryAvailability Unavailable -ObservationSource MockFixture
        ($fw.criteria | Where-Object id -eq 'firewall-evidence').state | Should -Be 'Unavailable'

        $claim = Test-XboxOSHostDiscoveryIsolationObservations `
            -ProposedSwitchName 'LabSwitch' `
            -ObservedSwitches @([pscustomobject]@{ name = 'LabSwitch'; type = 'Private' }) `
            -ObservedVms @() `
            -SwitchInventoryAvailability Available `
            -FirewallEvidenceAvailable `
            -ClaimProductionVerificationFromFixture `
            -ObservationSource MockFixture
        $claim.actualIsolationVerified | Should -BeFalse
        ($claim.notes -join ' ') | Should -Match 'Mock/fixture'
    }

    It 'rejects workspace escapes and path cloud-sync locations' {
        $scope = New-XboxOSHostDiscoveryScope -WorkspaceRoot 'C:\Users\schmi\OneDrive\WinDev Apps\XboxOS11\LabWork'
        $report = Invoke-XboxOSHostLabDiscoverySimulate -Allowlist $script:Allowlist -DiscoveryScope $scope -ExpectedGitCommitSha $script:GitSha
        ($report.blockers -join ' ') | Should -Match 'OneDrive|cloud-sync|Workspace'

        $escape = Invoke-XboxOSHostLabDiscoverySimulate -Allowlist $script:Allowlist -ExpectedGitCommitSha $script:GitSha -InjectFailure WorkspaceEscape
        $escape.decision | Should -Be 'RecoveryRequired'
    }

    It 'mocked approval simulation still ends HostDiscoveryBlocked with flags False' {
        $hostId = New-XboxOSHostIdentity -Fixture
        $scope = New-XboxOSHostDiscoveryScope
        $approval = New-XboxOSHostDiscoveryApprovalRecord `
            -OperatorId 'op' -HostIdentity $hostId -DiscoveryScope $scope `
            -GitCommitSha $script:GitSha -ApprovedCategories @($scope.categories) -ReadOnlyAcknowledged
        $report = Invoke-XboxOSHostLabDiscoverySimulate -Allowlist $script:Allowlist -HostIdentity $hostId -DiscoveryScope $scope `
            -Approval $approval -ExpectedGitCommitSha $script:GitSha -SimulateHyperVUnavailable
        $report.decision | Should -Be 'HostDiscoveryBlocked'
        $report.approvalValid | Should -BeTrue
        $report.isolation.actualIsolationVerified | Should -BeFalse
        foreach ($flag in @(
                'realDismExecutionEnabled', 'modifyingCommandsInvoked', 'executionAuthorized', 'servicingAuthorized',
                'experimentalMutationEnabled', 'experimentalExecutionAuthorized',
                'labRealProvisioningEnabled', 'labHypervisorCommandsInvoked', 'layerDActivated',
                'hostDiscoveryRealHostCommandsInvoked', 'realHostInspectionEnabled'
            )) {
            $report.$flag | Should -BeFalse
        }
    }

    It 'rejects invalid state transitions to real-host inspection and provisioning' {
        { Assert-XboxOSHostDiscoveryTransactionTransition -From DiscoveryPlanned -To RealHostInspection } | Should -Throw
        { Assert-XboxOSHostDiscoveryTransactionTransition -From DiscoverySimulated -To LabProvisioning } | Should -Throw
        { Assert-XboxOSHostDiscoveryTransactionTransition -From HostDiscoveryBlocked -To WritableExecution } | Should -Throw
    }

    It 'evidence uses m6c namespace and JSON/Markdown agree' {
        $hostId = New-XboxOSHostIdentity -Fixture
        $scope = New-XboxOSHostDiscoveryScope
        $approval = New-XboxOSHostDiscoveryApprovalRecord `
            -OperatorId 'op' -HostIdentity $hostId -DiscoveryScope $scope `
            -GitCommitSha $script:GitSha -ApprovedCategories @($scope.categories) -ReadOnlyAcknowledged
        $report = Invoke-XboxOSHostLabDiscoverySimulate -Allowlist $script:Allowlist -HostIdentity $hostId -DiscoveryScope $scope `
            -Approval $approval -ExpectedGitCommitSha $script:GitSha
        $report.evidenceManifest.reportNamespace | Should -Be 'm6c'
        $report.evidenceManifest.preservesPriorBaselines | Should -BeTrue
        $report.evidenceManifest.sourceType | Should -Be 'FixtureDerived'
        $out = Join-Path $script:TempRoot 'reports'
        $paths = Save-XboxOSHostLabDiscoveryReport -Report $report -OutputDirectory $out -Stem 'XboxOS11-host-lab-discovery-m6c-test' -RepoRoot $script:RepoRoot
        $json = Get-Content -LiteralPath $paths.JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $md = Get-Content -LiteralPath $paths.MarkdownPath -Raw -Encoding UTF8
        $json.decision | Should -Be $report.decision
        $md | Should -Match ([regex]::Escape([string]$report.decision))
        $md | Should -Match 'ActualIsolationVerified|Actual isolation verified'
        { Save-XboxOSHostLabDiscoveryReport -Report $report -OutputDirectory $out -Stem 'XboxOS11-isolated-lab-m6b' -RepoRoot $script:RepoRoot } | Should -Throw
    }

    It 'CLI defaults blocked and refuses real-host bypass switches' {
        $cli = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts\Test-HostLabDiscovery.ps1') -Raw
        $cli | Should -Match 'HostDiscoveryBlocked'
        $cli | Should -Match 'AllowMockedApproval requires -Simulation'
        $cli | Should -Not -Match '(?i)-EnableRealHost|RealHostInspection\s*=\s*\$true|Get-VM\b'
        $cli | Should -Match 'exit 2'
    }

    It 'detects evidence substitution and source identity integrity on approval binding' {
        $hostId = New-XboxOSHostIdentity -Fixture
        $scope = New-XboxOSHostDiscoveryScope
        $approval = New-XboxOSHostDiscoveryApprovalRecord `
            -OperatorId 'op' -HostIdentity $hostId -DiscoveryScope $scope `
            -GitCommitSha $script:GitSha -ApprovedCategories @($scope.categories) -ReadOnlyAcknowledged
        $approval.bindingHash = ('0' * 64)
        $check = Test-XboxOSHostDiscoveryApprovalRecord -Record $approval -HostIdentity $hostId -DiscoveryScope $scope -ExpectedGitCommitSha $script:GitSha
        $check.valid | Should -BeFalse
        ($check.errors -join ' ') | Should -Match 'binding hash'

        $sub = Invoke-XboxOSHostLabDiscoverySimulate -Allowlist $script:Allowlist -ExpectedGitCommitSha $script:GitSha -InjectFailure EvidenceSubstitution
        $sub.decision | Should -Be 'RecoveryRequired'
    }
}
