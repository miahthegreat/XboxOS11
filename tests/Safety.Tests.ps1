#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'XboxOS11 safety controls' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        Import-Module (Join-Path $repoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force
        $script:RepoRoot = $repoRoot.Path
        $script:Compatibility = Import-XboxOSManifest -Path (Join-Path $script:RepoRoot 'config\compatibility.json')
        $script:Protected = Get-XboxOSProtectedAppxPatterns -CompatibilityManifest $script:Compatibility
        $script:Packages = Get-Content (Join-Path $script:RepoRoot 'tests\Fixtures\sample-appx-packages.txt')
    }

    It 'marks Xbox and Store packages as protected' {
        Test-XboxOSPackageProtected -PackageName 'Microsoft.WindowsStore_22405.1401.0.0_neutral_~_8wekyb3d8bbwe' -ProtectedPatterns $script:Protected | Should -BeTrue
        Test-XboxOSPackageProtected -PackageName 'Microsoft.Xbox.TCUI_1.24.10001.0_neutral_~_8wekyb3d8bbwe' -ProtectedPatterns $script:Protected | Should -BeTrue
        Test-XboxOSPackageProtected -PackageName 'Microsoft.GamingApp_2405.1001.0.0_x64__8wekyb3d8bbwe' -ProtectedPatterns $script:Protected | Should -BeTrue
    }

    It 'does not protect ordinary removable candidates' {
        Test-XboxOSPackageProtected -PackageName 'Microsoft.BingWeather_4.53.0.0_neutral_~_8wekyb3d8bbwe' -ProtectedPatterns $script:Protected | Should -BeFalse
        Test-XboxOSPackageProtected -PackageName 'Clipchamp.Clipchamp_2.2.0.0_neutral_~_yxz26nhyzhsrt' -ProtectedPatterns $script:Protected | Should -BeFalse
    }

    It 'rejects ambiguous package matches when configured' {
        {
            Resolve-XboxOSPackageMatches -Patterns @('Microsoft.*') -AvailablePackages $script:Packages -RejectAmbiguous
        } | Should -Throw -ExpectedMessage '*Ambiguous*'
    }

    It 'resolves a single exact/prefix package match' {
        $resolved = @(Resolve-XboxOSPackageMatches -Patterns @('Microsoft.BingWeather*') -AvailablePackages $script:Packages -RejectAmbiguous)
        $resolved.Count | Should -Be 1
        $resolved[0] | Should -Match 'BingWeather'
    }

    It 'returns absent for unknown package identities' {
        $resolved = @(Resolve-XboxOSPackageMatches -Patterns @('Contoso.NotARealPackage*') -AvailablePackages $script:Packages -RejectAmbiguous)
        $resolved.Count | Should -Be 0
    }

    It 'refuses unsafe workspace roots' {
        {
            Assert-XboxOSBuildSafety -WorkspaceRoot $env:SystemRoot -RepoRoot $script:RepoRoot
        } | Should -Throw
        {
            Assert-XboxOSBuildSafety -WorkspaceRoot $script:RepoRoot -RepoRoot $script:RepoRoot
        } | Should -Throw
    }

    It 'accepts isolated artifact workspace' {
        $ws = Join-Path $script:RepoRoot 'artifacts\workspace\test-safety'
        Assert-XboxOSBuildSafety -WorkspaceRoot $ws -RepoRoot $script:RepoRoot | Should -BeTrue
    }

    It 'rejects invalid driver INF fixtures' {
        $dir = Join-Path $script:RepoRoot 'tests\Fixtures'
        $manifest = Import-XboxOSManifest -Path (Join-Path $script:RepoRoot 'config\drivers.json')
        $packages = Find-XboxOSDriverPackages -DriverDirectory $dir -DriversManifest $manifest
        $invalid = $packages | Where-Object { $_.Name -eq 'invalid-driver.inf' }
        $invalid | Should -Not -BeNullOrEmpty
        $invalid.ValidInf | Should -BeFalse
    }

    It 'orders updates with servicing stack before cumulative' {
        $packages = @(
            [pscustomobject]@{ Name = 'windows11.0-kb5000002-x64-LCU.msu'; Kind = 'Cumulative' }
            [pscustomobject]@{ Name = 'windows11.0-kb5000001-x64-SSU.cab'; Kind = 'ServicingStack' }
            [pscustomobject]@{ Name = 'windows11.0-kb5000003-x64-DotNet.cab'; Kind = 'DotNet' }
        )
        $ordered = Get-XboxOSOrderedUpdatePackages -Packages $packages
        $ordered[0].Kind | Should -Be 'ServicingStack'
        $ordered[1].Kind | Should -Be 'Cumulative'
        $ordered[2].Kind | Should -Be 'DotNet'
    }

    It 'DryRun guard reports skip without throwing' {
        Test-XboxOSDryRunGuard -DryRun -Action 'unit-test' | Should -BeTrue
        Test-XboxOSDryRunGuard -Action 'unit-test' | Should -BeFalse
    }

    It 'protects NetFx features from disable helper' {
        Test-XboxOSFeatureProtected -FeatureName 'NetFx3' | Should -BeTrue
        Test-XboxOSFeatureProtected -FeatureName 'SMB1Protocol' -NeverDisable @('NetFx*') | Should -BeFalse
    }
}
