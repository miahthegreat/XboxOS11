#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'XboxOS11 Milestone 10 release engineering and recovery' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        Import-Module (Join-Path $repoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force
        $script:RepoRoot = $repoRoot.Path
        $script:TempRoot = Join-Path $env:TEMP ('XboxOS11-m10-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
    }

    AfterAll {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'versioning' {
        It 'keeps every version source in agreement with VERSION' {
            $check = Test-XboxOSReleaseVersionConsistency -RepoRoot $script:RepoRoot
            $check.consistent | Should -BeTrue -Because ($check.errors -join '; ')
            $check.version | Should -Match '^\d+\.\d+\.\d+$'
            (Import-PowerShellDataFile (Join-Path $script:RepoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1')).ModuleVersion | Should -Be $check.version
        }

        It 'detects drift between VERSION and the module manifest' {
            $fake = Join-Path $script:TempRoot 'fake-root'
            New-Item -ItemType Directory -Path (Join-Path $fake 'modules\XboxOS.Build') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $fake 'VERSION') -Value '9.9.9'
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Destination (Join-Path $fake 'modules\XboxOS.Build\XboxOS.Build.psd1')
            $check = Test-XboxOSReleaseVersionConsistency -RepoRoot $fake
            $check.consistent | Should -BeFalse
            ($check.errors -join ';') | Should -Match "ModuleVersion"
        }

        It 'has a CHANGELOG entry for the current version' {
            $v = Get-XboxOSToolkitVersion -RepoRoot $script:RepoRoot
            (Get-Content -LiteralPath (Join-Path $script:RepoRoot 'CHANGELOG.md') -Raw) | Should -Match ([regex]::Escape("## [$v]"))
        }
    }

    Context 'packaging' {
        It 'produces a clean toolkit zip with checksums and a manifest' {
            $out = Join-Path $script:TempRoot 'release'
            $result = & (Join-Path $script:RepoRoot 'scripts\New-XboxOSRelease.ps1') -OutputDirectory $out -SkipAppBuild -AllowDirtyTree 6>$null
            $version = Get-XboxOSToolkitVersion -RepoRoot $script:RepoRoot
            $zip = Join-Path $result.Directory ("XboxOS11-Toolkit-{0}.zip" -f $version)
            Test-Path -LiteralPath $zip | Should -BeTrue

            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
            try { $entries = @($archive.Entries | ForEach-Object { $_.FullName -replace '\\', '/' }) } finally { $archive.Dispose() }
            foreach ($required in @('VERSION', 'LICENSE', 'README.md', 'CHANGELOG.md', 'modules/XboxOS.Build/XboxOS.Build.psd1',
                    'scripts/Invoke-XboxOSBuild.ps1', 'scripts/Invoke-XboxOSBuilderApi.ps1', 'config/presets/gaming-balanced.json',
                    'config/gaming-tweaks.json', 'postinstall/Restore-XboxOS11Components.ps1', 'docs/recovery.md')) {
                $entries | Should -Contain $required
            }
            foreach ($forbidden in @('^tests/', '^\.github/', '^automation/', '^src/', '^artifacts/', '\.pem$', '\.iso$', '\.wim$')) {
                @($entries | Where-Object { $_ -match $forbidden }).Count | Should -Be 0 -Because $forbidden
            }

            $sums = Get-Content -LiteralPath (Join-Path $result.Directory 'SHA256SUMS.txt')
            $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
            $sums | Should -Contain ("{0}  {1}" -f $hash, (Split-Path -Leaf $zip))
            $manifest = Get-Content -LiteralPath $result.Manifest -Raw | ConvertFrom-Json
            $manifest.schemaVersion | Should -Be 'xboxos-release-manifest-v1'
            $manifest.version | Should -Be $version
            $manifest.artifacts[0].sha256 | Should -Be $hash
            Test-Path -LiteralPath (Join-Path $result.Directory '_staging') | Should -BeFalse
        }

        It 'refuses to write a release inside the repository' {
            { & (Join-Path $script:RepoRoot 'scripts\New-XboxOSRelease.ps1') -OutputDirectory (Join-Path $script:RepoRoot 'artifacts\release') -SkipAppBuild -AllowDirtyTree 6>$null } |
                Should -Throw '*outside the repository*'
        }
    }

    Context 'recovery on the installed PC' {
        BeforeAll {
            $script:RecordDir = Join-Path $script:TempRoot 'record'
            New-Item -ItemType Directory -Path $script:RecordDir -Force | Out-Null
            $recoveryProfile = New-XboxOSBuildProfile -Name 'Recovery Rig' -PresetId gaming-balanced
            $record = New-XboxOSBuildRecord -BuildProfile $recoveryProfile -ProfileHash (Get-XboxOSBuildProfileHash -BuildProfile $recoveryProfile)
            $script:RecordPath = Join-Path $script:RecordDir 'build-record.json'
            ($record | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $script:RecordPath
            $script:Restore = Join-Path $script:RepoRoot 'postinstall\Restore-XboxOS11Components.ps1'
        }

        It 'records what the build changed' {
            $r = Get-Content -LiteralPath $script:RecordPath -Raw | ConvertFrom-Json
            @($r.removedApps | ForEach-Object { $_.id }) | Should -Contain 'Clipchamp'
            @($r.disabledFeatures | ForEach-Object { $_.featureNames } ) | Should -Contain 'SMB1Protocol'
            $r.postInstall.optimizations | Should -Contain 'WindowedGameOptimizations'
        }

        It 'lists Store reinstall links for removed apps without installing anything' {
            $res = & $script:Restore -Apps -RecordPath $script:RecordPath -PassThru 6>$null
            @($res | Where-Object { $_.Area -eq 'App' }).Count | Should -Be 7
            @($res | ForEach-Object { $_.Status } | Select-Object -Unique) | Should -Be @('Listed')
            @($res)[0].Message | Should -Match '^Reinstall from the Microsoft Store: ms-windows-store://search/\?query='
        }

        It 're-enables disabled features only with administrator rights' {
            Mock Get-WindowsOptionalFeature { [pscustomobject]@{ FeatureName = $FeatureName; State = 'Disabled' } }
            Mock Enable-WindowsOptionalFeature { [pscustomobject]@{ RestartNeeded = $false } }
            $res = & $script:Restore -Features -RecordPath $script:RecordPath -PassThru -WhatIf 6>$null
            $features = @($res | Where-Object { $_.Area -eq 'Feature' })
            $features.Count | Should -Be 6
            if (Test-XboxOSAdministrator) {
                @($features | ForEach-Object { $_.Status } | Select-Object -Unique) | Should -Be @('WhatIf')
            }
            else {
                @($features | ForEach-Object { $_.Status } | Select-Object -Unique) | Should -Be @('SkippedRequiresAdministrator')
            }
            Should -Invoke Enable-WindowsOptionalFeature -Times 0
        }

        It 're-adds removed capabilities only with administrator rights and never without -WhatIf consent' {
            $tiny = New-XboxOSBuildProfile -Name 'Tiny Rig' -PresetId gaming-tiny
            $tinyRecordPath = Join-Path $script:RecordDir 'build-record-tiny.json'
            ((New-XboxOSBuildRecord -BuildProfile $tiny -ProfileHash (Get-XboxOSBuildProfileHash -BuildProfile $tiny)) | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $tinyRecordPath
            Mock Get-WindowsCapability {
                @('App.StepsRecorder~~~~0.0.1.0', 'MathRecognizer~~~~0.0.1.0', 'Browser.InternetExplorer~~~~0.0.11.0', 'Microsoft.Windows.PowerShell.ISE~~~~0.0.1.0',
                    'Microsoft.Windows.WordPad~~~~0.0.1.0', 'Print.Fax.Scan~~~~0.0.1.0', 'App.Support.QuickAssist~~~~0.0.1.0', 'Microsoft.Wallpapers.Extended~~~~0.0.1.0') |
                    ForEach-Object { [pscustomobject]@{ Name = $_; State = 'NotPresent' } }
            }
            Mock Add-WindowsCapability { }
            $res = & $script:Restore -Capabilities -RecordPath $tinyRecordPath -PassThru -WhatIf 6>$null
            $caps = @($res | Where-Object { $_.Area -eq 'Capability' })
            $caps.Count | Should -Be 8
            $expected = if (Test-XboxOSAdministrator) { 'WhatIf' } else { 'SkippedRequiresAdministrator' }
            @($caps | ForEach-Object { $_.Status } | Select-Object -Unique) | Should -Be @($expected)
            Should -Invoke Add-WindowsCapability -Times 0
        }

        It 'reports nothing to restore when no gaming changes were recorded' {
            $res = & $script:Restore -GamingSettings -RecordPath $script:RecordPath -StatePath (Join-Path $script:TempRoot 'no-state.json') -PassThru 6>$null
            @($res)[0].Status | Should -Be 'NothingToRestore'
        }

        It 'fails clearly without a build record' {
            { & $script:Restore -RecordPath (Join-Path $script:TempRoot 'missing.json') 6>$null } | Should -Throw '*No XboxOS11 build record*'
        }
    }
}
