#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'XboxOS11 DISM compatibility helpers' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        Import-Module (Join-Path $repoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force
        $script:RepoRoot = $repoRoot.Path
        $script:Fixtures = Join-Path $script:RepoRoot 'tests\Fixtures'
        $script:TempRoot = Join-Path $env:TEMP ("XboxOS11-dism-compat-tests-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'parses DISM version from /English /? banner output' {
        $lines = Get-Content -LiteralPath (Join-Path $script:Fixtures 'dism-help-version.txt')
        $version = Get-XboxOSDismVersionFromOutput -Output $lines -ExitCode 0
        $version | Should -Be '10.0.26100.8972'
    }

    It 'fails safely when DISM version output is malformed' {
        $lines = Get-Content -LiteralPath (Join-Path $script:Fixtures 'dism-help-version-malformed.txt')
        {
            Get-XboxOSDismVersionFromOutput -Output $lines -ExitCode 0
        } | Should -Throw -ExpectedMessage '*could not be reliably determined*'
    }

    It 'fails safely when DISM version probe returns a nonzero exit code' {
        $lines = @(
            'Error: 87'
            'The requested DISM option is unknown.'
        )
        {
            Get-XboxOSDismVersionFromOutput -Output $lines -ExitCode 87
        } | Should -Throw -ExpectedMessage '*exit code 87*'
    }

    It 'writes a failed status marker that cannot be mistaken for success' {
        $statusPath = Join-Path $script:TempRoot 'DISM-Compatibility-unit.status'
        $legacyDone = Join-Path $script:TempRoot 'DISM-Compatibility-unit.done'
        'success=True' | Set-Content -LiteralPath $legacyDone -Encoding UTF8

        $marker = Write-XboxOSCompatTestStatusMarker -StatusPath $statusPath -Success:$false -ExitCode 1 -Fields @{
            cleanupOk = $true
            report    = 'C:\XboxOS\Logs\example.md'
        }

        Test-Path -LiteralPath $statusPath | Should -BeTrue
        Test-Path -LiteralPath $marker.OutcomePath | Should -BeTrue
        $marker.OutcomePath | Should -Match '\.failed$'
        Test-Path -LiteralPath (Join-Path $script:TempRoot 'DISM-Compatibility-unit.succeeded') | Should -BeFalse
        Test-Path -LiteralPath $legacyDone | Should -BeFalse

        $statusText = Get-Content -LiteralPath $statusPath -Raw
        $statusText | Should -Match 'success=False'
        $statusText | Should -Match 'outcome=Failed'
        $statusText | Should -Match 'exitCode=1'
        $statusText | Should -Not -Match 'success=True'
    }

    It 'writes an exclusive succeeded marker on success' {
        $statusPath = Join-Path $script:TempRoot 'DISM-Compatibility-ok.status'
        $marker = Write-XboxOSCompatTestStatusMarker -StatusPath $statusPath -Success:$true -ExitCode 0 -Fields @{
            cleanupOk = $true
        }

        $marker.OutcomePath | Should -Match '\.succeeded$'
        Test-Path -LiteralPath (Join-Path $script:TempRoot 'DISM-Compatibility-ok.failed') | Should -BeFalse
        (Get-Content -LiteralPath $statusPath -Raw) | Should -Match 'success=True'
        (Get-Content -LiteralPath $statusPath -Raw) | Should -Match 'outcome=Succeeded'
    }

    It 'does not invoke the unsupported Get-DismVersion switch in scripts or modules' {
        $roots = @(
            (Join-Path $script:RepoRoot 'scripts')
            (Join-Path $script:RepoRoot 'modules')
        )
        $hits = @(
            foreach ($root in $roots) {
                Get-ChildItem -LiteralPath $root -Recurse -Include *.ps1, *.psm1 -File |
                    Select-String -Pattern '/Get-DismVersion' -SimpleMatch
            }
        )
        $hits.Count | Should -Be 0
    }

    It 'compatibility script probes DISM version via /English /?' {
        $scriptPath = Join-Path $script:RepoRoot 'scripts\Test-DismCompatibility.ps1'
        $text = Get-Content -LiteralPath $scriptPath -Raw
        $text.Contains("@('/English', '/?')") | Should -BeTrue
        $text.Contains('Get-XboxOSDismVersionFromOutput') | Should -BeTrue
        $text.Contains('Write-XboxOSCompatTestStatusMarker') | Should -BeTrue
        $text.Contains('/Get-DismVersion') | Should -BeFalse
    }
}
