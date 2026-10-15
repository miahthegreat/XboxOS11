#Requires -Modules Pester
Describe 'XboxOS11 Milestone 4 disposable-image preflight' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        Import-Module (Join-Path $script:RepoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force
        $script:Fixtures = Join-Path $script:RepoRoot 'tests\Fixtures'
        $script:TempRoot = Join-Path $env:TEMP ('XboxOS11-m4-' + [guid]::NewGuid().ToString('N'))
        $script:WorkRoot = Join-Path $script:TempRoot 'Work'
        $script:LogsRoot = Join-Path $script:TempRoot 'Logs'
        New-Item -ItemType Directory -Path $script:WorkRoot, $script:LogsRoot -Force | Out-Null

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
            -Source 'tests/Fixtures' `
            -VerificationStatus Authoritative `
            -SourceImage ([pscustomobject]@{
                editionName    = 'Windows 11 Pro'
                sourceIndex    = 6
                buildNumber    = '26300.9457'
                displayVersion = '26H2'
                isoSha256      = (Get-XboxOSExpectedSourceIsoSha256)
            })

        $script:Plan = New-XboxOSServicingPlan `
            -Inventory $script:Inventory `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility

        $script:PubKey = Join-Path $script:Fixtures 'approval-auth\test-approval-public.pem'
        $script:PrivKey = Join-Path $script:Fixtures 'approval-auth\test-approval-private.pem'
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports preflight engine 4.0.0 and readonly-dism-v1' {
        Get-XboxOSPreflightEngineVersion | Should -Be '4.0.0'
        Get-XboxOSReadOnlyDismAdapterVersion | Should -Be 'readonly-dism-v1'
        Get-XboxOSRealDismExecutionEnabled | Should -BeFalse
    }

    It 'allowlists approved operations and rejects arbitrary/prohibited arguments' {
        $ok = Assert-XboxOSReadOnlyDismOperationAllowed -Operation GetFeatures -Parameters @{ MountDir = 'C:\XboxOS\Work\m\mount' }
        $ok.Class | Should -Be 'PureInspection'
        { Assert-XboxOSReadOnlyDismOperationAllowed -Operation RemoveAppx } | Should -Throw
        $scan = Test-XboxOSDismArgumentListAllowed -ArgumentList @('/English', '/Remove-ProvisionedAppxPackage', '/PackageName:x')
        $scan.Allowed | Should -BeFalse
        $mount = Test-XboxOSDismArgumentListAllowed -ArgumentList @('/English', '/Mount-Image', '/ImageFile:x.wim', '/Index:1', '/MountDir:C:\m')
        $mount.Allowed | Should -BeFalse
        $ro = Test-XboxOSDismArgumentListAllowed -ArgumentList @('/English', '/Mount-Image', '/ImageFile:x.wim', '/Index:1', '/MountDir:C:\m', '/ReadOnly')
        $ro.Allowed | Should -BeTrue
    }

    It 'fails closed on source hash mismatch and OneDrive paths' {
        $bad = Test-XboxOSSourceImagePrerequisites `
            -IsoPath (Join-Path $script:Fixtures 'dism-get-appx-26300.9457.txt') `
            -ExpectedSha256 ('0' * 64) `
            -WorkRoot $script:WorkRoot `
            -LogsRoot $script:LogsRoot `
            -RequireIsoPresent `
            -MinimumFreeBytes 1KB
        $bad.valid | Should -BeFalse
        ($bad.errors -join ' ') | Should -Match 'SHA256 mismatch'

        $od = Test-XboxOSSourceImagePrerequisites `
            -WorkRoot 'C:\Users\ci\OneDrive\Work' `
            -LogsRoot $script:LogsRoot `
            -RequireIsoPresent:$false `
            -MinimumFreeBytes 1KB
        $od.valid | Should -BeFalse
        ($od.errors -join ' ') | Should -Match 'OneDrive'
    }

    It 'fails closed on unrelated mounts and image-index ambiguity' {
        $mounts = Test-XboxOSSourceImagePrerequisites `
            -WorkRoot $script:WorkRoot `
            -LogsRoot $script:LogsRoot `
            -RequireIsoPresent:$false `
            -MinimumFreeBytes 1KB `
            -ExistingMounts @([pscustomobject]@{ MountDir = 'C:\OtherMount\Windows' })
        $mounts.valid | Should -BeFalse
        ($mounts.errors -join ' ') | Should -Match 'unrelated'

        $ambiguous = @(
            [pscustomobject]@{ Index = 5; Name = 'Windows 11 Pro' }
            [pscustomobject]@{ Index = 6; Name = 'Windows 11 Pro' }
        )
        { Resolve-XboxOSExactImageIndex -Images $ambiguous -ExactName 'Windows 11 Pro' } | Should -Throw -ExpectedMessage '*ambiguous*'
        { Resolve-XboxOSExactImageIndex -Images @([pscustomobject]@{ Index = 1; Name = 'Windows 11 Home' }) -ExactName 'Windows 11 Pro' } |
            Should -Throw -ExpectedMessage '*not found*'
    }

    It 'enforces disposable workspace ownership for cleanup' {
        $ws = New-XboxOSDisposableWorkspace -WorkRoot $script:WorkRoot -OwnerId 'owner-test'
        Assert-XboxOSDisposableWorkspaceOwnership -Workspace $ws -OwnershipToken $ws.ownershipToken -CandidateMountDir $ws.mountDir | Should -BeTrue
        { Assert-XboxOSDisposableWorkspaceOwnership -Workspace $ws -OwnershipToken 'bad' } | Should -Throw
        { Assert-XboxOSDisposableWorkspaceOwnership -Workspace $ws -OwnershipToken $ws.ownershipToken -CandidateMountDir 'C:\Other\mount' } |
            Should -Throw -ExpectedMessage '*outside owned workspace*'
    }

    It 'runs simulated successful read-only lifecycle with safety flags false' {
        $adapter = New-XboxOSMockReadOnlyDismAdapter -FixtureRoot $script:Fixtures
        $pf = New-XboxOSDisposableImagePreflight `
            -Plan $script:Plan `
            -BaselineInventory $script:Inventory `
            -CompatibilityManifest $script:Compatibility `
            -Adapter $adapter `
            -Mode Simulation `
            -WorkRoot $script:WorkRoot `
            -LogsRoot $script:LogsRoot `
            -IsoPath (Join-Path $script:TempRoot 'fake.iso')
        $pf = Invoke-XboxOSDisposableImagePreflightSimulate -Preflight $pf
        # Guard against accidental pipeline pollution
        @($pf).Count | Should -Be 1
        $pf.transactionState | Should -Be 'Completed'
        $pf.cleanupStatus | Should -Be 'Succeeded'
        $pf.mountOwned | Should -BeFalse
        $pf.modifyingCommandsInvoked | Should -BeFalse
        $pf.realDismExecutionEnabled | Should -BeFalse
        $pf.executionAuthorized | Should -BeFalse
        $pf.sourceIsoProtected | Should -BeTrue
        $pf.driftResult.result | Should -Be 'Match'
        # Eligible ops still have Unknown deps => decision Blocked (fail closed)
        $pf.preflightDecision | Should -Be 'Blocked'
        $adapter.Ctx.SourceIsoModified | Should -BeFalse
    }

    It 'detects inventory drift against a mismatched plan fingerprint' {
        $other = New-XboxOSInventorySnapshot `
            -AppxAvailability Available `
            -FeatureAvailability Available `
            -AppxPackages @('Contoso.Only_1.0.0.0_neutral_~_abcdefghijklm') `
            -Features @([pscustomobject]@{ Name = 'WorkFolders-Client'; State = 'Enabled' }) `
            -VerificationStatus Authoritative `
            -SourceImage $script:Inventory.sourceImage
        $otherPlan = New-XboxOSServicingPlan `
            -Inventory $other `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        $adapter = New-XboxOSMockReadOnlyDismAdapter -FixtureRoot $script:Fixtures
        $pf = New-XboxOSDisposableImagePreflight `
            -Plan $otherPlan `
            -BaselineInventory $other `
            -CompatibilityManifest $script:Compatibility `
            -Adapter $adapter `
            -Mode Simulation `
            -WorkRoot $script:WorkRoot `
            -LogsRoot $script:LogsRoot
        $pf = Invoke-XboxOSDisposableImagePreflightSimulate -Preflight $pf
        $pf.driftResult.failClosed | Should -BeTrue
        $pf.recomputedPlan | Should -Not -BeNullOrEmpty
        $pf.recomputedPlan.contentHash | Should -Not -Be $otherPlan.contentHash
    }

    It 'records dependency evidence gaps without claiming removal safety from missing protections' {
        $deps = Get-XboxOSDependencyCategoryEvidence -Inventory $script:Inventory -CompatibilityManifest $script:Compatibility
        $deps.approvalCannotOverride | Should -BeTrue
        @($deps.categories).Count | Should -BeGreaterThan 5
        ($deps.categories | Where-Object note -Match 'never proves removal safety').Count | Should -BeGreaterThan 0
    }

    It 'signs and verifies approval auth payloads with test keys without authorizing DISM' {
        $eligible = @($script:Plan.operations | Where-Object status -eq 'Eligible' | Select-Object -First 1 -ExpandProperty operationId)
        $approval = New-XboxOSApprovalRecord -Plan $script:Plan -ApprovedOperationIds $eligible -OperatorId 'ops-m4'
        $payload = New-XboxOSApprovalSigningPayload -ApprovalBindingDocument $approval.binding -Nonce 'nonce-1'
        $sig = New-XboxOSApprovalSignature -CanonicalPayload $payload -PrivateKeyPemPath $script:PrivKey
        $verify = Test-XboxOSApprovalSignature -CanonicalPayload $payload -SignatureBase64 $sig -PublicKeyPemPath $script:PubKey
        $verify.signatureValid | Should -BeTrue
        $verify.executionAuthorized | Should -BeFalse
        $verify.realDismExecutionEnabled | Should -BeFalse
        $verify.grantsRealDismExecution | Should -BeFalse

        $bad = Test-XboxOSApprovalSignature -CanonicalPayload ($payload + 'x') -SignatureBase64 $sig -PublicKeyPemPath $script:PubKey
        $bad.signatureValid | Should -BeFalse
    }

    It 'handles export/mount/unmount failure injection with scoped recovery' {
        foreach ($mode in @('ExportInterrupted', 'MountFailed', 'UnmountFailed', 'CorruptWim')) {
            $adapter = New-XboxOSMockReadOnlyDismAdapter -FailureMode $mode -FixtureRoot $script:Fixtures
            $pf = New-XboxOSDisposableImagePreflight `
                -Plan $script:Plan `
                -CompatibilityManifest $script:Compatibility `
                -Adapter $adapter `
                -Mode Simulation `
                -WorkRoot $script:WorkRoot `
                -LogsRoot $script:LogsRoot
            $pf = Invoke-XboxOSDisposableImagePreflightSimulate -Preflight $pf
            $pf.transactionState | Should -BeIn @('Aborted', 'Failed', 'RecoveryRequired')
            $pf.transactionState | Should -Not -Be 'Completed'
            $pf.modifyingCommandsInvoked | Should -BeFalse
            $pf.executionAuthorized | Should -BeFalse
        }
    }

    It 'gates live read-only mode until explicit authorization' {
        { Assert-XboxOSLiveReadOnlyPreflightAuthorization } | Should -Throw -ExpectedMessage '*ConfirmLiveReadOnlyPreflight*'
        {
            Assert-XboxOSLiveReadOnlyPreflightAuthorization -ConfirmLiveReadOnlyPreflight
        } | Should -Throw -ExpectedMessage '*AllowLiveReadOnlyPreflight*'
        {
            Assert-XboxOSLiveReadOnlyPreflightAuthorization -ConfirmLiveReadOnlyPreflight -AllowLiveReadOnlyPreflight
        } | Should -Not -Throw
    }

    It 'writes JSON/Markdown reports that agree on safety flags' {
        $adapter = New-XboxOSMockReadOnlyDismAdapter -FixtureRoot $script:Fixtures
        $pf = New-XboxOSDisposableImagePreflight `
            -Plan $script:Plan `
            -BaselineInventory $script:Inventory `
            -CompatibilityManifest $script:Compatibility `
            -Adapter $adapter `
            -Mode Simulation `
            -WorkRoot $script:WorkRoot `
            -LogsRoot $script:LogsRoot
        $pf = Invoke-XboxOSDisposableImagePreflightSimulate -Preflight $pf
        $paths = Save-XboxOSDisposableImagePreflightReport -Preflight $pf -OutputDirectory $script:LogsRoot -Stem 'm4-unit'
        $json = Get-Content -LiteralPath $paths.Json -Raw | ConvertFrom-Json
        $md = Get-Content -LiteralPath $paths.Markdown -Raw
        $json.modifyingCommandsInvoked | Should -BeFalse
        $json.realDismExecutionEnabled | Should -BeFalse
        $json.executionAuthorized | Should -BeFalse
        $json.lifecycleCompleted | Should -BeTrue
        $md | Should -Match 'Modifying commands invoked: \*\*False\*\*'
        $md | Should -Match 'Real DISM execution enabled: \*\*False\*\*'
        $md | Should -Match ([regex]::Escape($script:Plan.contentHash))
    }

    It 'CLI default is simulation-only and live mode is not auto-run' {
        $text = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts\Test-DisposableImagePreflight.ps1') -Raw
        $text | Should -Match 'Mode = ''Simulation'''
        $text | Should -Match 'AllowLiveReadOnlyPreflight'
        $text | Should -Match 'Awaiting explicit operator approval'
        $text | Should -Not -Match '/Commit'
        $text | Should -Not -Match '/Remove-ProvisionedAppxPackage'
        $text | Should -Not -Match '/Disable-Feature'
    }

    It 'refuses OneDrive report output paths' {
        $adapter = New-XboxOSMockReadOnlyDismAdapter -FixtureRoot $script:Fixtures
        $pf = New-XboxOSDisposableImagePreflight `
            -Plan $script:Plan `
            -CompatibilityManifest $script:Compatibility `
            -Adapter $adapter `
            -Mode Simulation `
            -WorkRoot $script:WorkRoot `
            -LogsRoot $script:LogsRoot
        $pf = Invoke-XboxOSDisposableImagePreflightSimulate -Preflight $pf
        {
            Save-XboxOSDisposableImagePreflightReport -Preflight $pf -OutputDirectory 'C:\Users\ci\OneDrive\Logs' -Stem 'bad'
        } | Should -Throw -ExpectedMessage '*OneDrive*'
    }
}
