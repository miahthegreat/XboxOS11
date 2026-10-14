#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'XboxOS11 pipeline regression' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        Import-Module (Join-Path $repoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force
        $script:RepoRoot = $repoRoot.Path
        $script:ConfigPath = Join-Path $script:RepoRoot 'config\build.json'
        $script:ExternalRoot = 'C:\XboxOS'
        $script:ExternalWork = 'C:\XboxOS\Work'
        $script:ExternalLogs = 'C:\XboxOS\Logs'
        $script:ExternalOutput = 'C:\XboxOS\Output'
    }

    Context 'Workspace isolation' {
        It 'accepts an external workspace while the repository lives under OneDrive' {
            $repoInOneDrive = Test-XboxOSCloudSynchronizedPath -Path $script:RepoRoot
            if (-not $repoInOneDrive) {
                Set-ItResult -Skipped -Because 'Repository is not under a cloud-synchronized path in this environment'
                return
            }

            Assert-XboxOSBuildSafety -WorkspaceRoot $script:ExternalWork -RepoRoot $script:RepoRoot -AdditionalPaths @(
                $script:ExternalLogs
                $script:ExternalOutput
            ) | Should -BeTrue
        }

        It 'rejects a workspace inside OneDrive / cloud sync' {
            {
                Assert-XboxOSBuildSafety -WorkspaceRoot $script:RepoRoot -RepoRoot 'C:\XboxOS\FakeRepo'
            } | Should -Throw -ExpectedMessage '*cloud-synchronized*'
        }

        It 'rejects a workspace inside the repository with boundary-safe comparison' {
            $insideRepo = Join-Path $script:RepoRoot 'artifacts\workspace'
            {
                Assert-XboxOSBuildSafety -WorkspaceRoot $insideRepo -RepoRoot $script:RepoRoot
            } | Should -Throw -ExpectedMessage '*Git repository*'
        }

        It 'does not treat a similarly prefixed sibling path as inside the repository' {
            $repoName = Split-Path -Leaf $script:RepoRoot
            $sibling = Join-Path (Split-Path -Parent $script:RepoRoot) ($repoName + '-sibling-not-repo')
            # Sibling is still under OneDrive in this host; cloud rejection is expected.
            # Boundary check itself must not match via naive prefix on the repo path.
            Test-XboxOSPathEqualsOrUnder -Path $sibling -ParentPath $script:RepoRoot | Should -BeFalse
        }

        It 'accepts the configured safe external workspace' {
            Assert-XboxOSBuildSafety -WorkspaceRoot $script:ExternalWork -RepoRoot $script:RepoRoot | Should -BeTrue
            Test-XboxOSCloudSynchronizedPath -Path $script:ExternalWork | Should -BeFalse
            Test-XboxOSPathEqualsOrUnder -Path $script:ExternalWork -ParentPath $script:RepoRoot | Should -BeFalse
        }

        It 'rejects servicing paths inside the repository or cloud folders' {
            {
                Assert-XboxOSServicingPathSafety -Path (Join-Path $script:RepoRoot 'mount') -RepoRoot $script:RepoRoot -Purpose 'WIM mount'
            } | Should -Throw -ExpectedMessage '*Git repository*'
        }
    }

    Context 'Inventory availability' {
        It 'allows a genuinely empty package inventory' {
            $iso = Join-Path $script:RepoRoot 'tests\Fixtures\missing-source.iso'
            $ctx = New-XboxOSBuildContext -ConfigurationPath $script:ConfigPath -SourceISO $iso -DryRun
            $result = & (Join-Path $script:RepoRoot 'scripts\Remove-Apps.ps1') -BuildContext $ctx -AvailablePackages @() -InventoryState Empty -DryRun
            $result.InventoryState | Should -Be 'Empty'
            ($result.Results | Where-Object Status -eq 'Absent').Count | Should -BeGreaterThan 0
            ($result.Results | Where-Object Status -eq 'NotEvaluated').Count | Should -Be 0
            $result.Success | Should -BeTrue
        }

        It 'allows a genuinely empty feature inventory' {
            $iso = Join-Path $script:RepoRoot 'tests\Fixtures\missing-source.iso'
            $ctx = New-XboxOSBuildContext -ConfigurationPath $script:ConfigPath -SourceISO $iso -DryRun
            $result = & (Join-Path $script:RepoRoot 'scripts\Disable-Features.ps1') -BuildContext $ctx -AvailableFeatures @() -InventoryState Empty -DryRun
            $result.InventoryState | Should -Be 'Empty'
            ($result.Results | Where-Object Status -eq 'Absent').Count | Should -BeGreaterThan 0
            ($result.Results | Where-Object Status -eq 'NotEvaluated').Count | Should -Be 0
            $result.Success | Should -BeTrue
        }

        It 'marks inventory-dependent actions NotEvaluated when inventory is unknown during dry-run' {
            $iso = Join-Path $script:RepoRoot 'tests\Fixtures\missing-source.iso'
            $ctx = New-XboxOSBuildContext -ConfigurationPath $script:ConfigPath -SourceISO $iso -DryRun
            $ctx.ImageMounted = $false
            $ctx.AppxInventoryState = 'Unknown'
            $ctx.FeatureInventoryState = 'Unknown'

            $apps = & (Join-Path $script:RepoRoot 'scripts\Remove-Apps.ps1') -BuildContext $ctx -DryRun
            $apps.InventoryState | Should -Be 'Unknown'
            ($apps.Results | Where-Object { $_.Status -eq 'NotEvaluated' }).Count | Should -BeGreaterThan 0
            ($apps.Results | Where-Object { $_.Status -in @('Removed', 'DryRun', 'Absent') }).Count | Should -Be 0

            $features = & (Join-Path $script:RepoRoot 'scripts\Disable-Features.ps1') -BuildContext $ctx -DryRun
            $features.InventoryState | Should -Be 'Unknown'
            ($features.Results | Where-Object { $_.Status -eq 'NotEvaluated' }).Count | Should -BeGreaterThan 0
        }

        It 'distinguishes Unknown from Empty inventory availability objects' {
            $unknown = Get-XboxOSInventoryAvailability -State Unknown
            $empty = Get-XboxOSInventoryAvailability -State Empty
            $unknown.CanEvaluate | Should -BeFalse
            $empty.CanEvaluate | Should -BeTrue
            $empty.Items.Count | Should -Be 0
        }
    }

    Context 'Error propagation and cleanup' {
        It 'fails on nonterminating PowerShell errors when asserted' {
            $Error.Clear()
            Write-Error 'synthetic-nonterminating' -ErrorAction Continue
            {
                if ($Error.Count -gt 0) {
                    throw "Phase 'Unit' produced nonterminating error(s): $($Error[0])"
                }
            } | Should -Throw -ExpectedMessage '*nonterminating*'
            $Error.Clear()
        }

        It 'fails Invoke-XboxOSDism on nonzero native exit codes' {
            $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
            {
                Invoke-XboxOSDism -DismPath $cmd -ArgumentList @('/d', '/c', 'exit /b 7')
            } | Should -Throw -ExpectedMessage '*exit code 7*'
        }

        It 'propagates phase failures from Failed result statuses' {
            $failed = [pscustomobject]@{
                Success = $false
                Results = @(
                    [pscustomobject]@{ Status = 'Failed'; Package = 'Contoso.App'; Message = 'boom' }
                )
            }
            {
                Assert-XboxOSPhaseOutcome -Result $failed -PhaseName 'RemoveApps'
            } | Should -Throw -ExpectedMessage '*RemoveApps*failed*'
        }

        It 'discards mounts through cleanup helper without committing' {
            $mount = Join-Path $script:ExternalWork 'pester-discard-mount'
            New-Item -ItemType Directory -Path $mount -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $mount 'marker.txt') -Value 'mounted'
            $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
            # DryRun cleanup must not invoke a real DISM commit path.
            Invoke-XboxOSMountCleanup -MountPath $mount -DismPath $cmd -Discard -DryRun
            Test-Path -LiteralPath (Join-Path $mount 'marker.txt') | Should -BeTrue
        }

        It 'completes dry-run Remove/Disable without image modification when inventory is unknown' {
            $iso = Join-Path $script:RepoRoot 'tests\Fixtures\missing-source.iso'
            $ctx = New-XboxOSBuildContext -ConfigurationPath $script:ConfigPath -SourceISO $iso -DryRun
            $wimBefore = Test-Path -LiteralPath $ctx.Paths.WorkingWim
            $apps = & (Join-Path $script:RepoRoot 'scripts\Remove-Apps.ps1') -BuildContext $ctx -DryRun
            $feats = & (Join-Path $script:RepoRoot 'scripts\Disable-Features.ps1') -BuildContext $ctx -DryRun
            $apps.Success | Should -BeTrue
            $feats.Success | Should -BeTrue
            $ctx.ImageMounted | Should -BeFalse
            (Test-Path -LiteralPath $ctx.Paths.WorkingWim) | Should -Be $wimBefore
        }
    }

    Context 'ISO naming from verified metadata' {
        It 'does not label build 26300.9457 as 25H2 without DisplayVersion' {
            $tag = Get-XboxOSIsoReleaseTag -BuildNumber '26300.9457' -ConfiguredRelease 'unverified'
            $tag | Should -Be 'build26300.9457'
            $tag | Should -Not -Match '25H2'
        }

        It 'uses DisplayVersion when verified' {
            Get-XboxOSIsoReleaseTag -DisplayVersion '25H2' -BuildNumber '26300.9457' | Should -Be '25H2'
        }

        It 'builds ISO file names from template without assumed 25H2' {
            $config = (Get-XboxOSBuildConfiguration -Path $script:ConfigPath).Raw
            $name = Get-XboxOSIsoFileName -Configuration $config -BuildNumber '26300.9457' -Edition 'Windows 11 Pro'
            $name | Should -Be 'XboxOS11-Win11Pro-build26300.9457.iso'
            $name | Should -Not -Match '25H2'
        }
    }

    Context 'Resolved configuration paths' {
        It 'resolves build workspace paths to C:\XboxOS regardless of working directory' {
            $config = Get-XboxOSBuildConfiguration -Path $script:ConfigPath
            $root = Resolve-XboxOSPath -Path ([string]$config.Raw.workspace.root) -BasePath $config.RepoRoot
            $logs = Resolve-XboxOSPath -Path ([string]$config.Raw.workspace.logs) -BasePath $config.RepoRoot
            $output = Resolve-XboxOSPath -Path ([string]$config.Raw.workspace.output) -BasePath $config.RepoRoot

            $root | Should -Be (Get-XboxOSCanonicalPath -Path 'C:\XboxOS\Work')
            $logs | Should -Be (Get-XboxOSCanonicalPath -Path 'C:\XboxOS\Logs')
            $output | Should -Be (Get-XboxOSCanonicalPath -Path 'C:\XboxOS\Output')

            Push-Location $env:TEMP
            try {
                $root2 = Resolve-XboxOSPath -Path ([string]$config.Raw.workspace.root) -BasePath $config.RepoRoot
                $root2 | Should -Be $root
            }
            finally {
                Pop-Location
            }
        }
    }
}
