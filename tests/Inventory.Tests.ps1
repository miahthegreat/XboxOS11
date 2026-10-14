#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'XboxOS11 DISM inventory parsing and reports' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        Import-Module (Join-Path $repoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force
        $script:RepoRoot = $repoRoot.Path
        $script:Fixtures = Join-Path $script:RepoRoot 'tests\Fixtures'
    }

    It 'parses complete package inventory with flat identities and state counts' {
        $lines = Get-Content -LiteralPath (Join-Path $script:Fixtures 'dism-get-packages-26300.9457.txt')
        $packages = @(ConvertFrom-XboxOSDismPackageListOutput -Output $lines)
        $packages.Count | Should -Be 146
        $packages[0].Identity | Should -BeOfType ([string])
        @($packages | Where-Object State -eq 'Installed').Count | Should -BeGreaterThan 0
        @($packages | Where-Object State -eq 'Staged').Count | Should -BeGreaterThan 0

        $sample = [string[]]@($packages | Select-Object -First 50 | ForEach-Object { $_.Identity })
        $sample.Count | Should -Be 50
        $sample[0] | Should -BeOfType ([string])
        (@($sample) | ConvertTo-Json -Compress) | Should -Not -Match '\[\['
    }

    It 'parses complete AppX inventory as flat PackageName values' {
        $lines = Get-Content -LiteralPath (Join-Path $script:Fixtures 'dism-get-appx-26300.9457.txt')
        $appx = @(ConvertFrom-XboxOSDismProvisionedAppxListOutput -Output $lines)
        $appx.Count | Should -Be 47
        $names = [string[]]@($appx | ForEach-Object { $_.PackageName })
        $names.Count | Should -Be 47
        $names[0] | Should -Match 'Clipchamp\.Clipchamp'
        (@($names) | ConvertTo-Json -Compress) | Should -Not -Match '\[\['
    }

    It 'parses complete feature inventory and accounts for every DISM state' {
        $lines = Get-Content -LiteralPath (Join-Path $script:Fixtures 'dism-get-features-26300.9457.txt')
        $features = @(ConvertFrom-XboxOSDismFeatureListOutput -Output $lines)
        $features.Count | Should -Be 136
        $summary = Get-XboxOSFeatureStateSummary -Features $features
        $summary.Complete | Should -BeTrue
        $summary.Accounted | Should -Be 136
        $summary.ByState.Enabled | Should -Be 13
        $summary.ByState.Disabled | Should -Be 122
        $summary.ByState.'Disabled with Payload Removed' | Should -Be 1
        (([int]$summary.ByState.Enabled) + ([int]$summary.ByState.Disabled) + ([int]$summary.ByState.'Disabled with Payload Removed')) |
            Should -Be 136
        @($features | Where-Object { $_.Name -eq 'NetFx3' -and $_.State -eq 'Disabled with Payload Removed' }).Count |
            Should -Be 1
        $sample = [string[]]@(
            $features | Select-Object -First 25 | ForEach-Object { '{0} ({1})' -f $_.Name, $_.State }
        )
        $md = ($sample -join [Environment]::NewLine)
        $md | Should -Not -Match 'System\.String\[\]'
        $md | Should -Match 'Printing-XPSServices-Features \(Disabled\)'
    }

    It 'Get-XboxOSDismListedValues returns a flat string array (no unary-comma nesting)' {
        $lines = @(
            'Package Identity : Contoso.One'
            'State : Installed'
            'Package Identity : Contoso.Two'
            'State : Staged'
        )
        $values = @(Get-XboxOSDismListedValues -Output $lines -Label 'Package Identity')
        $values.Count | Should -Be 2
        $values[0] | Should -Be 'Contoso.One'
        $values[1] | Should -Be 'Contoso.Two'
    }

    It 'formats markdown inventory samples without System.String[]' {
        $items = @('Alpha.Package', 'Beta.Package', 'Gamma.Package')
        $lines = @(Format-XboxOSInventorySampleLines -Items $items -Take 25)
        $lines.Count | Should -Be 3
        ($lines -join "`n") | Should -Be "Alpha.Package`nBeta.Package`nGamma.Package"
    }

    It 'builds a compatibility matrix with protected and eligible classifications' {
        $appxLines = Get-Content -LiteralPath (Join-Path $script:Fixtures 'dism-get-appx-26300.9457.txt')
        $featLines = Get-Content -LiteralPath (Join-Path $script:Fixtures 'dism-get-features-26300.9457.txt')
        $appx = @(ConvertFrom-XboxOSDismProvisionedAppxListOutput -Output $appxLines | ForEach-Object { $_.PackageName })
        $features = @(ConvertFrom-XboxOSDismFeatureListOutput -Output $featLines)
        $matrix = New-XboxOSCompatibilityMatrix `
            -AppxPackages $appx `
            -Features $features `
            -RemoveAppsManifest (Import-XboxOSManifest -Path (Join-Path $script:RepoRoot 'config\remove-apps.json')) `
            -DisableFeaturesManifest (Import-XboxOSManifest -Path (Join-Path $script:RepoRoot 'config\disable-features.json')) `
            -CompatibilityManifest (Import-XboxOSManifest -Path (Join-Path $script:RepoRoot 'config\compatibility.json'))

        $matrix.summary.conflicting | Should -Be 0
        $matrix.summary.alreadyDisabled | Should -Be 4
        @($matrix.rows | Where-Object { $_.Kind -eq 'Feature' -and $_.Status -eq 'Eligible' }).Count |
            Should -Be 1
        @($matrix.rows | Where-Object { $_.Feature -eq 'WorkFolders-Client' -and $_.Status -eq 'Eligible' }).Count |
            Should -Be 1
        @($matrix.rows | Where-Object { $_.Feature -eq 'Printing-XPSServices-Features' -and $_.Status -eq 'AlreadyDisabled' }).Count |
            Should -Be 1
        @($matrix.rows | Where-Object { $_.Feature -like 'SMB1Protocol*' -and $_.Status -eq 'AlreadyDisabled' }).Count |
            Should -Be 3
        @($matrix.rows | Where-Object { $_.Candidate -eq 'XboxTCUI' -and $_.Status -eq 'Protected' }).Count | Should -BeGreaterThan 0
        $allowed = @('Present', 'Absent', 'Protected', 'Eligible', 'AlreadyDisabled', 'Ambiguous', 'Conflicting')
        @($matrix.rows | Where-Object { $_.Status -in $allowed }).Count | Should -Be $matrix.rows.Count
    }
}
