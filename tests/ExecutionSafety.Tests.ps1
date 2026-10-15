#Requires -Modules Pester
Describe 'XboxOS11 Milestone 3 execution safety' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        Import-Module (Join-Path $script:RepoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force
        $script:TempRoot = Join-Path $env:TEMP ("XboxOS11-m3-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

        $script:Fixtures = Join-Path $script:RepoRoot 'tests\Fixtures'
        $script:RemoveApps = Import-XboxOSManifest -Path (Join-Path $script:RepoRoot 'config\remove-apps.json')
        $script:DisableFeatures = Import-XboxOSManifest -Path (Join-Path $script:RepoRoot 'config\disable-features.json')
        $script:Compatibility = Import-XboxOSManifest -Path (Join-Path $script:RepoRoot 'config\compatibility.json')

        $appx = @(ConvertFrom-XboxOSDismProvisionedAppxListOutput -Output (Get-Content (Join-Path $script:Fixtures 'dism-get-appx-26300.9457.txt')) | ForEach-Object { $_.PackageName })
        $features = @(ConvertFrom-XboxOSDismFeatureListOutput -Output (Get-Content (Join-Path $script:Fixtures 'dism-get-features-26300.9457.txt')))
        $script:Inventory = New-XboxOSInventorySnapshot `
            -AppxAvailability Available `
            -FeatureAvailability Available `
            -AppxPackages $appx `
            -Features $features `
            -Source 'tests/Fixtures/dism-get-*-26300.9457.txt' `
            -VerificationStatus Authoritative `
            -SourceImage ([pscustomobject]@{
                editionName    = 'Windows 11 Pro'
                sourceIndex    = 6
                buildNumber    = '26300.9457'
                displayVersion = '26H2'
                isoSha256      = 'ABCDEF0123456789'
            })

        $script:Plan = New-XboxOSServicingPlan `
            -Inventory $script:Inventory `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility

        $script:EligibleIds = @($script:Plan.operations | Where-Object status -eq 'Eligible' | ForEach-Object { $_.operationId })
        $script:VerifiedEvidence = @(
            $script:Plan.operations |
                Where-Object status -eq 'Eligible' |
                ForEach-Object {
                    [pscustomobject]@{
                        operationId    = $_.operationId
                        targetIdentity = $_.targetIdentity
                        outcome        = 'Verified'
                        evidenceHash   = Get-XboxOSUtf8Sha256Hex -Text ("dep:{0}" -f $_.operationId)
                    }
                }
        )
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports safety engine 3.0.0 and keeps real DISM disabled' {
        Get-XboxOSExecutionSafetyEngineVersion | Should -Be '3.0.0'
        Get-XboxOSApprovalSchemaVersion | Should -Be 'approval-v1'
        Get-XboxOSRealDismExecutionEnabled | Should -BeFalse
    }

    It 'does not treat PendingOperatorApproval as an approval record' {
        $script:Plan.approvalGate | Should -Be 'PendingOperatorApproval'
        $script:Plan.executionAuthorized | Should -BeFalse
        $tx = New-XboxOSServicingTransaction -Plan $script:Plan -FreshInventory $script:Inventory -DependencyEvidence $script:VerifiedEvidence -CompatibilityManifest $script:Compatibility
        $tx = Invoke-XboxOSTransactionPreflight -Transaction $tx
        $tx.state | Should -Be 'AwaitingApproval'
        $tx.executionAuthorized | Should -BeFalse
        $tx.simulatedAuthorizationResult | Should -Be 'NotEvaluated'
    }

    It 'binds approval to contentHash and invalidates on plan drift' {
        $approval = New-XboxOSApprovalRecord `
            -Plan $script:Plan `
            -ApprovedOperationIds $script:EligibleIds `
            -OperatorId 'ops-1' `
            -Scope simulation
        $ok = Test-XboxOSApprovalValidity -Approval $approval -Plan $script:Plan
        $ok.validForSimulation | Should -BeTrue
        $ok.grantsRealDismExecution | Should -BeFalse

        $otherInventory = New-XboxOSInventorySnapshot `
            -AppxAvailability Available `
            -FeatureAvailability Available `
            -AppxPackages @($script:Inventory.appxPackages + 'Contoso.Extra_1.0.0.0_neutral_~_abcdefghijklm') `
            -Features $script:Inventory.features `
            -VerificationStatus Authoritative `
            -SourceImage $script:Inventory.sourceImage
        $otherPlan = New-XboxOSServicingPlan `
            -Inventory $otherInventory `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        $reuse = Test-XboxOSApprovalValidity -Approval $approval -Plan $otherPlan
        $reuse.validForSimulation | Should -BeFalse
        $reuse.effectiveState | Should -Be 'Invalidated'
    }

    It 'expires and revokes approvals' {
        $approval = New-XboxOSApprovalRecord `
            -Plan $script:Plan `
            -ApprovedOperationIds $script:EligibleIds `
            -OperatorId 'ops-1' `
            -ApprovedUtc ([datetime]::UtcNow.AddHours(-2)) `
            -ExpiresUtc ([datetime]::UtcNow.AddHours(-1))
        $expired = Test-XboxOSApprovalValidity -Approval $approval -Plan $script:Plan
        $expired.effectiveState | Should -Be 'Expired'
        $expired.validForSimulation | Should -BeFalse

        $live = New-XboxOSApprovalRecord -Plan $script:Plan -ApprovedOperationIds $script:EligibleIds -OperatorId 'ops-1'
        $null = Set-XboxOSApprovalState -Approval $live -State Revoked -Reason 'operator revoked'
        $rev = Test-XboxOSApprovalValidity -Approval $live -Plan $script:Plan
        $rev.effectiveState | Should -Be 'Revoked'
        $rev.validForSimulation | Should -BeFalse
    }

    It 'invalidates tampered bindingHash and forged real-DISM approval flags' {
        $approval = New-XboxOSApprovalRecord -Plan $script:Plan -ApprovedOperationIds $script:EligibleIds -OperatorId 'ops-1'
        $approval.bindingHash = '0' * 64
        $tampered = Test-XboxOSApprovalValidity -Approval $approval -Plan $script:Plan
        $tampered.validForSimulation | Should -BeFalse
        $tampered.effectiveState | Should -Be 'Invalidated'
        $tampered.cryptographicallyAuthenticated | Should -BeFalse

        $forged = New-XboxOSApprovalRecord -Plan $script:Plan -ApprovedOperationIds $script:EligibleIds -OperatorId 'ops-1'
        $forged.grantsRealDismExecution = $true
        $forged.realDismExecutionEnabled = $true
        $denied = Test-XboxOSApprovalValidity -Approval $forged -Plan $script:Plan
        $denied.validForSimulation | Should -BeFalse
        $denied.grantsRealDismExecution | Should -BeFalse
        { Assert-XboxOSExecutionSafetyInvariants -Approval $forged } | Should -Throw -ExpectedMessage '*grantsRealDismExecution*'
    }

    It 'fails closed on missing approval binding fields' {
        $approval = New-XboxOSApprovalRecord -Plan $script:Plan -ApprovedOperationIds $script:EligibleIds -OperatorId 'ops-1'
        $approval.binding.contentHash = ''
        $bad = Test-XboxOSApprovalValidity -Approval $approval -Plan $script:Plan
        $bad.validForSimulation | Should -BeFalse
        ($bad.errors -join ' ') | Should -Match 'contentHash'

        $noBind = [pscustomobject]@{
            state                 = 'Approved'
            approvalSchemaVersion = 'approval-v1'
            bindingHash           = 'abc'
            grantsRealDismExecution = $false
            realDismExecutionEnabled = $false
        }
        $missing = Test-XboxOSApprovalValidity -Approval $noBind -Plan $script:Plan
        $missing.effectiveState | Should -Be 'Invalidated'
    }

    It 'rejects simulated approval as real execution permission' {
        $approval = New-XboxOSApprovalRecord -Plan $script:Plan -ApprovedOperationIds $script:EligibleIds -OperatorId 'ops-1'
        $approval.grantsRealDismExecution | Should -BeFalse
        $approval.cryptographicallyAuthenticated | Should -BeFalse
        $tx = New-XboxOSServicingTransaction `
            -Plan $script:Plan `
            -FreshInventory $script:Inventory `
            -CompatibilityManifest $script:Compatibility `
            -DependencyEvidence $script:VerifiedEvidence `
            -Backend (New-XboxOSMockServicingBackend)
        $tx = Invoke-XboxOSTransactionPreflight -Transaction $tx
        $tx = Invoke-XboxOSTransactionApplyApproval -Transaction $tx -Approval $approval
        $tx.simulatedAuthorizationResult | Should -Be 'SimulatedApprovedForPreparation'
        $tx.executionAuthorized | Should -BeFalse
        Get-XboxOSRealDismExecutionEnabled | Should -BeFalse
    }

    It 'detects inventory fingerprint drift and fail-closes' {
        $drifted = New-XboxOSInventorySnapshot `
            -AppxAvailability Available `
            -FeatureAvailability Available `
            -AppxPackages @('Only.One_1.0.0.0_neutral_~_abcdefghijklm') `
            -Features @([pscustomobject]@{ Name = 'WorkFolders-Client'; State = 'Disabled' }) `
            -VerificationStatus Authoritative `
            -SourceImage $script:Inventory.sourceImage
        $result = Test-XboxOSInventoryDrift -Plan $script:Plan -FreshInventory $drifted -CompatibilityManifest $script:Compatibility
        $result.result | Should -Be 'DriftDetected'
        $result.failClosed | Should -BeTrue
    }

    It 'detects manifest fingerprint changes via new plan inequality' {
        $json = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'config\remove-apps.json') -Raw | ConvertFrom-Json
        $json.candidates = @($json.candidates | Select-Object -First 1)
        $alteredPath = Join-Path $script:TempRoot 'remove-apps-altered.json'
        ($json | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $alteredPath -Encoding UTF8
        $alteredRemove = Import-XboxOSManifest -Path $alteredPath
        $p2 = New-XboxOSServicingPlan `
            -Inventory $script:Inventory `
            -RemoveAppsManifest $alteredRemove `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        $script:Plan.manifestFingerprints.removeApps | Should -Not -Be $p2.manifestFingerprints.removeApps
        $approval = New-XboxOSApprovalRecord -Plan $script:Plan -ApprovedOperationIds $script:EligibleIds -OperatorId 'ops-1'
        $check = Test-XboxOSApprovalValidity -Approval $approval -Plan $p2
        $check.validForSimulation | Should -BeFalse
    }

    It 'blocks unknown dependencies and rejects approval override' {
        $deps = Test-XboxOSDependencySafety -Plan $script:Plan -DependencyEvidence @()
        $deps.aggregateOutcome | Should -Be 'Unknown'
        $deps.failClosed | Should -BeTrue
        $deps.approvalCannotOverride | Should -BeTrue
        $blocked = Test-XboxOSDependencySafety -Plan $script:Plan -DependencyEvidence $script:VerifiedEvidence -AllowApprovalOverride
        $blocked.errors.Count | Should -BeGreaterThan 0
        $blocked.failClosed | Should -BeTrue
    }

    It 'accepts verified dependency evidence' {
        $deps = Test-XboxOSDependencySafety -Plan $script:Plan -DependencyEvidence $script:VerifiedEvidence
        $deps.aggregateOutcome | Should -Be 'Verified'
        $deps.failClosed | Should -BeFalse
    }

    It 'rejects protected targets during drift evaluation' {
        $badPlan = [pscustomobject]@{
            contentHash           = $script:Plan.contentHash
            hashSchemaVersion     = $script:Plan.hashSchemaVersion
            engineVersion         = $script:Plan.engineVersion
            inventoryFingerprint  = $script:Plan.inventoryFingerprint
            sourceImage           = $script:Plan.sourceImage
            manifestFingerprints  = $script:Plan.manifestFingerprints
            operations            = @(
                [pscustomobject]@{
                    operationId    = 'evil'
                    operationType  = 'RemoveProvisionedAppx'
                    targetKind     = 'AppX'
                    targetIdentity = 'Microsoft.Xbox.TCUI_1.0.0.0_neutral_~_8wekyb3d8bbwe'
                    status         = 'Eligible'
                    currentState   = 'Present'
                }
            )
        }
        $result = Test-XboxOSInventoryDrift -Plan $badPlan -FreshInventory $script:Inventory -CompatibilityManifest $script:Compatibility
        $result.result | Should -Be 'ProtectedTarget'
        $result.failClosed | Should -BeTrue
    }

    It 'rejects invalid transaction transitions' {
        $tx = New-XboxOSServicingTransaction -Plan $script:Plan -FreshInventory $script:Inventory
        {
            Set-XboxOSTransactionState -Transaction $tx -State Completed
        } | Should -Throw -ExpectedMessage '*Invalid transaction transition*'
    }

    It 'runs simulated happy-path transaction without real DISM' {
        $backend = New-XboxOSMockServicingBackend -FailureMode Success
        $tx = New-XboxOSServicingTransaction `
            -Plan $script:Plan `
            -FreshInventory $script:Inventory `
            -CompatibilityManifest $script:Compatibility `
            -DependencyEvidence $script:VerifiedEvidence `
            -Backend $backend
        $tx = Invoke-XboxOSTransactionPreflight -Transaction $tx
        $approval = New-XboxOSApprovalRecord -Plan $script:Plan -ApprovedOperationIds $script:EligibleIds -OperatorId 'ops-1'
        $tx = Invoke-XboxOSTransactionApplyApproval -Transaction $tx -Approval $approval
        $tx.simulatedAuthorizationResult | Should -Be 'SimulatedApprovedForPreparation'
        $tx.executionAuthorized | Should -BeFalse
        $tx = Invoke-XboxOSTransactionSimulate -Transaction $tx
        $tx.state | Should -Be 'Completed'
        $tx.modifyingCommandsInvoked | Should -BeFalse
        Get-XboxOSRealDismExecutionEnabled | Should -BeFalse
        $backend.GetState().SourceIsoModified | Should -BeFalse
        $backend.GetState().ModifyingCommandsInvoked | Should -BeFalse
    }

    It 'recovers from simulated DISM failure without commit' {
        $backend = New-XboxOSMockServicingBackend -FailureMode DismFailure
        $tx = New-XboxOSServicingTransaction `
            -Plan $script:Plan `
            -FreshInventory $script:Inventory `
            -CompatibilityManifest $script:Compatibility `
            -DependencyEvidence $script:VerifiedEvidence `
            -Backend $backend
        $tx = Invoke-XboxOSTransactionPreflight -Transaction $tx
        $approval = New-XboxOSApprovalRecord -Plan $script:Plan -ApprovedOperationIds $script:EligibleIds -OperatorId 'ops-1'
        $tx = Invoke-XboxOSTransactionApplyApproval -Transaction $tx -Approval $approval
        $tx = Invoke-XboxOSTransactionSimulate -Transaction $tx
        $tx.state | Should -Be 'RecoveryRequired'
        $tx = Invoke-XboxOSTransactionRecover -Transaction $tx
        $tx.state | Should -Be 'Aborted'
        $tx.modifyingCommandsInvoked | Should -BeFalse
        ($tx.recoveryRecommendation -match 'Discard') | Should -BeTrue
    }

    It 'handles preparation interruption, verification failure, and commit rejection without Completed' {
        foreach ($mode in @('PreparationInterrupted', 'VerificationFailure', 'CommitRejected')) {
            $backend = New-XboxOSMockServicingBackend -FailureMode $mode
            $tx = New-XboxOSServicingTransaction `
                -Plan $script:Plan `
                -FreshInventory $script:Inventory `
                -CompatibilityManifest $script:Compatibility `
                -DependencyEvidence $script:VerifiedEvidence `
                -Backend $backend
            $tx = Invoke-XboxOSTransactionPreflight -Transaction $tx
            $approval = New-XboxOSApprovalRecord -Plan $script:Plan -ApprovedOperationIds $script:EligibleIds -OperatorId 'ops-1'
            $tx = Invoke-XboxOSTransactionApplyApproval -Transaction $tx -Approval $approval
            $tx = Invoke-XboxOSTransactionSimulate -Transaction $tx
            $tx.state | Should -Be 'RecoveryRequired'
            $tx.state | Should -Not -Be 'Completed'
            $tx.executionAuthorized | Should -BeFalse
            $tx.modifyingCommandsInvoked | Should -BeFalse
            $tx = Invoke-XboxOSTransactionRecover -Transaction $tx
            $tx.state | Should -Be 'Aborted'
            @($tx.audit | Where-Object type -eq 'StateTransition').Count | Should -BeGreaterThan 0
        }
    }

    It 'default unknown-dependency preflight never reaches Completed' {
        $tx = New-XboxOSServicingTransaction `
            -Plan $script:Plan `
            -FreshInventory $script:Inventory `
            -CompatibilityManifest $script:Compatibility `
            -DependencyEvidence @() `
            -Backend (New-XboxOSMockServicingBackend)
        $tx = Invoke-XboxOSTransactionPreflight -Transaction $tx
        $tx.state | Should -Be 'Failed'
        $tx.dependencyResult.aggregateOutcome | Should -Be 'Unknown'
        $tx.simulatedAuthorizationResult | Should -Be 'Denied'
        $tx.executionAuthorized | Should -BeFalse
    }

    It 'enforces hard safety invariants after simulated completion' {
        $backend = New-XboxOSMockServicingBackend
        $tx = New-XboxOSServicingTransaction `
            -Plan $script:Plan `
            -FreshInventory $script:Inventory `
            -CompatibilityManifest $script:Compatibility `
            -DependencyEvidence $script:VerifiedEvidence `
            -Backend $backend
        $tx = Invoke-XboxOSTransactionPreflight -Transaction $tx
        $approval = New-XboxOSApprovalRecord -Plan $script:Plan -ApprovedOperationIds $script:EligibleIds -OperatorId 'ops-1'
        $tx = Invoke-XboxOSTransactionApplyApproval -Transaction $tx -Approval $approval
        $tx = Invoke-XboxOSTransactionSimulate -Transaction $tx
        $tx.state | Should -Be 'Completed'
        Assert-XboxOSExecutionSafetyInvariants -Transaction $tx -Approval $approval
        $tx.executionAuthorized = $true
        { Assert-XboxOSExecutionSafetyInvariants -Transaction $tx } | Should -Throw -ExpectedMessage '*executionAuthorized*'
    }

    It 'handles approval expiration during apply' {
        $tx = New-XboxOSServicingTransaction `
            -Plan $script:Plan `
            -FreshInventory $script:Inventory `
            -DependencyEvidence $script:VerifiedEvidence `
            -CompatibilityManifest $script:Compatibility
        $tx = Invoke-XboxOSTransactionPreflight -Transaction $tx
        $approval = New-XboxOSApprovalRecord `
            -Plan $script:Plan `
            -ApprovedOperationIds $script:EligibleIds `
            -OperatorId 'ops-1' `
            -ApprovedUtc ([datetime]::UtcNow.AddDays(-2)) `
            -ExpiresUtc ([datetime]::UtcNow.AddDays(-1))
        $tx = Invoke-XboxOSTransactionApplyApproval -Transaction $tx -Approval $approval
        $tx.state | Should -Be 'Failed'
        $tx.executionAuthorized | Should -BeFalse
    }

    It 'handles interrupted unmount with retry discard' {
        $backend = New-XboxOSMockServicingBackend -FailureMode UnmountInterrupted
        $tx = New-XboxOSServicingTransaction `
            -Plan $script:Plan `
            -FreshInventory $script:Inventory `
            -CompatibilityManifest $script:Compatibility `
            -DependencyEvidence $script:VerifiedEvidence `
            -Backend $backend
        $tx = Invoke-XboxOSTransactionPreflight -Transaction $tx
        $approval = New-XboxOSApprovalRecord -Plan $script:Plan -ApprovedOperationIds $script:EligibleIds -OperatorId 'ops-1'
        $tx = Invoke-XboxOSTransactionApplyApproval -Transaction $tx -Approval $approval
        # Force release path: simulate to WorkingImageValidated then inject recovery
        $tx = Invoke-XboxOSTransactionSimulate -Transaction $tx -StopBeforeExecution
        Set-XboxOSTransactionState -Transaction $tx -State RecoveryRequired -Message 'forced recovery for unmount test'
        $tx = Invoke-XboxOSTransactionRecover -Transaction $tx
        $tx.state | Should -Be 'RecoveryRequired'
        $tx = Invoke-XboxOSTransactionRecover -Transaction $tx -RetryDiscard
        $tx.state | Should -Be 'Aborted'
        $tx.modifyingCommandsInvoked | Should -BeFalse
    }

    It 'writes JSON/Markdown safety reports that agree and deny real execution' {
        $backend = New-XboxOSMockServicingBackend
        $tx = New-XboxOSServicingTransaction `
            -Plan $script:Plan `
            -FreshInventory $script:Inventory `
            -CompatibilityManifest $script:Compatibility `
            -DependencyEvidence $script:VerifiedEvidence `
            -Backend $backend
        $tx = Invoke-XboxOSTransactionPreflight -Transaction $tx
        $approval = New-XboxOSApprovalRecord -Plan $script:Plan -ApprovedOperationIds $script:EligibleIds -OperatorId 'ops-1'
        $tx = Invoke-XboxOSTransactionApplyApproval -Transaction $tx -Approval $approval
        $tx = Invoke-XboxOSTransactionSimulate -Transaction $tx
        $paths = Save-XboxOSExecutionSafetyReport -Transaction $tx -OutputDirectory $script:TempRoot -Stem 'm3-unit'
        $json = Get-Content -LiteralPath $paths.Json -Raw | ConvertFrom-Json
        $md = Get-Content -LiteralPath $paths.Markdown -Raw
        $json.modifyingCommandsInvoked | Should -BeFalse
        $json.realDismExecutionEnabled | Should -BeFalse
        $json.executionAuthorized | Should -BeFalse
        $json.planContentHash | Should -Be $script:Plan.contentHash
        $md | Should -Match ([regex]::Escape($script:Plan.contentHash))
        $md | Should -Match 'Real DISM execution enabled: \*\*False\*\*'
        $md | Should -Match 'Modifying commands invoked: \*\*False\*\*'
    }

    It 'refuses OneDrive report output paths' {
        {
            $tx = New-XboxOSServicingTransaction -Plan $script:Plan -FreshInventory $script:Inventory
            Save-XboxOSExecutionSafetyReport -Transaction $tx -OutputDirectory 'C:\Users\ci\OneDrive\XboxOS11\artifacts' -Stem 'bad'
        } | Should -Throw -ExpectedMessage '*OneDrive*'
    }

    It 'Test-ExecutionSafety.ps1 is simulation-only' {
        $text = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts\Test-ExecutionSafety.ps1') -Raw
        $text | Should -Match 'Get-XboxOSRealDismExecutionEnabled'
        $text | Should -Not -Match '/Commit'
        $text | Should -Not -Match '/Remove-ProvisionedAppxPackage'
        $text | Should -Not -Match '/Disable-Feature'
    }

    It 'missing inventory evidence fails closed' {
        $result = Test-XboxOSInventoryDrift -Plan $script:Plan -FreshInventory ([pscustomobject]@{ inventoryFingerprint = ''; verificationStatus = 'Blocked' })
        $result.result | Should -Be 'MissingEvidence'
        $result.failClosed | Should -BeTrue
    }
}
