#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'XboxOS11 Milestone 6D authorized host discovery (mocked)' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        Import-Module (Join-Path $repoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force
        $script:RepoRoot = $repoRoot.Path
        $script:Allowlist = Import-XboxOSHostDiscoveryAllowlistCatalog -Path (Join-Path $script:RepoRoot 'config\host-discovery-allowlist.json')
        $script:TempRoot = Join-Path $env:TEMP ('XboxOS11-m6d-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        $script:GitSha = 'fixture-git-sha-for-authorized-simulation'
        $script:Priv = Join-Path $script:RepoRoot 'tests\Fixtures\approval-auth\test-approval-private.pem'
        $script:Pub = Join-Path $script:RepoRoot 'tests\Fixtures\approval-auth\test-approval-public.pem'
        Initialize-XboxOSAuthorizedHostDiscoveryTestKeyFingerprints -RepoRoot $script:RepoRoot
        Reset-XboxOSAuthorizedHostDiscoveryNonceRegistry
        $script:NewM6dApproval = {
            param(
                [object]$HostIdentity,
                [object]$Scope,
                [string]$RunIdentity = $null
            )
            if (-not $RunIdentity) { $RunIdentity = ('run-' + [guid]::NewGuid().ToString('N')) }
            return New-XboxOSAuthorizedHostDiscoveryApprovalRecord `
                -OperatorId 'lab-operator' `
                -HostIdentity $HostIdentity `
                -DiscoveryScope $Scope `
                -GitCommitSha $script:GitSha `
                -ApprovedCategories @($Scope.categories) `
                -RunIdentity $RunIdentity `
                -PrivateKeyPemPath $script:Priv `
                -PublicKeyPemPath $script:Pub `
                -ReadOnlyAcknowledged `
                -AllowTestKeyForSimulationOnly
        }

        Reset-XboxOSHostDiscoveryNonceRegistry
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        Reset-XboxOSAuthorizedHostDiscoveryNonceRegistry
        Reset-XboxOSHostDiscoveryNonceRegistry
    }

    BeforeEach {
        Reset-XboxOSAuthorizedHostDiscoveryNonceRegistry
        Reset-XboxOSHostDiscoveryNonceRegistry
    }

    It 'reports Milestone 6D engine versions and inactive live activation' {
        Get-XboxOSAuthorizedHostDiscoveryEngineVersion | Should -Be '6.3.0-d'
        Get-XboxOSAuthorizedHostDiscoveryApprovalSchemaVersion | Should -Be 'host-discovery-real-approval-v1'
        Get-XboxOSAuthorizedHostDiscoveryLiveActivationEnabled | Should -BeFalse
        Get-XboxOSHostDiscoveryRealHostCommandsInvoked | Should -BeFalse
        Get-XboxOSLabRealProvisioningEnabled | Should -BeFalse
        Get-XboxOSRealDismExecutionEnabled | Should -BeFalse
        Get-XboxOSExperimentalExecutionAuthorized | Should -BeFalse
    }

    It 'defaults to HostDiscoveryBlocked without authorized approval' {
        $report = Invoke-XboxOSAuthorizedHostDiscoverySimulate -Allowlist $script:Allowlist -RepoRoot $script:RepoRoot -ExpectedGitCommitSha $script:GitSha
        $report.decision | Should -Be 'HostDiscoveryBlocked'
        $report.approvalValid | Should -BeFalse
        $report.reportNamespace | Should -Be 'm6d'
        $report.liveHostInspectionActivated | Should -BeFalse
        $report.hostDiscoveryRealHostCommandsInvoked | Should -BeFalse
    }

    It 'rejects M6C mock approvals for real-host discovery' {
        $hostId = New-XboxOSHostIdentity -Fixture
        $m6cScope = New-XboxOSHostDiscoveryScope
        $m6c = New-XboxOSHostDiscoveryApprovalRecord `
            -OperatorId 'op' -HostIdentity $hostId -DiscoveryScope $m6cScope `
            -GitCommitSha $script:GitSha -ApprovedCategories @($m6cScope.categories) -ReadOnlyAcknowledged
        $scope = New-XboxOSHostDiscoveryScopeForRealHost
        $check = Test-XboxOSAuthorizedHostDiscoveryApprovalRecord `
            -Record $m6c -HostIdentity $hostId -DiscoveryScope $scope `
            -ExpectedGitCommitSha $script:GitSha -PublicKeyPemPath $script:Pub
        $check.valid | Should -BeFalse
        ($check.errors -join ' ') | Should -Match 'HostDiscoveryReal|m6c|never valid|invalid'

        $report = Invoke-XboxOSAuthorizedHostDiscoverySimulate -Allowlist $script:Allowlist -HostIdentity $hostId `
            -DiscoveryScope $scope -Approval $m6c -ExpectedGitCommitSha $script:GitSha `
            -PublicKeyPemPath $script:Pub -InjectFailure M6cMockApproval
        $report.decision | Should -Be 'RecoveryRequired'
        ($report.blockers -join ' ') | Should -Match 'M6C|never valid'
    }

    It 'rejects expired, replayed, wrong-host, wrong-git, dirty tree, and test-key trusted path' {
        $hostId = New-XboxOSHostIdentity -Fixture -HostLabel 'auth-host'
        $scope = New-XboxOSHostDiscoveryScopeForRealHost
        $approval = & $script:NewM6dApproval -HostIdentity $hostId -Scope $scope

        foreach ($kind in @('ExpiredApproval', 'ReplayNonce', 'ReplayRunIdentity', 'WrongHost', 'WrongGitSha', 'DirtyWorkingTree', 'TestKeySubstitution', 'InvalidSignature', 'UnauthorizedScope')) {
            Reset-XboxOSAuthorizedHostDiscoveryNonceRegistry
            $a = & $script:NewM6dApproval -HostIdentity $hostId -Scope $scope
            $r = Invoke-XboxOSAuthorizedHostDiscoverySimulate -Allowlist $script:Allowlist -HostIdentity $hostId `
                -DiscoveryScope $scope -Approval $a -ExpectedGitCommitSha $script:GitSha `
                -PublicKeyPemPath $script:Pub -AllowSimulationTestKey -InjectFailure $kind
            $r.decision | Should -Be 'RecoveryRequired'
            $r.approvalValid | Should -BeFalse
            $r.liveHostInspectionActivated | Should -BeFalse
        }
    }

    It 'rejects test keys when trusted lab identity is required' {
        $hostId = New-XboxOSHostIdentity -Fixture
        $scope = New-XboxOSHostDiscoveryScopeForRealHost
        { New-XboxOSAuthorizedHostDiscoveryApprovalRecord `
                -OperatorId 'op' -HostIdentity $hostId -DiscoveryScope $scope `
                -GitCommitSha $script:GitSha -ApprovedCategories @($scope.categories) `
                -RunIdentity ('run-' + [guid]::NewGuid().ToString('N')) `
                -PrivateKeyPemPath $script:Priv -PublicKeyPemPath $script:Pub `
                -ReadOnlyAcknowledged } | Should -Throw -ExpectedMessage '*Test signing keys*'
    }

    It 'blocks RealHostReadOnly adapter execution while live activation is False' {
        $adapter = New-XboxOSAuthorizedHostDiscoveryAdapter -Allowlist $script:Allowlist -Mode RealHostReadOnly
        $adapter.mode | Should -Be 'RealHostReadOnly'
        { Invoke-XboxOSAuthorizedHostDiscoveryAdapterOperation -Adapter $adapter -OperationId 'Get-OsInfo' } | Should -Throw -ExpectedMessage '*live activation*'
        Get-XboxOSHostDiscoveryRealHostCommandsInvoked | Should -BeFalse
    }

    It 'rejects mutation operations and arbitrary parameters' {
        $deny = Test-XboxOSHostDiscoveryOperationSpec -Allowlist $script:Allowlist -OperationId 'New-VM'
        $deny.allowed | Should -BeFalse
        $paramDeny = Test-XboxOSHostDiscoveryOperationSpec -Allowlist $script:Allowlist -OperationId 'Get-OsInfo' -Parameters @{ Extra = 1 }
        $paramDeny.allowed | Should -BeFalse
        $shellDeny = Test-XboxOSHostDiscoveryOperationSpec -Allowlist $script:Allowlist -OperationId 'Get-OsInfo' -RawCommand 'Get-OsInfo; Invoke-Expression "evil"'
        $shellDeny.allowed | Should -BeFalse
    }

    It 'represents missing Hyper-V module as Unavailable without inventing empty inventories' {
        $hostId = New-XboxOSHostIdentity -Fixture
        $scope = New-XboxOSHostDiscoveryScopeForRealHost
        $approval = & $script:NewM6dApproval -HostIdentity $hostId -Scope $scope
        $report = Invoke-XboxOSAuthorizedHostDiscoverySimulate -Allowlist $script:Allowlist -HostIdentity $hostId `
            -DiscoveryScope $scope -Approval $approval -ExpectedGitCommitSha $script:GitSha `
            -PublicKeyPemPath $script:Pub -AllowSimulationTestKey -InjectFailure MissingHyperVModule
        $report.vmInventory.availability | Should -Be 'Unavailable'
        $report.switchInventory.availability | Should -Be 'Unavailable'
        ($report.vmInventory.notes -join ' ') | Should -Match 'Unavailable|empty'
    }

    It 'treats insufficient permissions as Unverified and never elevates' {
        $hostId = New-XboxOSHostIdentity -Fixture
        $scope = New-XboxOSHostDiscoveryScopeForRealHost
        $approval = & $script:NewM6dApproval -HostIdentity $hostId -Scope $scope
        $report = Invoke-XboxOSAuthorizedHostDiscoverySimulate -Allowlist $script:Allowlist -HostIdentity $hostId `
            -DiscoveryScope $scope -Approval $approval -ExpectedGitCommitSha $script:GitSha `
            -PublicKeyPemPath $script:Pub -AllowSimulationTestKey -InjectFailure InsufficientPermissions
        $os = @($report.operationResults | Where-Object operationId -eq 'Get-OsInfo' | Select-Object -First 1)
        $os.status | Should -Be 'Unverified'
        ($os.reason -join ' ') | Should -Match 'elevation|permissions|Insufficient'
        $report.hostDiscoveryRealHostCommandsInvoked | Should -BeFalse
    }

    It 'fails closed on unexpected command failure and write-operation attempts' {
        $hostId = New-XboxOSHostIdentity -Fixture
        $scope = New-XboxOSHostDiscoveryScopeForRealHost
        foreach ($kind in @('UnexpectedCommandFailure', 'WriteOperationAttempt')) {
            Reset-XboxOSAuthorizedHostDiscoveryNonceRegistry
            $approval = & $script:NewM6dApproval -HostIdentity $hostId -Scope $scope
            $report = Invoke-XboxOSAuthorizedHostDiscoverySimulate -Allowlist $script:Allowlist -HostIdentity $hostId `
                -DiscoveryScope $scope -Approval $approval -ExpectedGitCommitSha $script:GitSha `
                -PublicKeyPemPath $script:Pub -AllowSimulationTestKey -InjectFailure $kind
            $report.decision | Should -Be 'RecoveryRequired'
            $report.labRealProvisioningEnabled | Should -BeFalse
            $report.layerDActivated | Should -BeFalse
        }
    }

    It 'does not verify isolation from IsolatedSwitch name; flags spoofing and production bridges' {
        $byName = Test-XboxOSHostDiscoveryIsolationObservations -ProposedSwitchName 'IsolatedSwitch' `
            -SwitchInventoryAvailability Unavailable -ObservationSource MockFixture
        $byName.actualIsolationVerified | Should -BeFalse

        $hostId = New-XboxOSHostIdentity -Fixture
        $scope = New-XboxOSHostDiscoveryScopeForRealHost
        $approval = & $script:NewM6dApproval -HostIdentity $hostId -Scope $scope
        $spoof = Invoke-XboxOSAuthorizedHostDiscoverySimulate -Allowlist $script:Allowlist -HostIdentity $hostId `
            -DiscoveryScope $scope -Approval $approval -ExpectedGitCommitSha $script:GitSha `
            -PublicKeyPemPath $script:Pub -AllowSimulationTestKey -InjectFailure SwitchNameSpoofing
        $spoof.isolation.actualIsolationVerified | Should -BeFalse
        ($spoof.isolation.criteria | Where-Object id -eq 'switch-type').state | Should -Be 'Unsafe'

        Reset-XboxOSAuthorizedHostDiscoveryNonceRegistry
        $approval2 = & $script:NewM6dApproval -HostIdentity $hostId -Scope $scope
        $bridge = Invoke-XboxOSAuthorizedHostDiscoverySimulate -Allowlist $script:Allowlist -HostIdentity $hostId `
            -DiscoveryScope $scope -Approval $approval2 -ExpectedGitCommitSha $script:GitSha `
            -PublicKeyPemPath $script:Pub -AllowSimulationTestKey -InjectFailure ProductionBridge
        ($bridge.isolation.criteria | Where-Object id -eq 'production-bridge').state | Should -Be 'Unsafe'
        $bridge.isolation.networkIsolationVerificationStatus | Should -Be 'NetworkIsolationNotVerified'
    }

    It 'applies redaction and fails closed on redaction failures' {
        $red = Protect-XboxOSHostDiscoverySensitiveValue -Value 'PROD-HOST-01' -Kind Hostname
        $red.redacted | Should -Not -Be 'PROD-HOST-01'
        $red.pseudonym | Should -Match 'hostname-'

        $hostId = New-XboxOSHostIdentity -Fixture -HostLabel 'sensitive-host'
        $scope = New-XboxOSHostDiscoveryScopeForRealHost
        $approval = & $script:NewM6dApproval -HostIdentity $hostId -Scope $scope
        $ok = Invoke-XboxOSAuthorizedHostDiscoverySimulate -Allowlist $script:Allowlist -HostIdentity $hostId `
            -DiscoveryScope $scope -Approval $approval -ExpectedGitCommitSha $script:GitSha `
            -PublicKeyPemPath $script:Pub -AllowSimulationTestKey
        $ok.redactedInventory.redactionStatus | Should -Be 'Applied'
        $ok.evidenceManifest.reportNamespace | Should -Be 'm6d'

        Reset-XboxOSAuthorizedHostDiscoveryNonceRegistry
        $approval2 = & $script:NewM6dApproval -HostIdentity $hostId -Scope $scope
        $fail = Invoke-XboxOSAuthorizedHostDiscoverySimulate -Allowlist $script:Allowlist -HostIdentity $hostId `
            -DiscoveryScope $scope -Approval $approval2 -ExpectedGitCommitSha $script:GitSha `
            -PublicKeyPemPath $script:Pub -AllowSimulationTestKey -InjectFailure RedactionFailure
        $fail.decision | Should -Be 'RecoveryRequired'
        ($fail.blockers -join ' ') | Should -Match 'redaction'
    }

    It 'blocks unreachable live/provisioning/writable transaction states' {
        { Assert-XboxOSAuthorizedHostDiscoveryTransactionTransition -From ApprovalRequired -To LiveHostInspection } | Should -Throw
        { Assert-XboxOSAuthorizedHostDiscoveryTransactionTransition -From ApprovalRequired -To LabProvisioning } | Should -Throw
        { Assert-XboxOSAuthorizedHostDiscoveryTransactionTransition -From ApprovalRequired -To WritableExecution } | Should -Throw
    }

    It 'saves m6d reports without overwriting m6c baselines' {
        $report = Invoke-XboxOSAuthorizedHostDiscoverySimulate -Allowlist $script:Allowlist -RepoRoot $script:RepoRoot -ExpectedGitCommitSha $script:GitSha
        $saved = Save-XboxOSAuthorizedHostDiscoveryReport -Report $report -OutputDirectory $script:TempRoot -RepoRoot $script:RepoRoot
        Test-Path -LiteralPath $saved.JsonPath | Should -BeTrue
        { Save-XboxOSAuthorizedHostDiscoveryReport -Report $report -OutputDirectory $script:TempRoot -Stem 'XboxOS11-host-lab-discovery-m6c' } | Should -Throw
        { Save-XboxOSAuthorizedHostDiscoveryReport -Report $report -OutputDirectory $script:TempRoot -Stem 'XboxOS11-isolated-lab-m6b' } | Should -Throw
    }

    It 'CLI default remains HostDiscoveryBlocked and does not enable live inspection' {
        $cli = Join-Path $script:RepoRoot 'scripts\Test-AuthorizedHostDiscovery.ps1'
        Test-Path -LiteralPath $cli | Should -BeTrue
        $text = Get-Content -LiteralPath $cli -Raw
        $text | Should -Match 'HostDiscoveryBlocked'
        $text | Should -Not -Match 'EnableLiveHostInspection\s*=\s*\$true'
        $text | Should -Not -Match 'Get-VM\s'
        $outDir = Join-Path $script:TempRoot 'cli-out'
        & pwsh -NoProfile -File $cli -OutputDirectory $outDir -RepoRoot $script:RepoRoot
        $LASTEXITCODE | Should -Be 2
    }

    It 'keeps all mutation and provisioning flags False on authorized mock success path' {
        $hostId = New-XboxOSHostIdentity -Fixture
        $scope = New-XboxOSHostDiscoveryScopeForRealHost
        $approval = & $script:NewM6dApproval -HostIdentity $hostId -Scope $scope
        $report = Invoke-XboxOSAuthorizedHostDiscoverySimulate -Allowlist $script:Allowlist -HostIdentity $hostId `
            -DiscoveryScope $scope -Approval $approval -ExpectedGitCommitSha $script:GitSha `
            -PublicKeyPemPath $script:Pub -AllowSimulationTestKey
        $report.decision | Should -Be 'HostDiscoveryBlocked'
        $report.approvalValid | Should -BeTrue
        $report.adapterMode | Should -Be 'AuthorizedMockReadOnly'
        $report.isolation.actualIsolationVerified | Should -BeFalse
        foreach ($flag in @(
                'realDismExecutionEnabled', 'modifyingCommandsInvoked', 'executionAuthorized', 'servicingAuthorized',
                'experimentalMutationEnabled', 'experimentalExecutionAuthorized',
                'labRealProvisioningEnabled', 'labHypervisorCommandsInvoked', 'layerDActivated',
                'hostDiscoveryRealHostCommandsInvoked', 'realHostInspectionEnabled', 'liveHostInspectionActivated'
            )) {
            $report.$flag | Should -BeFalse
        }
    }
}
