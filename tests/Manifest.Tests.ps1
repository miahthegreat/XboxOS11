#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'XboxOS11 manifests' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        $module = Join-Path $repoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1'
        Import-Module $module -Force
        $script:RepoRoot = $repoRoot.Path
    }

    It 'build.json contains required fields' {
        $config = Get-XboxOSBuildConfiguration -Path (Join-Path $script:RepoRoot 'config\build.json')
        $schema = Test-XboxOSManifestSchema -Configuration $config.Raw -ManifestType build
        $schema.Valid | Should -BeTrue
        $config.Raw.target.edition | Should -Not -BeNullOrEmpty
        $config.Raw.target.architecture | Should -Be 'amd64'
    }

    It 'remove-apps.json validates and lists candidates' {
        $manifest = Import-XboxOSManifest -Path (Join-Path $script:RepoRoot 'config\remove-apps.json')
        $schema = Test-XboxOSManifestSchema -Configuration $manifest -ManifestType 'remove-apps'
        $schema.Valid | Should -BeTrue
        @($manifest.candidates).Count | Should -BeGreaterThan 0
    }

    It 'disable-features.json validates' {
        $manifest = Import-XboxOSManifest -Path (Join-Path $script:RepoRoot 'config\disable-features.json')
        $schema = Test-XboxOSManifestSchema -Configuration $manifest -ManifestType 'disable-features'
        $schema.Valid | Should -BeTrue
        $manifest.removePayload | Should -BeFalse
    }

    It 'compatibility.json protects Store and Xbox patterns' {
        $manifest = Import-XboxOSManifest -Path (Join-Path $script:RepoRoot 'config\compatibility.json')
        $schema = Test-XboxOSManifestSchema -Configuration $manifest -ManifestType compatibility
        $schema.Valid | Should -BeTrue
        $patterns = Get-XboxOSProtectedAppxPatterns -CompatibilityManifest $manifest
        ($patterns -contains 'Microsoft.WindowsStore*') | Should -BeTrue
        ($patterns -contains 'Microsoft.Xbox*') | Should -BeTrue
        ($patterns -contains 'Microsoft.GamingApp*') | Should -BeTrue
    }

    It 'services.json does not apply during image build in M1' {
        $manifest = Import-XboxOSManifest -Path (Join-Path $script:RepoRoot 'config\services.json')
        $manifest.applyDuringImageBuild | Should -BeFalse
    }

    It 'rejects incomplete build configuration' {
        $bad = [pscustomobject]@{ project = 'x' }
        $schema = Test-XboxOSManifestSchema -Configuration $bad -ManifestType build
        $schema.Valid | Should -BeFalse
        $schema.Errors.Count | Should -BeGreaterThan 0
    }
}
