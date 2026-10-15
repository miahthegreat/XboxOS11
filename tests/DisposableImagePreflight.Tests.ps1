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
        $script:ExpectedSha = Get-XboxOSExpectedSourceIsoSha256
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports preflight engine 4.1.2 and readonly-dism-v1' {
        Get-XboxOSPreflightEngineVersion | Should -Be '4.1.2'
        Get-XboxOSReadOnlyDismAdapterVersion | Should -Be 'readonly-dism-v1'
        Get-XboxOSRealDismExecutionEnabled | Should -BeFalse
    }

    It 'allowlists approved operations and rejects arbitrary/prohibited arguments' {
        $ok = Assert-XboxOSReadOnlyDismOperationAllowed -Operation GetFeatures -Parameters @{ MountDir = 'C:\XboxOS\Work\m\mount' }
        $ok.Class | Should -Be 'PureInspection'
        { Assert-XboxOSReadOnlyDismOperationAllowed -Operation RemoveAppx } | Should -Throw
        $scan = Test-XboxOSDismArgumentListAllowed -ArgumentList @('/English', '/Remove-ProvisionedAppxPackage', '/PackageName:x')
        $scan.Allowed | Should -BeFalse
        $commit = Test-XboxOSDismArgumentListAllowed -ArgumentList @('/English', '/Unmount-Image', '/MountDir:C:\m', '/Commit')
        $commit.Allowed | Should -BeFalse
        $disable = Test-XboxOSDismArgumentListAllowed -ArgumentList @('/English', '/Image:C:\m', '/Disable-Feature', '/FeatureName:x')
        $disable.Allowed | Should -BeFalse
        $mount = Test-XboxOSDismArgumentListAllowed -ArgumentList @('/English', '/Mount-Image', '/ImageFile:x.wim', '/Index:1', '/MountDir:C:\m')
        $mount.Allowed | Should -BeFalse
        $ro = Test-XboxOSDismArgumentListAllowed -ArgumentList @('/English', '/Mount-Image', '/ImageFile:x.wim', '/Index:1', '/MountDir:C:\m', '/ReadOnly')
        $ro.Allowed | Should -BeTrue
        $arb = Test-XboxOSDismArgumentListAllowed -ArgumentList @('/English', '/Get-Packages', '/ScratchDir:C:\tmp')
        $arb.Allowed | Should -BeFalse
    }

    It 'records exact native argument arrays via injectable runner and rejects modifying ops' {
        $rec = New-XboxOSRecordingDismRunner -AutoFixtureResponses -FixtureRoot $script:Fixtures
        $adapter = New-XboxOSRealReadOnlyDismAdapter -DismPath 'C:\Windows\System32\dism.exe' -NativeRunner $rec.Runner
        $r = $adapter.InvokeOperation('GetFeatures', @{ MountDir = 'C:\XboxOS\Work\ws\mount' })
        $r.ExitCode | Should -Be 0
        @($rec.Calls).Count | Should -Be 1
        $rec.Calls[0].ArgumentList | Should -Be @('/English', '/Image:C:\XboxOS\Work\ws\mount', '/Get-Features')
        { Invoke-XboxOSNativeDismCommand -DismPath 'C:\Windows\System32\dism.exe' -ArgumentList @('/English', '/Commit') -Runner $rec.Runner } |
            Should -Throw
        { Invoke-XboxOSNativeDismCommand -DismPath 'C:\Windows\System32\dism.exe' -ArgumentList @('/English', '/Remove-ProvisionedAppxPackage', '/PackageName:x') -Runner $rec.Runner } |
            Should -Throw
        { Invoke-XboxOSNativeDismCommand -DismPath 'C:\Windows\System32\dism.exe' -ArgumentList @('/English', '/Image:C:\m', '/Disable-Feature', '/FeatureName:x') -Runner $rec.Runner } |
            Should -Throw
        { Invoke-XboxOSNativeDismCommand -DismPath 'C:\Windows\System32\dism.exe' -ArgumentList @('/English', '/Mount-Image', '/ImageFile:x.wim', '/Index:1', '/MountDir:C:\m') -Runner $rec.Runner } |
            Should -Throw
        $adapter.Ctx.ModifyingCommandsInvoked | Should -BeFalse
        $adapter.Ctx.RealDismExecutionEnabled | Should -BeFalse
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

    It 'fails closed on unrelated mounts, traversal, and image-index ambiguity' {
        $mounts = Test-XboxOSSourceImagePrerequisites `
            -WorkRoot $script:WorkRoot `
            -LogsRoot $script:LogsRoot `
            -RequireIsoPresent:$false `
            -MinimumFreeBytes 1KB `
            -ExistingMounts @([pscustomobject]@{ MountDir = 'C:\OtherMount\Windows' })
        $mounts.valid | Should -BeFalse
        ($mounts.errors -join ' ') | Should -Match 'unrelated'

        $trav = Test-XboxOSSourceImagePrerequisites `
            -IsoPath 'C:\XboxOS\Sources\..\..\Windows\bad.iso' `
            -WorkRoot $script:WorkRoot `
            -LogsRoot $script:LogsRoot `
            -RequireIsoPresent:$false `
            -MinimumFreeBytes 1KB
        $trav.valid | Should -BeFalse
        ($trav.errors -join ' ') | Should -Match 'traversal'

        $ambiguous = @(
            [pscustomobject]@{ Index = 5; Name = 'Windows 11 Pro' }
            [pscustomobject]@{ Index = 6; Name = 'Windows 11 Pro' }
        )
        { Resolve-XboxOSExactImageIndex -Images $ambiguous -ExactName 'Windows 11 Pro' } | Should -Throw -ExpectedMessage '*ambiguous*'
        { Resolve-XboxOSExactImageIndex -Images @([pscustomobject]@{ Index = 1; Name = 'Windows 11 Home' }) -ExactName 'Windows 11 Pro' } |
            Should -Throw -ExpectedMessage '*not found*'
    }

    It 'enforces disposable workspace ownership and rejects unsafe cleanup paths' {
        $ws = New-XboxOSDisposableWorkspace -WorkRoot $script:WorkRoot -OwnerId 'owner-test'
        { Assert-XboxOSDisposableWorkspaceOwnership -Workspace $ws -OwnershipToken $ws.ownershipToken -CandidateMountDir $ws.mountDir } |
            Should -Not -Throw
        { Assert-XboxOSDisposableWorkspaceOwnership -Workspace $ws -OwnershipToken 'bad' } | Should -Throw
        { Assert-XboxOSDisposableWorkspaceOwnership -Workspace $ws -OwnershipToken $ws.ownershipToken -CandidateMountDir 'C:\Other\mount' } |
            Should -Throw -ExpectedMessage '*outside owned workspace*'
        { Assert-XboxOSPathOwnedAndSafe -CandidatePath ($ws.workspacePath + '\..\..\Windows') -WorkspaceRoot $ws.workspacePath } |
            Should -Throw
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
        @($pf).Count | Should -Be 1
        $pf.transactionState | Should -Be 'Completed'
        $pf.cleanupStatus | Should -Be 'Succeeded'
        $pf.mountOwned | Should -BeFalse
        $pf.modifyingCommandsInvoked | Should -BeFalse
        $pf.realDismExecutionEnabled | Should -BeFalse
        $pf.executionAuthorized | Should -BeFalse
        $pf.sourceIsoProtected | Should -BeTrue
        $pf.driftResult.result | Should -Be 'Match'
        $pf.preflightDecision | Should -Be 'Blocked'
        $adapter.Ctx.SourceIsoModified | Should -BeFalse
    }

    It 'runs harnessed live read-only lifecycle without native DISM or CI auto-start' {
        $isoPath = Join-Path $script:TempRoot 'Windows11_Client_x64_en-us_26300_9457.iso'
        Set-Content -LiteralPath $isoPath -Value 'fake-iso-for-harness' -Encoding ascii
        $sourceWim = Join-Path $script:TempRoot 'iso-root\sources\install.wim'
        New-Item -ItemType Directory -Path (Split-Path -Parent $sourceWim) -Force | Out-Null
        Set-Content -LiteralPath $sourceWim -Value 'fake-install-wim' -Encoding ascii

        $rec = New-XboxOSRecordingDismRunner -AutoFixtureResponses -FixtureRoot $script:Fixtures
        $adapter = New-XboxOSRealReadOnlyDismAdapter -DismPath 'C:\Windows\System32\dism.exe' -NativeRunner $rec.Runner
        $expectedSha = [string]$script:ExpectedSha
        $hashProvider = { param($IsoPath) return $expectedSha }.GetNewClosure()
        $hiveReader = {
            param($MountDir)
            return [pscustomobject]@{
                buildNumber    = '26300.9457'
                displayVersion = '26H2'
                editionId      = 'Professional'
                productName    = 'Windows 11 Pro'
                architecture   = 'amd64'
            }
        }
        $mountRunner = {
            param($IsoPath)
            return [pscustomobject]@{
                IsoPath         = $IsoPath
                DriveLetter     = 'Z'
                IsoRoot         = 'Z:\'
                SourceImageFile = $sourceWim
                DiskImage       = $null
            }
        }.GetNewClosure()
        $dismountRunner = { param($IsoPath) return $true }

        $pf = New-XboxOSDisposableImagePreflight `
            -Plan $script:Plan `
            -BaselineInventory $script:Inventory `
            -CompatibilityManifest $script:Compatibility `
            -Adapter $adapter `
            -Mode LiveReadOnly `
            -IsoPath $isoPath `
            -WorkRoot $script:WorkRoot `
            -LogsRoot $script:LogsRoot

        $pf = Invoke-XboxOSDisposableImagePreflightLiveReadOnly `
            -Preflight $pf `
            -ConfirmLiveReadOnlyPreflight `
            -AllowLiveReadOnlyPreflight `
            -IUnderstandTemporaryHostState `
            -AllowCiBypassForUnitTests `
            -IsoMountRunner $mountRunner `
            -IsoDismountRunner $dismountRunner `
            -HashProvider $hashProvider `
            -HiveReader $hiveReader `
            -MinimumFreeBytes 1KB

        $pf.transactionState | Should -Be 'Completed'
        $pf.cleanupStatus | Should -Be 'Succeeded'
        $pf.cleanupVerified | Should -BeTrue
        $pf.inventoryMetadataVerified | Should -BeTrue
        $pf.registryHiveCleanupVerified | Should -BeTrue
        $pf.registryHiveCleanupNotApplicable | Should -BeTrue
        $pf.mountOwned | Should -BeFalse
        $pf.modifyingCommandsInvoked | Should -BeFalse
        $pf.realDismExecutionEnabled | Should -BeFalse
        $pf.executionAuthorized | Should -BeFalse
        $pf.liveReadOnlyAuthorized | Should -BeTrue
        $pf.realReadOnlyInspectionOccurred | Should -BeTrue
        $pf.disposableExportOccurred | Should -BeTrue
        $pf.readOnlyMountOccurred | Should -BeTrue
        $pf.postIsoIntegrityVerified | Should -BeTrue
        $pf.sourceIsoProtected | Should -BeTrue
        $pf.sourceImage.verified | Should -BeTrue
        $pf.sourceImage.buildNumber | Should -Be '26300.9457'
        $pf.sourceImage.displayVersion | Should -Be '26H2'
        $pf.expectedSourceImage.buildNumber | Should -Be '26300.9457'
        ($rec.Calls | Where-Object { ($_.ArgumentList -join ' ') -match '/Commit' }).Count | Should -Be 0
        ($rec.Calls | Where-Object { ($_.ArgumentList -join ' ') -match '/Remove-ProvisionedAppxPackage' }).Count | Should -Be 0
        ($rec.Calls | Where-Object { ($_.ArgumentList -join ' ') -match '/Export-Image' }).Count | Should -Be 1
        ($rec.Calls | Where-Object { ($_.ArgumentList -join ' ') -match '/ReadOnly' }).Count | Should -Be 1
        ($rec.Calls | Where-Object { ($_.ArgumentList -join ' ') -match '/Discard' }).Count | Should -Be 1
        ($rec.Calls | Where-Object { ($_.ArgumentList -join ' ') -match '/Get-MountedImageInfo' }).Count | Should -BeGreaterThan 2

        $paths = Save-XboxOSDisposableImagePreflightReport -Preflight $pf -OutputDirectory $script:LogsRoot -Stem 'm4-live-harness'
        $json = Get-Content -LiteralPath $paths.Json -Raw | ConvertFrom-Json
        $json.reportNamespace | Should -Be 'm4-live-readonly'
        $json.modifyingCommandsInvoked | Should -BeFalse
        $json.realDismExecutionEnabled | Should -BeFalse
        $json.executionAuthorized | Should -BeFalse
        $json.realReadOnlyInspectionOccurred | Should -BeTrue
        $json.cleanupVerified | Should -BeTrue
        $json.inventoryMetadataVerified | Should -BeTrue
    }

    It 'aborts harnessed live path on unexpected mounts and cleanup failure prevents success' {
        $isoPath = Join-Path $script:TempRoot 'Windows11_badmount.iso'
        Set-Content -LiteralPath $isoPath -Value 'fake' -Encoding ascii
        $rec = New-XboxOSRecordingDismRunner -Responses @{
            '*/Get-MountedImageInfo' = @{
                ExitCode = 0
                Output   = @('Mount Dir : C:\OtherMount\Windows', 'Status : Ok', 'Read Only : Yes')
            }
        }
        $adapter = New-XboxOSRealReadOnlyDismAdapter -DismPath 'C:\Windows\System32\dism.exe' -NativeRunner $rec.Runner
        $expectedSha = [string]$script:ExpectedSha
        $hashProvider = { param($IsoPath) return $expectedSha }.GetNewClosure()
        $pf = New-XboxOSDisposableImagePreflight `
            -Plan $script:Plan `
            -CompatibilityManifest $script:Compatibility `
            -Adapter $adapter `
            -Mode LiveReadOnly `
            -IsoPath $isoPath `
            -WorkRoot $script:WorkRoot `
            -LogsRoot $script:LogsRoot
        $pf = Invoke-XboxOSDisposableImagePreflightLiveReadOnly `
            -Preflight $pf `
            -ConfirmLiveReadOnlyPreflight `
            -AllowLiveReadOnlyPreflight `
            -IUnderstandTemporaryHostState `
            -AllowCiBypassForUnitTests `
            -HashProvider $hashProvider `
            -HiveReader ({ param($MountDir) [pscustomobject]@{ buildNumber = '26300.9457'; displayVersion = '26H2' } }) `
            -MinimumFreeBytes 1KB `
            -IsoMountRunner { throw 'should not mount' } `
            -IsoDismountRunner { }
        $pf.transactionState | Should -Not -Be 'Completed'
        ($pf.blockers -join ' ') | Should -Match 'unrelated'

        $failResponses = @{
            '*/Unmount-Image*' = @{ ExitCode = 1; Output = @('Unmount failed') }
        }
        $recFail2 = New-XboxOSRecordingDismRunner -Responses $failResponses -AutoFixtureResponses -FixtureRoot $script:Fixtures
        $sourceWim = Join-Path $script:TempRoot 'iso-root2\sources\install.wim'
        New-Item -ItemType Directory -Path (Split-Path -Parent $sourceWim) -Force | Out-Null
        Set-Content -LiteralPath $sourceWim -Value 'wim' -Encoding ascii
        $adapter2 = New-XboxOSRealReadOnlyDismAdapter -DismPath 'C:\Windows\System32\dism.exe' -NativeRunner $recFail2.Runner
        $iso2 = Join-Path $script:TempRoot 'Windows11_unmountfail.iso'
        Set-Content -LiteralPath $iso2 -Value 'fake' -Encoding ascii
        $pf2 = New-XboxOSDisposableImagePreflight `
            -Plan $script:Plan `
            -BaselineInventory $script:Inventory `
            -CompatibilityManifest $script:Compatibility `
            -Adapter $adapter2 `
            -Mode LiveReadOnly `
            -IsoPath $iso2 `
            -WorkRoot $script:WorkRoot `
            -LogsRoot $script:LogsRoot
        $hashProvider2 = { param($IsoPath) return $expectedSha }.GetNewClosure()
        $mountRunner2 = {
            param($IsoPath)
            return [pscustomobject]@{
                IsoPath         = $IsoPath
                DriveLetter     = 'Y'
                IsoRoot         = 'Y:\'
                SourceImageFile = $sourceWim
                DiskImage       = $null
            }
        }.GetNewClosure()
        $hiveReader2 = {
            param($MountDir)
            return [pscustomobject]@{
                buildNumber    = '26300.9457'
                displayVersion = '26H2'
                editionId      = 'Professional'
                productName    = 'Windows 11 Pro'
            }
        }
        $pf2 = Invoke-XboxOSDisposableImagePreflightLiveReadOnly `
            -Preflight $pf2 `
            -ConfirmLiveReadOnlyPreflight `
            -AllowLiveReadOnlyPreflight `
            -IUnderstandTemporaryHostState `
            -AllowCiBypassForUnitTests `
            -HashProvider $hashProvider2 `
            -HiveReader $hiveReader2 `
            -MinimumFreeBytes 1KB `
            -IsoMountRunner $mountRunner2 `
            -IsoDismountRunner { param($IsoPath) }
        $pf2.transactionState | Should -Not -Be 'Completed'
        $pf2.cleanupStatus | Should -BeIn @('Failed', 'Recovered')
        $pf2.cleanupVerified | Should -BeFalse
        $pf2.preflightDecision | Should -Be 'Failed'
    }

    It 'creates unique owned registry hive mount names and refuses collisions' {
        $a = New-XboxOSOwnedRegistryHiveMountSpec -RunId 'runA'
        $b = New-XboxOSOwnedRegistryHiveMountSpec -RunId 'runA'
        $a.leafName | Should -Match '^XboxOSPreflight-runA-[0-9a-f]{12}$'
        $b.leafName | Should -Match '^XboxOSPreflight-runA-[0-9a-f]{12}$'
        $a.leafName | Should -Not -Be $b.leafName
        $a.ownershipToken | Should -Not -BeNullOrEmpty
        Assert-XboxOSOwnedRegistryHiveMount -HiveMountSpec $a -ExpectedOwnershipToken $a.ownershipToken
        { Assert-XboxOSOwnedRegistryHiveMount -HiveMountSpec $a -ExpectedOwnershipToken 'nope' } |
            Should -Throw -ExpectedMessage '*ownership token mismatch*'

        # Any newly generated leaf appears occupied => refuse overwrite.
        $presence = { param($LeafName) return $true }
        {
            Get-XboxOSMountedImageHiveMetadata `
                -MountDir $script:WorkRoot `
                -RunId 'collision' `
                -OwnershipSeed 'seed' `
                -PresenceTester $presence `
                -RegLoad { throw 'should not load over collision' }
        } | Should -Throw -ExpectedMessage '*preexisting registry hive mount*'
    }

    It 'fails closed on hive load failure, missing CurrentVersion, unload failure, and unverified absence' {
        $mountDir = Join-Path $script:WorkRoot 'hive-mount'
        $software = Join-Path $mountDir 'Windows\System32\config\SOFTWARE'
        New-Item -ItemType Directory -Path (Split-Path -Parent $software) -Force | Out-Null
        Set-Content -LiteralPath $software -Value 'fake-hive' -Encoding ascii

        $bag = [pscustomobject]@{ Present = [System.Collections.Generic.Dictionary[string, bool]]::new() }
        $presence = {
            param($LeafName)
            return $bag.Present.ContainsKey([string]$LeafName) -and $bag.Present[[string]$LeafName]
        }.GetNewClosure()
        $loadOk = {
            param($RegKeyPath, $HiveFile, $LeafName)
            $bag.Present[[string]$LeafName] = $true
            @{ ExitCode = 0; Output = @('loaded') }
        }.GetNewClosure()
        $unloadOk = {
            param($RegKeyPath, $LeafName)
            $bag.Present[[string]$LeafName] = $false
            @{ ExitCode = 0; Output = @('unloaded') }
        }.GetNewClosure()

        {
            Get-XboxOSMountedImageHiveMetadata `
                -MountDir $mountDir `
                -RunId 'loadfail' `
                -PresenceTester $presence `
                -RegLoad { param($RegKeyPath, $HiveFile, $LeafName) @{ ExitCode = 1; Output = @('load denied') } }
        } | Should -Throw -ExpectedMessage '*load failed*'

        $bag.Present.Clear()
        {
            Get-XboxOSMountedImageHiveMetadata `
                -MountDir $mountDir `
                -RunId 'missingcv' `
                -PresenceTester $presence `
                -RegLoad $loadOk `
                -RegUnload $unloadOk `
                -CurrentVersionReader { param($LeafName, $PsProviderPath) return [pscustomobject]@{ CurrentBuild = ''; DisplayVersion = '' } }
        } | Should -Throw -ExpectedMessage '*CurrentBuild*'

        $bag.Present.Clear()
        {
            Get-XboxOSMountedImageHiveMetadata `
                -MountDir $mountDir `
                -RunId 'unloadfail' `
                -PresenceTester $presence `
                -RegLoad $loadOk `
                -RegUnload ({
                        param($RegKeyPath, $LeafName)
                        @{ ExitCode = 5; Output = @('access denied') }
                    }) `
                -CurrentVersionReader {
                    param($LeafName, $PsProviderPath)
                    [pscustomobject]@{ CurrentBuild = '26300'; UBR = 9457; DisplayVersion = '26H2'; EditionID = 'Professional' }
                }
        } | Should -Throw -ExpectedMessage '*registry hive cleanup failed*'
        @($bag.Present.GetEnumerator() | Where-Object Value -eq $true).Count | Should -BeGreaterThan 0

        $bag.Present.Clear()
        {
            Get-XboxOSMountedImageHiveMetadata `
                -MountDir $mountDir `
                -RunId 'ghostunload' `
                -PresenceTester $presence `
                -RegLoad $loadOk `
                -RegUnload ({
                        param($RegKeyPath, $LeafName)
                        @{ ExitCode = 0; Output = @('unloaded') }
                    }) `
                -CurrentVersionReader {
                    param($LeafName, $PsProviderPath)
                    [pscustomobject]@{ CurrentBuild = '26300'; UBR = 9457; DisplayVersion = '26H2' }
                }
        } | Should -Throw -ExpectedMessage '*still present after unload*'
    }

    It 'verifies hive cleanup after inspection errors and does not unload unrelated keys' {
        $mountDir = Join-Path $script:WorkRoot 'hive-mount-recovery'
        $software = Join-Path $mountDir 'Windows\System32\config\SOFTWARE'
        New-Item -ItemType Directory -Path (Split-Path -Parent $software) -Force | Out-Null
        Set-Content -LiteralPath $software -Value 'fake-hive' -Encoding ascii

        $bag = [pscustomobject]@{
            Present     = [System.Collections.Generic.Dictionary[string, bool]]::new()
            UnloadCalls = [System.Collections.ArrayList]@()
        }
        $bag.Present['OtherAppHive'] = $true
        $presence = {
            param($LeafName)
            return $bag.Present.ContainsKey([string]$LeafName) -and $bag.Present[[string]$LeafName]
        }.GetNewClosure()
        try {
            $null = Get-XboxOSMountedImageHiveMetadata `
                -MountDir $mountDir `
                -RunId 'inspecterr' `
                -PresenceTester $presence `
                -RegLoad ({
                        param($RegKeyPath, $HiveFile, $LeafName)
                        $bag.Present[[string]$LeafName] = $true
                        @{ ExitCode = 0; Output = @('loaded') }
                    }.GetNewClosure()) `
                -RegUnload ({
                        param($RegKeyPath, $LeafName)
                        $null = $bag.UnloadCalls.Add([string]$LeafName)
                        $bag.Present[[string]$LeafName] = $false
                        @{ ExitCode = 0; Output = @('unloaded') }
                    }.GetNewClosure()) `
                -CurrentVersionReader { throw 'simulated CurrentVersion query failure' }
        }
        catch {
            $_.Exception.Message | Should -Match 'CurrentVersion query failure'
        }
        $bag.Present['OtherAppHive'] | Should -BeTrue
        @($bag.UnloadCalls).Count | Should -Be 1
        @($bag.UnloadCalls)[0] | Should -Match '^XboxOSPreflight-inspecterr-'
        @($bag.Present.GetEnumerator() | Where-Object { $_.Key -like 'XboxOSPreflight-*' -and $_.Value }).Count | Should -Be 0

        $meta = Get-XboxOSMountedImageHiveMetadata `
            -MountDir $mountDir `
            -RunId 'okhive' `
            -PresenceTester $presence `
            -RegLoad ({
                    param($RegKeyPath, $HiveFile, $LeafName)
                    $bag.Present[[string]$LeafName] = $true
                    @{ ExitCode = 0; Output = @('loaded') }
                }.GetNewClosure()) `
            -RegUnload ({
                    param($RegKeyPath, $LeafName)
                    $bag.Present[[string]$LeafName] = $false
                    @{ ExitCode = 0; Output = @('unloaded') }
                }.GetNewClosure()) `
            -CurrentVersionReader {
                param($LeafName, $PsProviderPath)
                [pscustomobject]@{ CurrentBuild = '26300'; UBR = 9457; DisplayVersion = '26H2'; EditionID = 'Professional'; ProductName = 'Windows 11 Pro' }
            }
        $meta.hiveCleanupVerified | Should -BeTrue
        $meta.buildNumber | Should -Be '26300.9457'
        $meta.hiveMount.leafName | Should -Match '^XboxOSPreflight-okhive-'
        $bag.Present['OtherAppHive'] | Should -BeTrue
    }

    It 'refuses WIM cleanup success when registry hive cleanup fails during live harness' {
        $isoPath = Join-Path $script:TempRoot 'Windows11_hivecleanup.iso'
        Set-Content -LiteralPath $isoPath -Value 'fake' -Encoding ascii
        $sourceWim = Join-Path $script:TempRoot 'iso-root-hive\sources\install.wim'
        New-Item -ItemType Directory -Path (Split-Path -Parent $sourceWim) -Force | Out-Null
        Set-Content -LiteralPath $sourceWim -Value 'wim' -Encoding ascii
        $rec = New-XboxOSRecordingDismRunner -AutoFixtureResponses -FixtureRoot $script:Fixtures
        $adapter = New-XboxOSRealReadOnlyDismAdapter -DismPath 'C:\Windows\System32\dism.exe' -NativeRunner $rec.Runner
        $expectedSha = [string]$script:ExpectedSha
        $hiveBag = [pscustomobject]@{ Present = [System.Collections.Generic.Dictionary[string, bool]]::new() }
        $pf = New-XboxOSDisposableImagePreflight `
            -Plan $script:Plan `
            -BaselineInventory $script:Inventory `
            -CompatibilityManifest $script:Compatibility `
            -Adapter $adapter `
            -Mode LiveReadOnly `
            -IsoPath $isoPath `
            -WorkRoot $script:WorkRoot `
            -LogsRoot $script:LogsRoot
        $pf = Invoke-XboxOSDisposableImagePreflightLiveReadOnly `
            -Preflight $pf `
            -ConfirmLiveReadOnlyPreflight `
            -AllowLiveReadOnlyPreflight `
            -IUnderstandTemporaryHostState `
            -AllowCiBypassForUnitTests `
            -HashProvider ({ param($IsoPath) return $expectedSha }.GetNewClosure()) `
            -IsoMountRunner ({
                    param($IsoPath)
                    [pscustomobject]@{ IsoPath = $IsoPath; DriveLetter = 'V'; IsoRoot = 'V:\'; SourceImageFile = $sourceWim; DiskImage = $null }
                }.GetNewClosure()) `
            -IsoDismountRunner { param($IsoPath) } `
            -PresenceTester ({
                    param($LeafName)
                    return $hiveBag.Present.ContainsKey([string]$LeafName) -and $hiveBag.Present[[string]$LeafName]
                }.GetNewClosure()) `
            -RegLoad ({
                    param($RegKeyPath, $HiveFile, $LeafName)
                    $hiveBag.Present[[string]$LeafName] = $true
                    @{ ExitCode = 0; Output = @('loaded') }
                }.GetNewClosure()) `
            -RegUnload ({
                    param($RegKeyPath, $LeafName)
                    @{ ExitCode = 9; Output = @('unload failed') }
                }.GetNewClosure()) `
            -CurrentVersionReader {
                param($LeafName, $PsProviderPath)
                [pscustomobject]@{ CurrentBuild = '26300'; UBR = 9457; DisplayVersion = '26H2'; EditionID = 'Professional' }
            } `
            -MinimumFreeBytes 1KB
        $pf.transactionState | Should -Not -Be 'Completed'
        $pf.registryHiveCleanupVerified | Should -BeFalse
        $pf.cleanupStatus | Should -Be 'Failed'
        $pf.preflightDecision | Should -Be 'Failed'
        ($pf.blockers -join ' ') | Should -Match 'registry hive cleanup failed'
        # WIM discard may still be attempted for recovery, but success is forbidden.
        $pf.cleanupVerified | Should -BeFalse
    }

    It 'fails closed on observed edition/build/DisplayVersion mismatches' {
        $expected = Get-XboxOSExpectedSourceImageIdentity
        {
            Assert-XboxOSObservedSourceImageIdentity -Observed ([pscustomobject]@{
                    editionName    = 'Windows 11 Home'
                    buildNumber    = $expected.buildNumber
                    displayVersion = $expected.displayVersion
                    isoSha256      = $expected.isoSha256
                    exportedIndex  = 1
                    sourceIndex    = 1
                }) -Expected $expected
        } | Should -Throw -ExpectedMessage '*edition*'
        {
            Assert-XboxOSObservedSourceImageIdentity -Observed ([pscustomobject]@{
                    editionName    = $expected.editionName
                    buildNumber    = '26100.1'
                    displayVersion = $expected.displayVersion
                    isoSha256      = $expected.isoSha256
                    exportedIndex  = 1
                    sourceIndex    = 1
                }) -Expected $expected
        } | Should -Throw -ExpectedMessage '*buildNumber*'
        {
            Assert-XboxOSObservedSourceImageIdentity -Observed ([pscustomobject]@{
                    editionName    = $expected.editionName
                    buildNumber    = $expected.buildNumber
                    displayVersion = '25H2'
                    isoSha256      = $expected.isoSha256
                    exportedIndex  = 1
                    sourceIndex    = 1
                }) -Expected $expected
        } | Should -Throw -ExpectedMessage '*displayVersion*'

        ConvertTo-XboxOSNormalizedBuildNumber -VersionText '10.0.26300.9457' | Should -Be '26300.9457'
    }

    It 'records nonzero DISM exit codes and does not mark export/mount success' {
        $failRunner = {
            param($DismPath, $ArgumentList)
            return @{ ExitCode = 87; Output = @('simulated failure') }
        }
        $adapter = New-XboxOSRealReadOnlyDismAdapter -DismPath 'C:\Windows\System32\dism.exe' -NativeRunner $failRunner
        {
            $adapter.InvokeOperation('ExportImage', @{
                    SourceImageFile      = 'C:\XboxOS\Work\src.wim'
                    SourceIndex          = '6'
                    DestinationImageFile = 'C:\XboxOS\Work\out.wim'
                })
        } | Should -Throw -ExpectedMessage '*exit code 87*'
        $adapter.Ctx.DisposableExportAttempted | Should -BeTrue
        $adapter.Ctx.DisposableExportOccurred | Should -BeFalse
        @($adapter.Ctx.Commands | Where-Object { $_.failed -and $_.exitCode -eq 87 }).Count | Should -Be 1
    }

    It 'requires cleanup confirmation and sticky Failed cleanup status' {
        $pf = [pscustomobject]@{
            cleanupStatus   = 'Failed'
            cleanupVerified = $false
        }
        Set-XboxOSPreflightCleanupStatus -Preflight $pf -Status Succeeded
        $pf.cleanupStatus | Should -Be 'Failed'

        $pf2 = [pscustomobject]@{
            cleanupStatus   = 'NotStarted'
            cleanupVerified = $false
        }
        Set-XboxOSPreflightCleanupStatus -Preflight $pf2 -Status Succeeded
        $pf2.cleanupStatus | Should -Be 'NotStarted'
        $pf2.cleanupVerified = $true
        Set-XboxOSPreflightCleanupStatus -Preflight $pf2 -Status Succeeded
        $pf2.cleanupStatus | Should -Be 'Succeeded'
    }

    It 'rejects harnessed live metadata mismatches from hive reader' {
        $isoPath = Join-Path $script:TempRoot 'Windows11_meta_mismatch.iso'
        Set-Content -LiteralPath $isoPath -Value 'fake' -Encoding ascii
        $sourceWim = Join-Path $script:TempRoot 'iso-root-meta\sources\install.wim'
        New-Item -ItemType Directory -Path (Split-Path -Parent $sourceWim) -Force | Out-Null
        Set-Content -LiteralPath $sourceWim -Value 'wim' -Encoding ascii
        $rec = New-XboxOSRecordingDismRunner -AutoFixtureResponses -FixtureRoot $script:Fixtures
        $adapter = New-XboxOSRealReadOnlyDismAdapter -DismPath 'C:\Windows\System32\dism.exe' -NativeRunner $rec.Runner
        $expectedSha = [string]$script:ExpectedSha
        $pf = New-XboxOSDisposableImagePreflight `
            -Plan $script:Plan `
            -BaselineInventory $script:Inventory `
            -CompatibilityManifest $script:Compatibility `
            -Adapter $adapter `
            -Mode LiveReadOnly `
            -IsoPath $isoPath `
            -WorkRoot $script:WorkRoot `
            -LogsRoot $script:LogsRoot
        $pf = Invoke-XboxOSDisposableImagePreflightLiveReadOnly `
            -Preflight $pf `
            -ConfirmLiveReadOnlyPreflight `
            -AllowLiveReadOnlyPreflight `
            -IUnderstandTemporaryHostState `
            -AllowCiBypassForUnitTests `
            -HashProvider ({ param($IsoPath) return $expectedSha }.GetNewClosure()) `
            -HiveReader ({
                    param($MountDir)
                    return [pscustomobject]@{
                        buildNumber    = '26300.9457'
                        displayVersion = '25H2'
                        editionId      = 'Professional'
                        productName    = 'Windows 11 Pro'
                    }
                }) `
            -IsoMountRunner ({
                    param($IsoPath)
                    return [pscustomobject]@{
                        IsoPath = $IsoPath; DriveLetter = 'X'; IsoRoot = 'X:\'
                        SourceImageFile = $sourceWim; DiskImage = $null
                    }
                }.GetNewClosure()) `
            -IsoDismountRunner { param($IsoPath) } `
            -MinimumFreeBytes 1KB
        $pf.transactionState | Should -Not -Be 'Completed'
        $pf.inventoryMetadataVerified | Should -BeFalse
        ($pf.blockers -join ' ') | Should -Match 'displayVersion'
    }

    It 'fails post-run ISO integrity checks and prevents success' {
        $isoPath = Join-Path $script:TempRoot 'Windows11_posthash.iso'
        Set-Content -LiteralPath $isoPath -Value 'fake' -Encoding ascii
        $sourceWim = Join-Path $script:TempRoot 'iso-root-post\sources\install.wim'
        New-Item -ItemType Directory -Path (Split-Path -Parent $sourceWim) -Force | Out-Null
        Set-Content -LiteralPath $sourceWim -Value 'wim' -Encoding ascii
        $rec = New-XboxOSRecordingDismRunner -AutoFixtureResponses -FixtureRoot $script:Fixtures
        $adapter = New-XboxOSRealReadOnlyDismAdapter -DismPath 'C:\Windows\System32\dism.exe' -NativeRunner $rec.Runner
        $expectedSha = [string]$script:ExpectedSha
        $hashCalls = [System.Collections.ArrayList]@()
        $hashProvider = {
            param($IsoPath)
            $null = $hashCalls.Add(1)
            if ($hashCalls.Count -le 1) { return $expectedSha }
            return ('F' * 64)
        }.GetNewClosure()
        $pf = New-XboxOSDisposableImagePreflight `
            -Plan $script:Plan `
            -BaselineInventory $script:Inventory `
            -CompatibilityManifest $script:Compatibility `
            -Adapter $adapter `
            -Mode LiveReadOnly `
            -IsoPath $isoPath `
            -WorkRoot $script:WorkRoot `
            -LogsRoot $script:LogsRoot
        $pf = Invoke-XboxOSDisposableImagePreflightLiveReadOnly `
            -Preflight $pf `
            -ConfirmLiveReadOnlyPreflight `
            -AllowLiveReadOnlyPreflight `
            -IUnderstandTemporaryHostState `
            -AllowCiBypassForUnitTests `
            -HashProvider $hashProvider `
            -HiveReader ({
                    param($MountDir)
                    [pscustomobject]@{ buildNumber = '26300.9457'; displayVersion = '26H2'; editionId = 'Professional'; productName = 'Windows 11 Pro' }
                }) `
            -IsoMountRunner ({
                    param($IsoPath)
                    [pscustomobject]@{ IsoPath = $IsoPath; DriveLetter = 'W'; IsoRoot = 'W:\'; SourceImageFile = $sourceWim; DiskImage = $null }
                }.GetNewClosure()) `
            -IsoDismountRunner { param($IsoPath) } `
            -MinimumFreeBytes 1KB
        $pf.postIsoIntegrityVerified | Should -BeFalse
        $pf.transactionState | Should -Not -Be 'Completed'
        $pf.preflightDecision | Should -Be 'Failed'
        ($pf.blockers -join ' ') | Should -Match 'Post-run ISO SHA256'
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

    It 'gates live read-only mode until explicit authorization and blocks CI' {
        { Assert-XboxOSLiveReadOnlyPreflightAuthorization -AllowCiBypassForUnitTests } |
            Should -Throw -ExpectedMessage '*ConfirmLiveReadOnlyPreflight*'
        {
            Assert-XboxOSLiveReadOnlyPreflightAuthorization -ConfirmLiveReadOnlyPreflight -AllowCiBypassForUnitTests
        } | Should -Throw -ExpectedMessage '*AllowLiveReadOnlyPreflight*'
        {
            Assert-XboxOSLiveReadOnlyPreflightAuthorization -ConfirmLiveReadOnlyPreflight -AllowLiveReadOnlyPreflight -AllowCiBypassForUnitTests
        } | Should -Throw -ExpectedMessage '*IUnderstandTemporaryHostState*'
        {
            Assert-XboxOSLiveReadOnlyPreflightAuthorization `
                -ConfirmLiveReadOnlyPreflight `
                -AllowLiveReadOnlyPreflight `
                -IUnderstandTemporaryHostState `
                -AllowCiBypassForUnitTests
        } | Should -Not -Throw

        $prevGa = $env:GITHUB_ACTIONS
        $env:GITHUB_ACTIONS = 'true'
        try {
            {
                Assert-XboxOSLiveReadOnlyPreflightAuthorization `
                    -ConfirmLiveReadOnlyPreflight `
                    -AllowLiveReadOnlyPreflight `
                    -IUnderstandTemporaryHostState
            } | Should -Throw -ExpectedMessage '*cannot run in CI*'
        }
        finally {
            if ($null -eq $prevGa) { Remove-Item Env:GITHUB_ACTIONS -ErrorAction SilentlyContinue }
            else { $env:GITHUB_ACTIONS = $prevGa }
        }
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
        $json.reportNamespace | Should -Be 'm4-simulation'
        $md | Should -Match 'Modifying commands invoked: \*\*False\*\*'
        $md | Should -Match 'Real DISM execution enabled: \*\*False\*\*'
        $md | Should -Match ([regex]::Escape($script:Plan.contentHash))
    }

    It 'CLI default is simulation-only and live mode requires explicit operator switches' {
        $text = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts\Test-DisposableImagePreflight.ps1') -Raw
        $text | Should -Match 'Mode = ''Simulation'''
        $text | Should -Match 'AllowLiveReadOnlyPreflight'
        $text | Should -Match 'IUnderstandTemporaryHostState'
        $text | Should -Match 'New-XboxOSRealReadOnlyDismAdapter'
        $text | Should -Match 'Invoke-XboxOSDisposableImagePreflightLiveReadOnly'
        $text | Should -Match 'cannot run in CI'
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
