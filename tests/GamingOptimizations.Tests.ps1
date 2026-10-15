#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'XboxOS11 Milestone 9 gaming optimizations (sandboxed registry)' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        $script:RepoRoot = $repoRoot.Path
        $script:Script = Join-Path $script:RepoRoot 'postinstall\Set-GamingOptimizations.ps1'
        $script:Catalog = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'config\gaming-tweaks.json') -Raw | ConvertFrom-Json
        $script:TempRoot = Join-Path $env:TEMP ('XboxOS11-m9-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

        $script:NewSandbox = {
            $root = 'HKCU:\Software\XboxOS11Tests\' + [guid]::NewGuid().ToString('N')
            New-Item -Path $root -Force | Out-Null
            return [pscustomobject]@{ Root = $root; State = (Join-Path $script:TempRoot ([guid]::NewGuid().ToString('N') + '.json')) }
        }
        $script:Reg = {
            param($sandbox, [string]$hive, [string]$path)
            Join-Path (Join-Path $sandbox.Root $hive) $path
        }
        $script:Invoke = {
            param($sandbox, [hashtable]$Arguments)
            & $script:Script @Arguments -StatePath $sandbox.State -TestRegistryRoot $sandbox.Root -PassThru 6>$null
        }
    }

    AfterAll {
        Remove-Item -LiteralPath 'HKCU:\Software\XboxOS11Tests' -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'catalog' {
        It 'contains only documented, reversible settings with unique ids' {
            $script:Catalog.schemaVersion | Should -Be 'xboxos-gaming-tweaks-v1'
            $ids = @($script:Catalog.tweaks | ForEach-Object { $_.id })
            @($ids | Select-Object -Unique).Count | Should -Be $ids.Count
            foreach ($t in $script:Catalog.tweaks) {
                $t.settingsPage | Should -Match '^Settings >' -Because $t.id
                $t.scope | Should -BeIn @('User', 'Machine')
                foreach ($v in $t.values) {
                    $v.path | Should -Match '^(HKCU|HKLM):\\'
                    $v.type | Should -BeIn @('DWord', 'String', 'DirectXSetting')
                }
            }
        }

        It 'never touches power plans, Game Bar, security, or update settings' {
            $paths = @($script:Catalog.tweaks | ForEach-Object { $_.values } | ForEach-Object { "$($_.path)\$($_.name)" }) -join "`n"
            $paths | Should -Not -Match '(?i)power|Defender|WindowsUpdate|DeviceGuard|Lsa|Memory Management|UseNexusForGameBarEnabled|AppCaptureEnabled'
            @($script:Catalog.neverChange | ForEach-Object { $_.item }) | Should -Contain 'Power plan'
            @($script:Catalog.neverChange | ForEach-Object { $_.item }) | Should -Contain 'Xbox Game Bar'
        }

        It 'lists the catalog without changing anything' {
            $out = & $script:Script -List -PassThru 6>$null
            @($out).Count | Should -Be @($script:Catalog.tweaks).Count
        }
    }

    Context 'apply and restore' {
        It 'applies defaults, captures originals, and restores them exactly' {
            $sb = & $script:NewSandbox
            $gameBarKey = & $script:Reg $sb 'HKCU' 'Software\Microsoft\GameBar'
            New-Item -Path $gameBarKey -Force | Out-Null
            New-ItemProperty -LiteralPath $gameBarKey -Name AutoGameModeEnabled -PropertyType DWord -Value 0 | Out-Null
            $dxKey = & $script:Reg $sb 'HKCU' 'Software\Microsoft\DirectX\UserGpuPreferences'
            New-Item -Path $dxKey -Force | Out-Null
            New-ItemProperty -LiteralPath $dxKey -Name DirectXUserGlobalSettings -PropertyType String -Value 'AutoHDREnable=1;SwapEffectUpgradeEnable=0;' | Out-Null

            $applied = & $script:Invoke $sb @{ UseDefaults = $true }
            @($applied | Where-Object { $_.Status -eq 'Applied' } | ForEach-Object { $_.Tweak }) | Should -Be @('GameMode', 'WindowedGameOptimizations', 'BackgroundRecordingOff')
            (Get-ItemProperty -LiteralPath $gameBarKey).AutoGameModeEnabled | Should -Be 1
            (Get-ItemProperty -LiteralPath $dxKey).DirectXUserGlobalSettings | Should -Be 'AutoHDREnable=1;SwapEffectUpgradeEnable=1;'
            (Get-ItemProperty -LiteralPath (& $script:Reg $sb 'HKCU' 'Software\Microsoft\Windows\CurrentVersion\GameDVR')).HistoricalCaptureEnabled | Should -Be 0

            $again = & $script:Invoke $sb @{ UseDefaults = $true }
            @($again | ForEach-Object { $_.Status } | Select-Object -Unique) | Should -Be @('AlreadySet')

            $restored = & $script:Invoke $sb @{ Restore = $true }
            @($restored | Where-Object { $_.Status -eq 'Restored' }).Count | Should -Be 3
            (Get-ItemProperty -LiteralPath $gameBarKey).AutoGameModeEnabled | Should -Be 0
            (Get-ItemProperty -LiteralPath $dxKey).DirectXUserGlobalSettings | Should -Be 'AutoHDREnable=1;SwapEffectUpgradeEnable=0;'
            $dvr = Get-Item -LiteralPath (& $script:Reg $sb 'HKCU' 'Software\Microsoft\Windows\CurrentVersion\GameDVR')
            $dvr.GetValueNames() | Should -Not -Contain 'HistoricalCaptureEnabled'
            (Get-Content -LiteralPath $sb.State -Raw | ConvertFrom-Json).captured.Count | Should -Be 0
        }

        It 'edits one DirectX key at a time and removes a value it created' {
            $sb = & $script:NewSandbox
            & $script:Invoke $sb @{ Enable = @('WindowedGameOptimizations', 'VariableRefreshRate') } | Out-Null
            $dxKey = & $script:Reg $sb 'HKCU' 'Software\Microsoft\DirectX\UserGpuPreferences'
            (Get-ItemProperty -LiteralPath $dxKey).DirectXUserGlobalSettings | Should -Be 'SwapEffectUpgradeEnable=1;VRROptimizeEnable=1;'
            & $script:Invoke $sb @{ Restore = $true } | Out-Null
            (Get-Item -LiteralPath $dxKey).GetValueNames() | Should -Not -Contain 'DirectXUserGlobalSettings'
        }

        It 'captures the original only once across repeated runs' {
            $sb = & $script:NewSandbox
            $mouse = & $script:Reg $sb 'HKCU' 'Control Panel\Mouse'
            New-Item -Path $mouse -Force | Out-Null
            foreach ($n in 'MouseSpeed', 'MouseThreshold1', 'MouseThreshold2') { New-ItemProperty -LiteralPath $mouse -Name $n -PropertyType String -Value '1' | Out-Null }
            & $script:Invoke $sb @{ Enable = @('PointerPrecisionOff') } | Out-Null
            Set-ItemProperty -LiteralPath $mouse -Name MouseSpeed -Value '2'
            & $script:Invoke $sb @{ Enable = @('PointerPrecisionOff') } | Out-Null
            & $script:Invoke $sb @{ Restore = $true } | Out-Null
            (Get-ItemProperty -LiteralPath $mouse).MouseSpeed | Should -Be '1'
        }

        It 'changes nothing under -WhatIf' {
            $sb = & $script:NewSandbox
            $r = & $script:Invoke $sb @{ UseDefaults = $true; WhatIf = $true }
            @($r | ForEach-Object { $_.Status } | Select-Object -Unique) | Should -Be @('WhatIf')
            Test-Path -LiteralPath (& $script:Reg $sb 'HKCU' 'Software\Microsoft\GameBar') | Should -BeFalse
            Test-Path -LiteralPath $sb.State | Should -BeFalse
        }

        It 'reports unknown tweaks without stopping other tweaks' {
            $sb = & $script:NewSandbox
            $r = & $script:Invoke $sb @{ Enable = @('DisableDefender', 'GameMode') }
            @($r | Where-Object { $_.Tweak -eq 'DisableDefender' })[0].Status | Should -Be 'Failed'
            @($r | Where-Object { $_.Tweak -eq 'GameMode' })[0].Status | Should -Be 'Applied'
        }

        It 'flags machine-scope restart requirements' {
            $sb = & $script:NewSandbox
            $r = & $script:Invoke $sb @{ Enable = @('HardwareAcceleratedGpuScheduling') }
            $r[0].Status | Should -Be 'Applied'
            $r[0].RequiresRestart | Should -BeTrue
            (Get-ItemProperty -LiteralPath (& $script:Reg $sb 'HKLM' 'SYSTEM\CurrentControlSet\Control\GraphicsDrivers')).HwSchMode | Should -Be 2
        }
    }

    Context 'first-logon integration' {
        It 'applies profile optimizations through Invoke-PostInstall' {
            $sb = & $script:NewSandbox
            $dir = Join-Path $script:TempRoot ('post-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $opts = [ordered]@{
                schemaVersion = 'xboxos-postinstall-options-v1'; profileName = 'm9'; gameMode = $true; hardwareAcceleratedGpuScheduling = $false
                launchers = @(); optimizations = @('WindowedGameOptimizations'); logPath = (Join-Path $dir 'postinstall.log')
            }
            ($opts | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $dir 'postinstall.json')
            $null = & (Join-Path $script:RepoRoot 'postinstall\Invoke-PostInstall.ps1') -OptionsPath (Join-Path $dir 'postinstall.json') `
                -StatePath $sb.State -TestRegistryRoot $sb.Root -WingetWaitSeconds 0 6>$null
            $summary = Get-Content -LiteralPath (Join-Path $dir 'postinstall-summary.json') -Raw | ConvertFrom-Json
            @($summary | Where-Object { $_.Step -eq 'Optimization:WindowedGameOptimizations' })[0].Status | Should -Be 'Applied'
            @($summary | Where-Object { $_.Step -eq 'Optimization:GameMode' })[0].Status | Should -Be 'Applied'
        }
    }
}
