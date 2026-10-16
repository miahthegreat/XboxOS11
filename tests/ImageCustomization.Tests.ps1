#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'XboxOS11 Milestone 11 lean image' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        Import-Module (Join-Path $repoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force
        $script:RepoRoot = $repoRoot.Path
        $script:TempRoot = Join-Path $env:TEMP ('XboxOS11-m11-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        $script:Compat = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'config\compatibility.json') -Raw | ConvertFrom-Json
        $script:Caps = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'config\remove-capabilities.json') -Raw | ConvertFrom-Json
        $script:Apps = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'config\remove-apps.json') -Raw | ConvertFrom-Json

        # Fake reg.exe: records every call; never touches the registry.
        $script:NewFakeReg = {
            param([int[]]$FailOnCall = @(), [switch]$FailUnload, [switch]$QueryMissing)
            $calls = New-Object System.Collections.Generic.List[string]
            $state = @{ n = 0 }
            $sb = {
                param([string[]]$Arguments)
                $state.n++
                $calls.Add(($Arguments -join ' ')) | Out-Null
                $code = 0
                if ($FailOnCall -contains $state.n) { $code = 1 }
                if ($Arguments[0] -eq 'unload' -and $FailUnload) { $code = 1 }
                if ($Arguments[0] -eq 'query' -and $QueryMissing) { $code = 1 }
                @{ ExitCode = $code; Output = @("fake reg $($Arguments[0])") }
            }.GetNewClosure()
            return [pscustomobject]@{ Command = $sb; Calls = $calls }
        }
    }

    AfterAll {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'manifests' {
        It 'adds removal candidates disabled by default and never targets protected apps' {
            $protected = Get-XboxOSProtectedAppxPatterns -CompatibilityManifest $script:Compat
            foreach ($id in @('BingSearch', 'PowerAutomate', 'ToDo', 'FeedbackHub', 'PhoneLink', 'Widgets', 'MailCalendar')) {
                $c = @($script:Apps.candidates | Where-Object { $_.id -eq $id })
                $c.Count | Should -Be 1 -Because $id
                $c[0].enabled | Should -BeFalse -Because "$id must be opt-in through a profile"
                Test-XboxOSAppCandidateProtected -Candidate $c[0] -ProtectedPatterns $protected | Should -BeFalse -Because $id
            }
            @($script:Apps.candidates | ForEach-Object { $_.id } | Select-Object -Unique).Count | Should -Be @($script:Apps.candidates).Count
        }

        It 'keeps Store, Xbox, Gaming Services, and Edge out of every candidate list' {
            $all = (@($script:Apps.candidates | Where-Object { $_.id -ne 'XboxTCUI' } | ForEach-Object { $_.patterns }) + @($script:Caps.candidates | ForEach-Object { $_.patterns })) -join "`n"
            $all | Should -Not -Match '(?i)WindowsStore|StorePurchase|GamingApp|GamingServices|XboxIdentity|XboxGamingOverlay|MicrosoftEdge|WebView|SecHealthUI|DesktopAppInstaller'
        }

        It 'only lists capabilities that are not protected, all disabled by default' {
            foreach ($c in $script:Caps.candidates) {
                $c.enabled | Should -BeFalse -Because $c.id
                Test-XboxOSCapabilityCandidateProtected -Candidate $c -ProtectedPatterns @($script:Compat.protectedCapabilities) | Should -BeFalse -Because $c.id
            }
            Test-XboxOSCapabilityCandidateProtected -Candidate ([pscustomobject]@{ patterns = @('Media.WindowsMediaPlayer~~~~*') }) -ProtectedPatterns @($script:Compat.protectedCapabilities) | Should -BeTrue
        }

        It 'loads the image settings catalog and never touches security, update, or recovery settings' {
            $catalog = Get-XboxOSImageTweakCatalog -Path (Join-Path $script:RepoRoot 'config\image-tweaks.json')
            $ids = @($catalog.tweaks | ForEach-Object { $_.id })
            @($ids | Select-Object -Unique).Count | Should -Be $ids.Count
            $paths = @($catalog.tweaks | ForEach-Object { $_.values } | ForEach-Object { "$($_.hive):$($_.path)\$($_.name)" }) -join "`n"
            $paths | Should -Not -Match '(?i)Defender|WindowsUpdate|\\WU\\|SmartScreen|WinRE|Recovery|DataCollection|LabConfig|Lsa|DeviceGuard|Firewall'
            foreach ($t in $catalog.tweaks) { $t.settingsPage | Should -Not -BeNullOrEmpty -Because $t.id }
        }

        It 'rejects malformed image settings catalogs' {
            $bad = Join-Path $script:TempRoot 'bad-tweaks.json'
            ([ordered]@{ schemaVersion = 'xboxos-image-tweaks-v1'; tweaks = @([ordered]@{ id = 'x'; values = @([ordered]@{ hive = 'SAM'; path = 'a'; name = 'b'; action = 'Set'; type = 'DWord'; data = 1 }) }) } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $bad
            { Get-XboxOSImageTweakCatalog -Path $bad } | Should -Throw '*unknown hive*'
            ([ordered]@{ schemaVersion = 'xboxos-image-tweaks-v1'; tweaks = @([ordered]@{ id = 'x'; values = @([ordered]@{ hive = 'Software'; path = '..\x'; name = 'b'; action = 'Set'; type = 'DWord'; data = 1 }) }) } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $bad
            { Get-XboxOSImageTweakCatalog -Path $bad } | Should -Throw '*unsafe*'
        }
    }

    Context 'capabilities' {
        It 'parses DISM /Get-Capabilities output' {
            $lines = @(
                'Deployment Image Servicing and Management tool', '',
                'Capability Identity : App.StepsRecorder~~~~0.0.1.0', 'State : Installed', '',
                'Capability Identity : Language.Basic~~~en-US~0.0.1.0', 'State : Installed', '',
                'Capability Identity : MathRecognizer~~~~0.0.1.0', 'State : Not Present'
            )
            $caps = @(ConvertFrom-XboxOSDismCapabilityListOutput -Lines $lines)
            $caps.Count | Should -Be 3
            $caps[0].Identity | Should -Be 'App.StepsRecorder~~~~0.0.1.0'
            $caps[2].State | Should -Be 'Not Present'
        }

        It 'plans capability removal only for enabled, installed, unprotected candidates' {
            $manifest = Join-Path $script:TempRoot 'caps.json'
            $doc = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'config\remove-capabilities.json') -Raw | ConvertFrom-Json
            foreach ($c in $doc.candidates) { $c.enabled = $c.id -in @('StepsRecorder', 'MathRecognizer') }
            ($doc | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $manifest
            $ctx = New-XboxOSBuildContext -ConfigurationPath (Join-Path $script:RepoRoot 'config\build.json') -SourceISO (Join-Path $script:TempRoot 'x.iso') -OutputDirectory (Join-Path $script:TempRoot 'out') -DryRun
            $r = & (Join-Path $script:RepoRoot 'scripts\Remove-Capabilities.ps1') -BuildContext $ctx -ManifestPath $manifest `
                -InstalledCapabilities @('App.StepsRecorder~~~~0.0.1.0', 'Language.Basic~~~en-US~0.0.1.0') -DryRun
            @($r.Results | Where-Object { $_.Candidate -eq 'StepsRecorder' })[0].Status | Should -Be 'DryRun'
            @($r.Results | Where-Object { $_.Candidate -eq 'MathRecognizer' })[0].Status | Should -Be 'Absent'
            @($r.Results | Where-Object { $_.Candidate -eq 'WordPad' })[0].Status | Should -Be 'Skipped'
            $r.Success | Should -BeTrue
        }

        It 'marks capability candidates NotEvaluated without an inventory' {
            $ctx = New-XboxOSBuildContext -ConfigurationPath (Join-Path $script:RepoRoot 'config\build.json') -SourceISO (Join-Path $script:TempRoot 'x.iso') -OutputDirectory (Join-Path $script:TempRoot 'out') -DryRun
            $manifest = Join-Path $script:TempRoot 'caps-all.json'
            $doc = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'config\remove-capabilities.json') -Raw | ConvertFrom-Json
            foreach ($c in $doc.candidates) { $c.enabled = $true }
            ($doc | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $manifest
            $r = & (Join-Path $script:RepoRoot 'scripts\Remove-Capabilities.ps1') -BuildContext $ctx -ManifestPath $manifest -DryRun
            @($r.Results | ForEach-Object { $_.Status } | Select-Object -Unique) | Should -Be @('NotEvaluated')
        }
    }

    Context 'offline image registry settings' {
        BeforeAll {
            $script:SampleTweaks = @(
                [pscustomobject]@{ id = 'A'; values = @(
                        [pscustomobject]@{ hive = 'DefaultUser'; path = 'Software\X'; name = 'V1'; action = 'Set'; type = 'DWord'; data = 0 },
                        [pscustomobject]@{ hive = 'DefaultUser'; path = 'Software\Microsoft\Windows\CurrentVersion\Run'; name = 'OneDriveSetup'; action = 'Delete' }) },
                [pscustomobject]@{ id = 'B'; values = @([pscustomobject]@{ hive = 'Software'; path = 'Policies\Microsoft\Edge'; name = 'HideFirstRunExperience'; action = 'Set'; type = 'DWord'; data = 1 }) }
            )
        }

        It 'loads each hive once under an owned key, writes via reg.exe, and unloads it' {
            $fake = & $script:NewFakeReg
            $r = @(Invoke-XboxOSImageRegistryTweaks -MountDir 'C:\XboxOS\Work\b1\mount' -Tweaks $script:SampleTweaks -RegCommand $fake.Command)
            $calls = @($fake.Calls)
            ($calls | Where-Object { $_ -like 'load *' }).Count | Should -Be 2
            ($calls | Where-Object { $_ -like 'unload *' }).Count | Should -Be 2
            $calls[0] | Should -Match '^load HKLM\\XboxOSImage-DefaultUser-[0-9a-f]{12} C:\\XboxOS\\Work\\b1\\mount\\Users\\Default\\NTUSER\.DAT$'
            @($calls | Where-Object { $_ -match '^add HKLM\\XboxOSImage-DefaultUser-\w+\\Software\\X /v V1 /t REG_DWORD /d 0 /f$' }).Count | Should -Be 1
            ($calls | Where-Object { $_ -match '^delete .*\\Run /v OneDriveSetup /f$' }).Count | Should -Be 1
            ($calls | Where-Object { $_ -match '^load HKLM\\XboxOSImage-Software-\w+ .*\\Windows\\System32\\config\\SOFTWARE$' }).Count | Should -Be 1
            @($r | ForEach-Object { $_.Status }) | Should -Be @('Set', 'Deleted', 'Set')
        }

        It 'reports values that are already absent instead of failing' {
            $fake = & $script:NewFakeReg -QueryMissing
            $r = @(Invoke-XboxOSImageRegistryTweaks -MountDir 'C:\m' -Tweaks @($script:SampleTweaks[0]) -RegCommand $fake.Command)
            @($r | Where-Object { $_.Name -eq 'OneDriveSetup' })[0].Status | Should -Be 'AlreadyAbsent'
            @($fake.Calls | Where-Object { $_ -like 'delete *' }).Count | Should -Be 0
        }

        It 'still unloads the hive when a write fails and reports the failure' {
            $fake = & $script:NewFakeReg -FailOnCall @(2)
            $r = @(Invoke-XboxOSImageRegistryTweaks -MountDir 'C:\m' -Tweaks @($script:SampleTweaks[0]) -RegCommand $fake.Command)
            $r[0].Status | Should -Be 'Failed'
            @($fake.Calls)[-1] | Should -Match '^unload HKLM\\XboxOSImage-DefaultUser-'
        }

        It 'fails closed with RecoveryRequired when a hive cannot be unloaded' {
            $fake = & $script:NewFakeReg -FailUnload
            { Invoke-XboxOSImageRegistryTweaks -MountDir 'C:\m' -Tweaks @($script:SampleTweaks[1]) -RegCommand $fake.Command } | Should -Throw '*RecoveryRequired*'
        }

        It 'makes no registry calls in dry-run mode' {
            $fake = & $script:NewFakeReg
            $r = @(Invoke-XboxOSImageRegistryTweaks -MountDir 'C:\m' -Tweaks $script:SampleTweaks -RegCommand $fake.Command -DryRun)
            @($fake.Calls).Count | Should -Be 0
            @($r | ForEach-Object { $_.Status } | Select-Object -Unique) | Should -Be @('DryRun')
        }

        It 'applies only enabled settings in the phase script and stays dry when the image is not mounted' {
            $manifest = Join-Path $script:TempRoot 'tweaks.json'
            $doc = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'config\image-tweaks.json') -Raw | ConvertFrom-Json
            foreach ($t in $doc.tweaks) { $t | Add-Member -NotePropertyName enabled -NotePropertyValue ($t.id -eq 'EdgeNoFirstRun') -Force }
            ($doc | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $manifest
            $ctx = New-XboxOSBuildContext -ConfigurationPath (Join-Path $script:RepoRoot 'config\build.json') -SourceISO (Join-Path $script:TempRoot 'x.iso') -OutputDirectory (Join-Path $script:TempRoot 'out') -DryRun
            $fake = & $script:NewFakeReg
            $r = & (Join-Path $script:RepoRoot 'scripts\Set-ImageTweaks.ps1') -BuildContext $ctx -ManifestPath $manifest -RegCommand $fake.Command
            @($r.Results).Count | Should -Be 1
            $r.Results[0].Status | Should -Be 'DryRun'
            @($fake.Calls).Count | Should -Be 0
        }
    }

    Context 'offline image version inventory' {
        BeforeAll {
            $script:QueryLines = @(
                '',
                'HKEY_LOCAL_MACHINE\XboxOSInventory-abc\Microsoft\Windows NT\CurrentVersion',
                '    CurrentBuild    REG_SZ    26300',
                '    UBR    REG_DWORD    0x24f1',
                '    EditionID    REG_SZ    Professional',
                '    DisplayVersion    REG_SZ    26H2',
                '    ProductName    REG_SZ    Windows 10 Pro',
                '    EmptyValue    REG_SZ',
                ''
            )
            $script:NewVersionReg = {
                param([switch]$FailUnload, [switch]$FailQuery)
                $calls = New-Object System.Collections.Generic.List[string]
                $lines = $script:QueryLines
                $sb = {
                    param([string[]]$Arguments)
                    $calls.Add($Arguments[0]) | Out-Null
                    switch ($Arguments[0]) {
                        'query' { if ($FailQuery) { @{ ExitCode = 1; Output = @('ERROR') } } else { @{ ExitCode = 0; Output = $lines } } }
                        'unload' { @{ ExitCode = $(if ($FailUnload) { 1 } else { 0 }); Output = @('x') } }
                        default { @{ ExitCode = 0; Output = @('ok') } }
                    }
                }.GetNewClosure()
                [pscustomobject]@{ Command = $sb; Calls = $calls }
            }
        }

        It 'parses reg.exe query output including DWORD hex values and empty data' {
            $v = ConvertFrom-XboxOSRegQueryOutput -Lines $script:QueryLines
            $v['CurrentBuild'] | Should -Be '26300'
            $v['UBR'] | Should -Be 9457
            $v['EditionID'] | Should -Be 'Professional'
            $v.ContainsKey('EmptyValue') | Should -BeTrue
        }

        It 'reads build metadata with reg.exe only and always unloads the hive' {
            $fake = & $script:NewVersionReg
            $r = Read-XboxOSOfflineCurrentVersion -MountDir 'C:\m' -RegCommand $fake.Command
            $r.build | Should -Be '26300.9457'
            $r.displayVersion | Should -Be '26H2'
            $r.editionId | Should -Be 'Professional'
            @($fake.Calls) | Should -Be @('load', 'query', 'unload')
        }

        It 'unloads the hive even when the query fails' {
            $fake = & $script:NewVersionReg -FailQuery
            { Read-XboxOSOfflineCurrentVersion -MountDir 'C:\m' -RegCommand $fake.Command } | Should -Throw '*CurrentVersion*'
            @($fake.Calls)[-1] | Should -Be 'unload'
        }

        It 'fails closed with RecoveryRequired when the hive cannot be unloaded' {
            $fake = & $script:NewVersionReg -FailUnload
            { Read-XboxOSOfflineCurrentVersion -MountDir 'C:\m' -RegCommand $fake.Command } | Should -Throw '*RecoveryRequired*'
        }
    }

    Context 'image size' {
        It 'builds component cleanup arguments with optional ResetBase' {
            (Get-XboxOSComponentCleanupArguments -MountDir 'C:\m') -join ' ' | Should -Be '/Image:C:\m /Cleanup-Image /StartComponentCleanup'
            (Get-XboxOSComponentCleanupArguments -MountDir 'C:\m' -ResetBase) -join ' ' | Should -Be '/Image:C:\m /Cleanup-Image /StartComponentCleanup /ResetBase'
        }

        It 'builds export arguments and pairs compression with the right file type' {
            $a = Get-XboxOSImageExportArguments -SourceImage 'C:\w\install.wim' -DestinationImage 'C:\w\install-final.esd' -Compression Recovery
            $a | Should -Contain '/Compress:recovery'
            $a | Should -Contain '/SourceIndex:1'
            { Get-XboxOSImageExportArguments -SourceImage 'a.wim' -DestinationImage 'b.wim' -Compression Recovery } | Should -Throw
            { Get-XboxOSImageExportArguments -SourceImage 'a.wim' -DestinationImage 'b.esd' -Compression Max } | Should -Throw
        }

        It 'uses the recompressed image when present' {
            $ctx = [pscustomobject]@{ Paths = [pscustomobject]@{ WorkingWim = 'C:\w\install.wim' } }
            Get-XboxOSFinalImagePath -Context $ctx | Should -Be 'C:\w\install.wim'
            $ctx | Add-Member -NotePropertyName FinalImagePath -NotePropertyValue 'C:\w\install-final.esd'
            Get-XboxOSFinalImagePath -Context $ctx | Should -Be 'C:\w\install-final.esd'
        }

        It 'removes every original install image from the ISO tree and nothing else' {
            $tree = Join-Path $script:TempRoot 'isotree'
            New-Item -ItemType Directory -Path (Join-Path $tree 'sources') -Force | Out-Null
            foreach ($f in @('install.esd', 'install.wim', 'install2.swm', 'boot.wim', 'setup.exe', 'installer.dll')) {
                Set-Content -LiteralPath (Join-Path $tree "sources\$f") -Value 'x'
            }
            $removed = @(Clear-XboxOSIsoInstallImages -SourceTree $tree)
            ($removed | Sort-Object) | Should -Be @('install.esd', 'install.wim', 'install2.swm')
            Test-Path -LiteralPath (Join-Path $tree 'sources\boot.wim') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $tree 'sources\installer.dll') | Should -BeTrue
        }

        It 'plans recompression in dry-run mode without touching the image' {
            $cfgPath = Join-Path $script:TempRoot 'build-recompress.json'
            $cfg = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'config\build.json') -Raw | ConvertFrom-Json
            $cfg.image.compression = 'Recovery'
            foreach ($p in @($cfg.paths.PSObject.Properties)) {
                if ([string]$p.Value -like './*') { $p.Value = Join-Path $script:RepoRoot ([string]$p.Value).Substring(2) }
            }
            ($cfg | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $cfgPath
            $ctx = New-XboxOSBuildContext -ConfigurationPath $cfgPath -SourceISO (Join-Path $script:TempRoot 'x.iso') -OutputDirectory (Join-Path $script:TempRoot 'out') -DryRun
            $r = & (Join-Path $script:RepoRoot 'scripts\Compress-Image.ps1') -Context $ctx -DryRun
            $r.FinalImagePath | Should -Match 'install-final\.esd$'
            $ctx.FinalImagePath | Should -Be $r.FinalImagePath
            Test-Path -LiteralPath $r.FinalImagePath | Should -BeFalse
        }
    }
}
