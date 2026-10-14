#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'XboxOS11 exact source-image index selection' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        Import-Module (Join-Path $repoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force
        $script:Fixtures = Join-Path $repoRoot.Path 'tests\Fixtures'
        $script:ExpectedName = 'Windows 11 Pro'
    }

    It 'selects Windows 11 Pro when it appears at index 6' {
        $lines = Get-Content -LiteralPath (Join-Path $script:Fixtures 'dism-imageinfo-pro-index6.txt')
        $images = @(ConvertFrom-XboxOSDismImageInfoOutput -Output $lines)
        $selected = Resolve-XboxOSExactImageIndex -Images $images -ExactName $script:ExpectedName
        $selected.Index | Should -Be 6
        $selected.Name | Should -Be 'Windows 11 Pro'
        $selected.MatchCount | Should -Be 1
    }

    It 'selects Windows 11 Pro when it appears at another index' {
        $lines = Get-Content -LiteralPath (Join-Path $script:Fixtures 'dism-imageinfo-pro-index4.txt')
        $images = @(ConvertFrom-XboxOSDismImageInfoOutput -Output $lines)
        $selected = Resolve-XboxOSExactImageIndex -Images $images -ExactName $script:ExpectedName
        $selected.Index | Should -Be 4
        $selected.Name | Should -Be 'Windows 11 Pro'
        $selected.Index | Should -Not -Be 6
    }

    It 'fails safely when Windows 11 Pro is missing' {
        $lines = Get-Content -LiteralPath (Join-Path $script:Fixtures 'dism-imageinfo-missing-pro.txt')
        $images = @(ConvertFrom-XboxOSDismImageInfoOutput -Output $lines)
        {
            Resolve-XboxOSExactImageIndex -Images $images -ExactName $script:ExpectedName
        } | Should -Throw -ExpectedMessage '*was not found*'
    }

    It 'fails safely when Windows 11 Pro is ambiguous' {
        $lines = Get-Content -LiteralPath (Join-Path $script:Fixtures 'dism-imageinfo-ambiguous-pro.txt')
        $images = @(ConvertFrom-XboxOSDismImageInfoOutput -Output $lines)
        {
            Resolve-XboxOSExactImageIndex -Images $images -ExactName $script:ExpectedName
        } | Should -Throw -ExpectedMessage '*ambiguous*'
    }

    It 'fails safely on malformed DISM output' {
        $lines = Get-Content -LiteralPath (Join-Path $script:Fixtures 'dism-imageinfo-malformed.txt')
        {
            ConvertFrom-XboxOSDismImageInfoOutput -Output $lines
        } | Should -Throw -ExpectedMessage '*could not be reliably parsed*'
    }

    It 'rejects Index entries missing Name metadata' {
        $lines = @(
            'Index : 1'
            'Description : Windows 11 Home'
            'Index : 2'
            'Name : Windows 11 Pro'
        )
        {
            ConvertFrom-XboxOSDismImageInfoOutput -Output $lines
        } | Should -Throw -ExpectedMessage '*missing a Name*'
    }

    It 'matches edition names case-insensitively but still requires an exact string' {
        $images = @(
            [pscustomobject]@{ Index = 3; Name = 'windows 11 pro' }
            [pscustomobject]@{ Index = 4; Name = 'Windows 11 Pro N' }
        )
        $selected = Resolve-XboxOSExactImageIndex -Images $images -ExactName 'Windows 11 Pro'
        $selected.Index | Should -Be 3
        {
            Resolve-XboxOSExactImageIndex -Images $images -ExactName 'Windows 11 Pro Education'
        } | Should -Throw -ExpectedMessage '*was not found*'
    }
}
