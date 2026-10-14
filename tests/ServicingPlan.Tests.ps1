#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'XboxOS11 Milestone 2 servicing plan engine' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        Import-Module (Join-Path $repoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force
        $script:RepoRoot = $repoRoot.Path
        $script:Fixtures = Join-Path $script:RepoRoot 'tests\Fixtures'
        $script:RemoveApps = Import-XboxOSManifest -Path (Join-Path $script:RepoRoot 'config\remove-apps.json')
        $script:DisableFeatures = Import-XboxOSManifest -Path (Join-Path $script:RepoRoot 'config\disable-features.json')
        $script:Compatibility = Import-XboxOSManifest -Path (Join-Path $script:RepoRoot 'config\compatibility.json')

        $appx = @(ConvertFrom-XboxOSDismProvisionedAppxListOutput -Output (Get-Content (Join-Path $script:Fixtures 'dism-get-appx-26300.9457.txt')) | ForEach-Object { $_.PackageName })
        $features = @(ConvertFrom-XboxOSDismFeatureListOutput -Output (Get-Content (Join-Path $script:Fixtures 'dism-get-features-26300.9457.txt')))
        $script:Inventory = New-XboxOSInventorySnapshot `
            -AppxAvailability Available `
            -FeatureAvailability Available `
            -AppxPackages $appx `
            -Features $features `
            -Source 'tests/Fixtures/dism-get-*-26300.9457.txt'
        $script:TempRoot = Join-Path $env:TEMP ('XboxOS11-plan-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports engine version 2.0.0' {
        Get-XboxOSServicingPlanEngineVersion | Should -Be '2.0.0'
    }

    It 'plans exact AppX identities and rejects protected Xbox TCUI' {
        $plan = New-XboxOSServicingPlan `
            -Inventory $script:Inventory `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility `
            -IncludeDisabledManifestCandidates

        $xbox = @($plan.operations | Where-Object { $_.manifestRuleId -eq 'XboxTCUI' -and $_.status -eq 'Protected' })
        $xbox.Count | Should -BeGreaterThan 0
        $eligibleAppx = @($plan.operations | Where-Object { $_.operationType -eq 'RemoveProvisionedAppx' -and $_.status -eq 'Eligible' })
        $eligibleAppx.Count | Should -BeGreaterThan 0
        foreach ($op in $eligibleAppx) {
            $op.targetIdentity | Should -Not -BeNullOrEmpty
            $op.targetIdentity | Should -Not -Match '\*'
            $op.approvalRequired | Should -BeTrue
        }
    }

    It 'rejects ambiguous package matches' {
        $inventory = New-XboxOSInventorySnapshot `
            -AppxAvailability Available `
            -FeatureAvailability Empty `
            -AppxPackages @(
                'Contoso.Demo_1.0.0.0_neutral_~_abcdefghijklm'
                'Contoso.DemoExtra_1.0.0.0_neutral_~_abcdefghijklm'
            ) `
            -Features @() `
            -Source 'unit-ambiguous'

        $remove = [pscustomobject]@{
            candidates = @(
                [pscustomobject]@{
                    id       = 'Demo'
                    enabled  = $true
                    patterns = @('Contoso.Demo*')
                }
            )
        }
        $disable = [pscustomobject]@{ candidates = @(); neverDisable = @() }
        $plan = New-XboxOSServicingPlan `
            -Inventory $inventory `
            -RemoveAppsManifest $remove `
            -DisableFeaturesManifest $disable `
            -CompatibilityManifest $script:Compatibility

        @($plan.operations | Where-Object status -eq 'Ambiguous').Count | Should -BeGreaterThan 0
        $plan.approvalGate | Should -Be 'Blocked'
        $plan.summary.Eligible | Should -Be 0
    }

    It 'fails closed on unknown inventory' {
        $inventory = New-XboxOSInventorySnapshot `
            -AppxAvailability Unknown `
            -FeatureAvailability Unknown `
            -AppxPackages @() `
            -Features @() `
            -Source 'unit-unknown'
        $plan = New-XboxOSServicingPlan `
            -Inventory $inventory `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility

        $plan.approvalGate | Should -Be 'Blocked'
        $plan.summary.NotEvaluated | Should -BeGreaterThan 0
        $plan.modifyingCommandsInvoked | Should -BeFalse
    }

    It 'marks already-disabled features as AlreadySatisfied and WorkFolders as Eligible' {
        $plan = New-XboxOSServicingPlan `
            -Inventory $script:Inventory `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility

        @($plan.operations | Where-Object { $_.targetIdentity -eq 'WorkFolders-Client' -and $_.status -eq 'Eligible' }).Count |
            Should -Be 1
        @($plan.operations | Where-Object { $_.targetIdentity -eq 'Printing-XPSServices-Features' -and $_.status -eq 'AlreadySatisfied' }).Count |
            Should -Be 1
        @($plan.operations | Where-Object { $_.targetIdentity -like 'SMB1Protocol*' -and $_.status -eq 'AlreadySatisfied' }).Count |
            Should -Be 3
    }

    It 'rejects disable-features manifest conflicts' {
        $badDisable = [pscustomobject]@{
            candidates = @(
                [pscustomobject]@{
                    id           = 'Smb1'
                    enabled      = $true
                    featureNames = @('SMB1Protocol-Deprecation')
                }
            )
            neverDisable = @('SMB1Protocol-Deprecation')
        }
        $inventory = New-XboxOSInventorySnapshot `
            -AppxAvailability Empty `
            -FeatureAvailability Available `
            -AppxPackages @() `
            -Features @([pscustomobject]@{ Name = 'SMB1Protocol-Deprecation'; State = 'Enabled' }) `
            -Source 'unit-conflict'
        $plan = New-XboxOSServicingPlan `
            -Inventory $inventory `
            -RemoveAppsManifest ([pscustomobject]@{ candidates = @() }) `
            -DisableFeaturesManifest $badDisable `
            -CompatibilityManifest $script:Compatibility

        $plan.summary.Conflicting | Should -BeGreaterThan 0
        $plan.approvalGate | Should -Be 'Blocked'
    }

    It 'produces deterministic content hashes for identical inputs' {
        $p1 = New-XboxOSServicingPlan `
            -Inventory $script:Inventory `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        Start-Sleep -Milliseconds 20
        $p2 = New-XboxOSServicingPlan `
            -Inventory $script:Inventory `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility

        $p1.contentHash | Should -Be $p2.contentHash
        (Get-XboxOSCanonicalPlanPayload -Operations $p1.operations) |
            Should -Be (Get-XboxOSCanonicalPlanPayload -Operations $p2.operations)
    }

    It 'detects duplicate Eligible operations for the same target' {
        $inventory = New-XboxOSInventorySnapshot `
            -AppxAvailability Available `
            -FeatureAvailability Empty `
            -AppxPackages @('Contoso.Weather_1.0.0.0_neutral_~_abcdefghijklm') `
            -Features @() `
            -Source 'unit-dup'
        $remove = [pscustomobject]@{
            candidates = @(
                [pscustomobject]@{ id = 'A'; enabled = $true; patterns = @('Contoso.Weather*') }
                [pscustomobject]@{ id = 'B'; enabled = $true; patterns = @('Contoso.Weather_1.0.0.0_neutral_~_abcdefghijklm') }
            )
        }
        $compat = [pscustomobject]@{
            protectedAppxPatterns          = @('Microsoft.WindowsStore*')
            protectedFeatureNamePatterns   = @()
        }
        $plan = New-XboxOSServicingPlan `
            -Inventory $inventory `
            -RemoveAppsManifest $remove `
            -DisableFeaturesManifest ([pscustomobject]@{ candidates = @(); neverDisable = @() }) `
            -CompatibilityManifest $compat

        $plan.summary.Conflicting | Should -BeGreaterThan 0
        $plan.approvalGate | Should -Be 'Blocked'
        $plan.modifyingCommandsInvoked | Should -BeFalse
    }

    It 'writes JSON/Markdown reports without modifying-command claims' {
        $plan = New-XboxOSServicingPlan `
            -Inventory $script:Inventory `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        $paths = Save-XboxOSServicingPlanReport -Plan $plan -OutputDirectory $script:TempRoot -Stem 'unit-plan'
        Test-Path -LiteralPath $paths.Json | Should -BeTrue
        Test-Path -LiteralPath $paths.Markdown | Should -BeTrue
        $json = Get-Content -LiteralPath $paths.Json -Raw | ConvertFrom-Json
        $json.modifyingCommandsInvoked | Should -BeFalse
        $json.dryRun | Should -BeTrue
        $md = Get-Content -LiteralPath $paths.Markdown -Raw
        $md | Should -Match 'Approval gate'
        $md | Should -Match 'AlreadySatisfied'
        $md | Should -Not -Match 'System\.String\[\]'
    }

    It 'imports Milestone 1 compat report inventory when available' {
        $compat = 'C:\XboxOS\Logs\DISM-Compatibility-20261014-2.json'
        if (-not (Test-Path -LiteralPath $compat)) {
            Set-ItResult -Skipped -Because 'M1 compat JSON not present on this host'
            return
        }
        $inventory = Import-XboxOSInventoryFromCompatReport -Path $compat
        $inventory.appxAvailability | Should -Be 'Available'
        $inventory.featureAvailability | Should -Be 'Available'
        $inventory.appxPackages.Count | Should -Be 47
        $inventory.features.Count | Should -Be 136
    }

    It 'New-ServicingPlan.ps1 is plan-only (no Commit/Remove/Disable switches)' {
        $text = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts\New-ServicingPlan.ps1') -Raw
        $text | Should -Match 'New-XboxOSServicingPlan'
        $text | Should -Not -Match '/Commit'
        $text | Should -Not -Match '/Remove-ProvisionedAppxPackage'
        $text | Should -Not -Match '/Disable-Feature'
        $text | Should -Not -Match '/Add-Driver'
        $text | Should -Not -Match '/Add-Package'
    }

    It 'refuses OneDrive report output paths' {
        {
            $plan = New-XboxOSServicingPlan `
                -Inventory $script:Inventory `
                -RemoveAppsManifest $script:RemoveApps `
                -DisableFeaturesManifest $script:DisableFeatures `
                -CompatibilityManifest $script:Compatibility
            Save-XboxOSServicingPlanReport -Plan $plan -OutputDirectory 'C:\Users\schmi\OneDrive\WinDev Apps\XboxOS11\artifacts' -Stem 'bad'
        } | Should -Throw -ExpectedMessage '*OneDrive*'
    }
}
