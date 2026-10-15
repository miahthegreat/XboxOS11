#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'XboxOS11 Milestone 7 builder backend' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        Import-Module (Join-Path $repoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force
        $script:RepoRoot = $repoRoot.Path
        $script:TempRoot = Join-Path $env:TEMP ('XboxOS11-m7-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        $script:Iso = Join-Path $script:TempRoot 'Win11_Pro_x64.iso'
        Set-Content -LiteralPath $script:Iso -Value 'placeholder' -Encoding ASCII
        $script:NewProfile = {
            param([string]$Preset = 'gaming-balanced')
            New-XboxOSBuildProfile -Name 'Test Rig' -PresetId $Preset -SourceIso $script:Iso -OutputDirectory (Join-Path $script:TempRoot 'out')
        }
        $script:Errors = { param($p, [switch]$ForBuild) (Test-XboxOSBuildProfile -BuildProfile $p -ForBuild:$ForBuild).errors -join ' | ' }
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:TempRoot) { Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Context 'presets and profiles' {
        It 'ships four ordered presets that each produce a valid profile' {
            $presets = @(Get-XboxOSBuilderPreset)
            @($presets | ForEach-Object { $_.id }) | Should -Be @('gaming-balanced', 'gaming-lean', 'handheld-xbox-mode', 'stock-safe')
            @($presets | Where-Object { $_.recommended }).Count | Should -Be 1
            foreach ($p in $presets) {
                $check = Test-XboxOSBuildProfile -BuildProfile (& $script:NewProfile $p.id)
                $check.valid | Should -BeTrue -Because ($p.id + ': ' + ($check.errors -join '; '))
            }
        }

        It 'rejects an unknown preset' {
            { Get-XboxOSBuilderPreset -Id 'turbo-debloat' } | Should -Throw '*Unknown builder preset*'
        }

        It 'round-trips through save/load with a stable hash' {
            $p = & $script:NewProfile
            $path = Export-XboxOSBuildProfile -BuildProfile $p -Path (Join-Path $script:TempRoot 'profiles\rig.json')
            $loaded = Import-XboxOSBuildProfile -Path $path
            (Test-XboxOSBuildProfile -BuildProfile $loaded).valid | Should -BeTrue
            Get-XboxOSBuildProfileHash -BuildProfile $loaded | Should -Be (Get-XboxOSBuildProfileHash -BuildProfile $p)
            $loaded.schemaVersion | Should -Be 'xboxos-build-profile-v1'
        }

        It 'refuses to save an invalid profile' {
            $p = & $script:NewProfile
            $p.apps.remove = @('XboxTCUI')
            { Export-XboxOSBuildProfile -BuildProfile $p -Path (Join-Path $script:TempRoot 'bad.json') } | Should -Throw '*invalid*'
        }
    }

    Context 'validation' {
        It 'rejects requirement bypass and security settings as unsupported' {
            $p = & $script:NewProfile
            $p.setup | Add-Member -NotePropertyName bypassTpmCheck -NotePropertyValue $true
            $p.setup | Add-Member -NotePropertyName disableDefender -NotePropertyValue $true
            $e = & $script:Errors $p
            $e | Should -Match "Unsupported setting 'setup.bypassTpmCheck'"
            $e | Should -Match "Unsupported setting 'setup.disableDefender'"
        }

        It 'rejects unknown keys and missing sections' {
            $p = & $script:NewProfile
            $p | Add-Member -NotePropertyName extras -NotePropertyValue 1
            & $script:Errors $p | Should -Match "Unknown profile setting '\(root\).extras'"
            $q = & $script:NewProfile
            $q.PSObject.Properties.Remove('apps')
            & $script:Errors $q | Should -Match "section 'apps' is missing"
        }

        It 'never allows protected gaming dependencies to be removed or disabled' {
            $p = & $script:NewProfile
            $p.apps.remove = @('XboxTCUI')
            & $script:Errors $p | Should -Match 'protected gaming/platform dependency'
        }

        It 'rejects unknown candidates, launchers, locales, time zones, and privacy values' {
            $p = & $script:NewProfile
            $p.apps.remove = @('Edge')
            $p.features.disable = @('Hyper-V')
            $p.setup.postInstall.launchers = @('Origin')
            $p.setup.uiLanguage = 'english'
            $p.setup.timeZone = 'Mars/Olympus'
            $p.setup.privacy = 'Off'
            $e = & $script:Errors $p
            foreach ($needle in @("Unknown app removal candidate 'Edge'", "Unknown feature candidate 'Hyper-V'", "Unknown launcher 'Origin'", 'setup.uiLanguage', 'Windows time zone', 'setup.privacy')) {
                $e | Should -Match ([regex]::Escape($needle))
            }
        }

        It 'requires unattend for post-install and StartupToGamingHome' {
            $p = & $script:NewProfile 'handheld-xbox-mode'
            $p.setup.unattend = $false
            $e = & $script:Errors $p
            $e | Should -Match 'startupToGamingHome requires setup.unattend'
            $e | Should -Match 'postInstall requires setup.unattend'
        }

        It 'validates gaming optimizations and keeps older v1 profiles without them valid' {
            $p = & $script:NewProfile
            $p.setup.postInstall.optimizations = @('VariableRefreshRate', 'DisableDefender', 'GameMode')
            $e = & $script:Errors $p
            $e | Should -Match "Unknown optimization 'DisableDefender'"
            $e | Should -Match "'GameMode' is controlled by setup.postInstall.gameMode"
            $e | Should -Not -Match 'VariableRefreshRate'
            $old = & $script:NewProfile
            $old.setup.postInstall.PSObject.Properties.Remove('optimizations')
            (Test-XboxOSBuildProfile -BuildProfile $old).valid | Should -BeTrue
        }

        It 'warns that StartupToGamingHome is handheld-oriented' {
            (Test-XboxOSBuildProfile -BuildProfile (& $script:NewProfile 'handheld-xbox-mode')).warnings -join ' ' | Should -Match 'handhelds'
        }

        It 'rejects output inside the repository or OneDrive and bad ISO labels' {
            $p = & $script:NewProfile
            $p.output.directory = Join-Path $script:RepoRoot 'out'
            $p.output.isoLabel = 'Xbox OS 11!'
            $e = & $script:Errors $p
            $e | Should -Match 'inside the XboxOS11 repository'
            $e | Should -Match 'isoLabel'
            $p.output.directory = 'C:\Users\someone\OneDrive\Builds'
            & $script:Errors $p | Should -Match 'cloud-synchronized'
        }

        It 'checks file-system prerequisites only for real builds' {
            $p = & $script:NewProfile
            $p.source.isoPath = Join-Path $script:TempRoot 'missing.iso'
            $p.drivers.enabled = $true
            $p.drivers.directory = Join-Path $script:TempRoot 'no-drivers'
            (Test-XboxOSBuildProfile -BuildProfile $p).valid | Should -BeTrue
            $e = & $script:Errors $p -ForBuild
            $e | Should -Match 'Source ISO not found'
            $e | Should -Match 'drivers directory not found'
            $p.source.isoPath = Join-Path $script:TempRoot 'image.img'
            & $script:Errors $p | Should -Match 'must be an .iso file'
        }

        It 'warns about installer executables in the driver folder' {
            $drv = Join-Path $script:TempRoot 'drivers-with-exe'
            New-Item -ItemType Directory -Path $drv -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $drv 'AMD-Software-Adrenalin-Setup.exe') -Value 'x'
            $p = & $script:NewProfile
            $p.drivers.enabled = $true
            $p.drivers.directory = $drv
            (Test-XboxOSBuildProfile -BuildProfile $p -ForBuild).warnings -join ' ' | Should -Match 'Adrenalin after Windows Setup'
        }
    }

    Context 'component review' {
        It 'marks protected candidates non-selectable and reports what is always preserved' {
            $r = Get-XboxOSBuildProfileReview -BuildProfile (& $script:NewProfile)
            $tcui = @($r.apps | Where-Object { $_.id -eq 'XboxTCUI' })[0]
            $tcui.protected | Should -BeTrue
            $tcui.selectable | Should -BeFalse
            @($r.apps | Where-Object { $_.id -eq 'Clipchamp' })[0].selected | Should -BeTrue
            $r.summary.appsRemoved | Should -Be 7
            $r.summary.featuresDisabled | Should -Be 4
            $r.alwaysPreserved | Should -Contain 'Microsoft Defender'
            $r.validation.valid | Should -BeTrue
        }
    }

    Context 'unattend generation' {
        It 'produces well-formed XML with only documented, non-bypass settings' {
            $xml = New-XboxOSUnattendXml -BuildProfile (& $script:NewProfile)
            { [xml]$xml } | Should -Not -Throw
            foreach ($forbidden in @('DiskConfiguration', 'ProductKey', 'LocalAccount', 'AutoLogon', 'BypassTPMCheck', 'BypassNRO', 'LabConfig', 'WillWipeDisk', 'Password')) {
                $xml | Should -Not -Match $forbidden
            }
            $xml | Should -Match '<ProtectYourPC>3</ProtectYourPC>'
            $xml | Should -Match 'Invoke-PostInstall.ps1'
            $xml | Should -Not -Match 'StartupToGamingHome'
        }

        It 'adds StartupToGamingHome only when selected and omits FirstLogonCommands without post-install' {
            $p = & $script:NewProfile 'handheld-xbox-mode'
            $p.setup.postInstall.enabled = $false
            $doc = [xml](New-XboxOSUnattendXml -BuildProfile $p)
            $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
            $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
            $doc.SelectSingleNode("//u:settings[@pass='specialize']/u:component[@name='Microsoft-Windows-Gaming-Configuration']/u:StartupToGamingHome", $ns).InnerText | Should -Be 'true'
            $doc.SelectNodes('//u:FirstLogonCommands', $ns).Count | Should -Be 0
        }

        It 'refuses to generate unattend when disabled' {
            { New-XboxOSUnattendXml -BuildProfile (& $script:NewProfile 'stock-safe') } | Should -Throw '*no unattend*'
        }
    }

    Context 'effective configuration and media overlay' {
        It 'materializes manifests outside the repository that the build engine accepts' {
            $p = & $script:NewProfile
            $eff = New-XboxOSBuilderEffectiveConfiguration -BuildProfile $p -WorkRoot (Join-Path $script:TempRoot 'eff')
            Test-XboxOSPathEqualsOrUnder -Path $eff.Directory -ParentPath $script:RepoRoot | Should -BeFalse
            $cfg = Get-XboxOSBuildConfiguration -Path $eff.ConfigurationPath
            $cfg.Raw.builderProfile.profileHash | Should -Be $eff.ProfileHash
            $cfg.Raw.phases.removeApps | Should -BeTrue
            $cfg.Raw.phases.addDrivers | Should -BeFalse
            $cfg.ResolvedPath.compatibilityManifest | Should -Be (Join-Path $script:RepoRoot 'config\compatibility.json')
            $apps = Get-Content -LiteralPath $cfg.ResolvedPath.removeAppsManifest -Raw | ConvertFrom-Json
            @($apps.candidates | Where-Object { $_.enabled } | ForEach-Object { $_.id }) | Should -Be @('Clipchamp', 'Copilot', 'TeamsConsumer', 'News', 'Weather', 'Solitaire', 'OutlookConsumer')
            @($apps.candidates | Where-Object { $_.id -eq 'XboxTCUI' })[0].enabled | Should -BeFalse
        }

        It 'stages autounattend and the post-install payload in a valid overlay' {
            $eff = New-XboxOSBuilderEffectiveConfiguration -BuildProfile (& $script:NewProfile) -WorkRoot (Join-Path $script:TempRoot 'eff2')
            $check = Test-XboxOSMediaOverlay -Directory $eff.MediaOverlayDirectory
            $check.valid | Should -BeTrue
            $check.files | Should -Contain 'autounattend.xml'
            $check.files | Should -Contain 'sources\$OEM$\$$\Setup\Scripts\XboxOS11\Invoke-PostInstall.ps1'
            $opts = Get-Content -LiteralPath (Join-Path $eff.MediaOverlayDirectory 'sources\$OEM$\$$\Setup\Scripts\XboxOS11\postinstall.json') -Raw | ConvertFrom-Json
            $opts.launchers | Should -Be @('Steam')
            $opts.gameMode | Should -BeTrue
            $opts.optimizations | Should -Be @('WindowedGameOptimizations', 'BackgroundRecordingOff')
            $check.files | Should -Contain 'sources\$OEM$\$$\Setup\Scripts\XboxOS11\Set-GamingOptimizations.ps1'
            $check.files | Should -Contain 'sources\$OEM$\$$\Setup\Scripts\XboxOS11\gaming-tweaks.json'
        }

        It 'uses an exact edition name picked from the ISO as the target edition' {
            $p = & $script:NewProfile
            $p.source.editionPattern = 'Windows 11 Home'
            $eff = New-XboxOSBuilderEffectiveConfiguration -BuildProfile $p -WorkRoot (Join-Path $script:TempRoot 'eff-edition')
            $cfg = Get-Content -LiteralPath $eff.ConfigurationPath -Raw | ConvertFrom-Json
            $cfg.target.edition | Should -Be 'Windows 11 Home'
            $cfg.target.imageNamePattern | Should -Be 'Windows 11 Home'
            $q = & $script:NewProfile
            $eff2 = New-XboxOSBuilderEffectiveConfiguration -BuildProfile $q -WorkRoot (Join-Path $script:TempRoot 'eff-edition2')
            (Get-Content -LiteralPath $eff2.ConfigurationPath -Raw | ConvertFrom-Json).target.edition | Should -Be 'Windows 11 Pro'
        }

        It 'produces no overlay when unattend is disabled' {
            $eff = New-XboxOSBuilderEffectiveConfiguration -BuildProfile (& $script:NewProfile 'stock-safe') -WorkRoot (Join-Path $script:TempRoot 'eff3')
            $eff.MediaOverlayDirectory | Should -BeNullOrEmpty
        }

        It 'rejects overlays that would replace boot or image files' {
            $bad = Join-Path $script:TempRoot 'bad-overlay'
            New-Item -ItemType Directory -Path (Join-Path $bad 'sources') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $bad 'sources\boot.wim') -Value 'x'
            Set-Content -LiteralPath (Join-Path $bad 'setup.exe') -Value 'x'
            $check = Test-XboxOSMediaOverlay -Directory $bad
            $check.valid | Should -BeFalse
            ($check.errors -join ';') | Should -Match 'setup.exe'
            ($check.errors -join ';') | Should -Match 'boot.wim'
        }

        It 'refuses an invalid profile' {
            $p = & $script:NewProfile
            $p.apps.remove = @('XboxTCUI')
            { New-XboxOSBuilderEffectiveConfiguration -BuildProfile $p -WorkRoot (Join-Path $script:TempRoot 'eff4') } | Should -Throw '*invalid*'
        }
    }

    Context 'first-logon post-install entrypoint' {
        It 'runs every step in dry-run mode and writes a summary without failing sign-in' {
            $dir = Join-Path $script:TempRoot 'postinstall'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $opts = [ordered]@{
                schemaVersion = 'xboxos-postinstall-options-v1'; profileName = 'Test Rig'; gameMode = $true
                hardwareAcceleratedGpuScheduling = $false; launchers = @('Steam'); logPath = (Join-Path $dir 'postinstall.log')
            }
            $optsPath = Join-Path $dir 'postinstall.json'
            ($opts | ConvertTo-Json) | Set-Content -LiteralPath $optsPath
            $null = & (Join-Path $script:RepoRoot 'postinstall\Invoke-PostInstall.ps1') -OptionsPath $optsPath -WingetWaitSeconds 0 -DryRun 6>$null
            $summary = Get-Content -LiteralPath (Join-Path $dir 'postinstall-summary.json') -Raw | ConvertFrom-Json
            @($summary | ForEach-Object { $_.Step }) | Should -Contain 'GamingSettings'
            @($summary | Where-Object { $_.Step -eq 'GamingSettings' })[0].Status | Should -Be 'Completed'
            @($summary | Where-Object { $_.Step -like 'Launcher:*' -or $_.Step -eq 'Launchers' }).Count | Should -BeGreaterThan 0
            @($summary | Where-Object { $_.Step -like 'Launcher:*' -and $_.Status -eq 'Installed' }).Count | Should -Be 0
        }
    }

    Context 'frontend protocol' {
        It 'round-trips progress events' {
            $line = Write-XboxOSBuilderEvent -Type phase -Data @{ name = 'RemoveApps'; status = 'started' } 6>$null
            $evt = ConvertFrom-XboxOSBuilderEventLine -Line $line
            $evt.type | Should -Be 'phase'
            $evt.name | Should -Be 'RemoveApps'
            ConvertFrom-XboxOSBuilderEventLine -Line 'ordinary log line' | Should -BeNullOrEmpty
        }

        It 'returns one parseable API result line' {
            $out = & (Join-Path $script:RepoRoot 'scripts\Invoke-XboxOSBuilderApi.ps1') -Command catalog 6>$null
            $line = @($out | Where-Object { "$_".StartsWith('XBOXOS-RESULT ') })
            $line.Count | Should -Be 1
            $doc = $line[0].Substring(14) | ConvertFrom-Json
            $doc.ok | Should -BeTrue
            $doc.data.presets.Count | Should -Be 4
            $doc.data.launchers | Should -Contain 'Steam'
        }

        It 'reports API errors as ok=false results' {
            $out = & (Join-Path $script:RepoRoot 'scripts\Invoke-XboxOSBuilderApi.ps1') -Command validate 6>$null
            $doc = (@($out | Where-Object { "$_".StartsWith('XBOXOS-RESULT ') })[0]).Substring(14) | ConvertFrom-Json
            $doc.ok | Should -BeFalse
            $doc.error | Should -Match 'ProfilePath'
        }

        It 'runs a full profile-driven dry-run build with events' {
            $p = & $script:NewProfile
            $path = Export-XboxOSBuildProfile -BuildProfile $p -Path (Join-Path $script:TempRoot 'dry.json')
            $exe = (Get-Process -Id $PID).Path
            $out = & $exe -NoProfile -File (Join-Path $script:RepoRoot 'scripts\Invoke-XboxOSBuild.ps1') -ProfilePath $path -DryRun -EmitEvents -SkipPrerequisites -WorkRoot (Join-Path $script:TempRoot 'dry-eff')
            $LASTEXITCODE | Should -Be 0 -Because (($out | Select-Object -Last 40) -join "`n")
            $events = @($out | ForEach-Object { ConvertFrom-XboxOSBuilderEventLine -Line "$_" } | Where-Object { $_ })
            $events[0].type | Should -Be 'started'
            $events[-1].type | Should -Be 'completed'
            @($events | Where-Object { $_.type -eq 'phase' -and $_.name -eq 'ExportIso' -and $_.status -eq 'succeeded' }).Count | Should -Be 1
        }

        It 'plans ISO export in dry-run mode without Windows ADK installed' {
            $ctx = New-XboxOSBuildContext -ConfigurationPath (Join-Path $script:RepoRoot 'config\build.json') -SourceISO $script:Iso -OutputDirectory (Join-Path $script:TempRoot 'no-adk') -DryRun
            $result = & (Join-Path $script:RepoRoot 'scripts\Export-ISO.ps1') -Context $ctx -OscdimgPath (Join-Path $script:TempRoot 'missing\oscdimg.exe') -DryRun
            $result.DryRun | Should -BeTrue
            $result.Command | Should -Match '^oscdimg\.exe '
        }

        It 'exits 4 on an invalid profile' {
            $bad = Join-Path $script:TempRoot 'invalid.json'
            $p = & $script:NewProfile
            $p.setup | Add-Member -NotePropertyName bypassNro -NotePropertyValue $true
            ($p | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $bad
            $exe = (Get-Process -Id $PID).Path
            $null = & $exe -NoProfile -File (Join-Path $script:RepoRoot 'scripts\Invoke-XboxOSBuild.ps1') -ProfilePath $bad -DryRun -SkipPrerequisites
            $LASTEXITCODE | Should -Be 4
        }
    }
}
