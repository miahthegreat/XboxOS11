#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'XboxOS11 build helpers' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        Import-Module (Join-Path $repoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force
        $script:RepoRoot = $repoRoot.Path
        $script:ConfigPath = Join-Path $script:RepoRoot 'config\build.json'
    }

    It 'creates an isolated dry-run build context' {
        $iso = Join-Path $script:RepoRoot 'tests\Fixtures\missing-source.iso'
        $ctx = New-XboxOSBuildContext -ConfigurationPath $script:ConfigPath -SourceISO $iso -DryRun
        $ctx.DryRun | Should -BeTrue
        $ctx.BuildId | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $ctx.Paths.Workspace | Should -BeTrue
        Test-Path -LiteralPath $ctx.Paths.Reports | Should -BeTrue
        Test-Path -LiteralPath $ctx.LogFile | Should -BeTrue
        Assert-XboxOSBuildSafety -WorkspaceRoot $ctx.Paths.Workspace -RepoRoot $script:RepoRoot | Should -BeTrue
    }

    It 'writes a build report with phase results' {
        $iso = Join-Path $script:RepoRoot 'tests\Fixtures\missing-source.iso'
        $ctx = New-XboxOSBuildContext -ConfigurationPath $script:ConfigPath -SourceISO $iso -DryRun
        $ctx.PhaseResults.Add([pscustomobject]@{ Name = 'UnitTest'; Status = 'Succeeded'; Message = 'ok' }) | Out-Null
        $ctx.Success = $true
        $report = Save-XboxOSBuildReport -Context $ctx
        Test-Path -LiteralPath $report.Json | Should -BeTrue
        Test-Path -LiteralPath $report.Text | Should -BeTrue
        $json = Get-Content -LiteralPath $report.Json -Raw | ConvertFrom-Json
        $json.buildId | Should -Be $ctx.BuildId
        $json.phases.Count | Should -BeGreaterThan 0
    }

    It 'supports architecture validation' {
        Test-XboxOSArchitectureSupported -Architecture 'amd64' | Should -BeTrue
        Test-XboxOSArchitectureSupported -Architecture 'x64' | Should -BeTrue
        Test-XboxOSArchitectureSupported -Architecture 'mips' | Should -BeFalse
    }

    It 'constructs ISO boot data paths from a fake source tree' {
        $tree = Join-Path $script:RepoRoot 'artifacts\temp\fake-iso-tree'
        $boot = Join-Path $tree 'boot'
        $efi = Join-Path $tree 'efi\microsoft\boot'
        New-Item -ItemType Directory -Path $boot -Force | Out-Null
        New-Item -ItemType Directory -Path $efi -Force | Out-Null
        Set-Content (Join-Path $boot 'etfsboot.com') -Value 'x'
        Set-Content (Join-Path $efi 'efisys.bin') -Value 'x'
        $bootData = New-XboxOSIsoBootData -SourceTree $tree
        $bootData | Should -Match 'etfsboot\.com'
        $bootData | Should -Match 'efisys\.bin'
    }

    It 'Invoke-XboxOSDism dry-run does not execute DISM mutations' {
        $dism = Find-XboxOSDism
        if (-not $dism) {
            Set-ItResult -Skipped -Because 'DISM not available on this host'
            return
        }
        $result = Invoke-XboxOSDism -DismPath $dism -ArgumentList @('/English', '/?') -DryRun
        $result.DryRun | Should -BeTrue
        $result.ExitCode | Should -Be 0
        $result.Command | Should -Match 'dism'
    }

    It 'repository contains required script entry points' {
        $required = @(
            'Build-ISO.ps1'
            'Test-Prerequisites.ps1'
            'Import-Source.ps1'
            'Mount-Image.ps1'
            'Inventory-Image.ps1'
            'Remove-Apps.ps1'
            'Disable-Features.ps1'
            'Add-Updates.ps1'
            'Add-Drivers.ps1'
            'Validate-Image.ps1'
            'Dismount-Image.ps1'
            'Export-ISO.ps1'
            'New-ServicingPlan.ps1'
            'Build-CompatibilityMatrix.ps1'
            'Test-DismCompatibility.ps1'
        )
        foreach ($name in $required) {
            Test-Path (Join-Path $script:RepoRoot "scripts\$name") | Should -BeTrue
        }
    }

    It 'Remove-Apps dry logic plans weather removal and never stages protected packages when inventory is known' {
        $iso = Join-Path $script:RepoRoot 'tests\Fixtures\missing-source.iso'
        $ctx = New-XboxOSBuildContext -ConfigurationPath $script:ConfigPath -SourceISO $iso -DryRun
        $packages = Get-Content (Join-Path $script:RepoRoot 'tests\Fixtures\sample-appx-packages.txt')
        $result = & (Join-Path $script:RepoRoot 'scripts\Remove-Apps.ps1') -BuildContext $ctx -AvailablePackages $packages -InventoryState Available -DryRun
        $planned = @($result.Results | Where-Object { $_.Status -eq 'DryRun' } | ForEach-Object { $_.Package })
        ($planned | Where-Object { $_ -like 'Microsoft.BingWeather*' }).Count | Should -BeGreaterThan 0
        ($planned | Where-Object { $_ -like 'Microsoft.WindowsStore*' }).Count | Should -Be 0
        ($planned | Where-Object { $_ -like 'Microsoft.Xbox*' }).Count | Should -Be 0
        ($planned | Where-Object { $_ -like 'Microsoft.GamingApp*' }).Count | Should -Be 0
        (@($result.Results | ForEach-Object { $_.Status }) -contains 'Removed') | Should -BeFalse
        $result.Success | Should -BeTrue
    }

    It 'build context stores logs and workspace under C:\XboxOS' {
        $iso = Join-Path $script:RepoRoot 'tests\Fixtures\missing-source.iso'
        $ctx = New-XboxOSBuildContext -ConfigurationPath $script:ConfigPath -SourceISO $iso -OutputDirectory 'C:\XboxOS\Output' -DryRun
        $ctx.Paths.Workspace.StartsWith('C:\XboxOS\Work', [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        $ctx.Paths.Logs.StartsWith('C:\XboxOS\Logs', [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        $ctx.Paths.Output.StartsWith('C:\XboxOS\Output', [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        Test-XboxOSPathEqualsOrUnder -Path $ctx.Paths.Workspace -ParentPath $script:RepoRoot | Should -BeFalse
    }

    It 'logs structured JSON lines' {
        $logDir = Join-Path $script:RepoRoot 'artifacts\logs'
        $log = New-XboxOSLogger -LogDirectory $logDir -BuildId 'pester-log' -Level Information
        Write-XboxOSLog -Level Information -Message 'pester-log-line' -Data @{ test = $true }
        (Get-Content -LiteralPath $log -Raw) | Should -Match 'pester-log-line'
        (Get-Content -LiteralPath $log -Raw) | Should -Match '"level":"Information"'
    }
}
