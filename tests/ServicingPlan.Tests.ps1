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
            -Source 'tests/Fixtures/dism-get-*-26300.9457.txt' `
            -VerificationStatus Authoritative `
            -SourceImage ([pscustomobject]@{
                editionName    = 'Windows 11 Pro'
                sourceIndex    = 6
                buildNumber    = '26300.9457'
                displayVersion = '26H2'
                isoSha256      = 'TEST'
            })
        $script:TempRoot = Join-Path $env:TEMP ('XboxOS11-plan-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports engine 2.1.0 and plan-hash-v1' {
        Get-XboxOSServicingPlanEngineVersion | Should -Be '2.1.0'
        Get-XboxOSPlanHashSchemaVersion | Should -Be 'plan-hash-v1'
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
            $op.dependencyCompleteness | Should -Be 'Unverified'
        }
        $plan.executionAuthorized | Should -BeFalse
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
            -Source 'unit-ambiguous' `
            -VerificationStatus Authoritative

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
        $plan.executionAuthorized | Should -BeFalse
    }

    It 'fails closed on unknown inventory' {
        $inventory = New-XboxOSInventorySnapshot `
            -AppxAvailability Unknown `
            -FeatureAvailability Unknown `
            -AppxPackages @() `
            -Features @() `
            -Source 'unit-unknown' `
            -VerificationStatus Unverified `
            -VerificationErrors @('synthetic')
        $plan = New-XboxOSServicingPlan `
            -Inventory $inventory `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility

        $plan.approvalGate | Should -Be 'Blocked'
        $plan.summary.NotEvaluated | Should -BeGreaterThan 0
        $plan.modifyingCommandsInvoked | Should -BeFalse
        $plan.executionAuthorized | Should -BeFalse
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
            -Source 'unit-conflict' `
            -VerificationStatus Authoritative
        $plan = New-XboxOSServicingPlan `
            -Inventory $inventory `
            -RemoveAppsManifest ([pscustomobject]@{ candidates = @() }) `
            -DisableFeaturesManifest $badDisable `
            -CompatibilityManifest $script:Compatibility

        $plan.summary.Conflicting | Should -BeGreaterThan 0
        $plan.approvalGate | Should -Be 'Blocked'
    }

    It 'produces identical content hashes for identical inputs despite different planId timestamps' {
        $p1 = New-XboxOSServicingPlan `
            -Inventory $script:Inventory `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        Start-Sleep -Milliseconds 30
        $p2 = New-XboxOSServicingPlan `
            -Inventory $script:Inventory `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility

        $p1.contentHash | Should -Be $p2.contentHash
        $p1.planId | Should -Not -Be $p2.planId
        $p1.generatedUtc | Should -Not -Be $p2.generatedUtc
    }

    It 'changes contentHash when inventory changes' {
        $p1 = New-XboxOSServicingPlan `
            -Inventory $script:Inventory `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        $alteredAppx = @($script:Inventory.appxPackages + 'Contoso.Extra_1.0.0.0_neutral_~_abcdefghijklm')
        $altered = New-XboxOSInventorySnapshot `
            -AppxAvailability Available `
            -FeatureAvailability Available `
            -AppxPackages $alteredAppx `
            -Features $script:Inventory.features `
            -Source 'altered' `
            -VerificationStatus Authoritative `
            -SourceImage $script:Inventory.sourceImage
        $p2 = New-XboxOSServicingPlan `
            -Inventory $altered `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        $p1.contentHash | Should -Not -Be $p2.contentHash
    }

    It 'changes contentHash when manifests change' {
        $p1 = New-XboxOSServicingPlan `
            -Inventory $script:Inventory `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        $tweaked = [pscustomobject]@{
            candidates = @($script:RemoveApps.candidates)
            notes      = @('hash-invalidation-marker')
        }
        $p2 = New-XboxOSServicingPlan `
            -Inventory $script:Inventory `
            -RemoveAppsManifest $tweaked `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        $p1.contentHash | Should -Not -Be $p2.contentHash
    }

    It 'changes contentHash when a safety-relevant operation field changes' {
        $p1 = New-XboxOSServicingPlan `
            -Inventory $script:Inventory `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        $doc = $p1.canonicalPlanDocument
        $doc2 = [ordered]@{}
        foreach ($key in @($doc.Keys)) { $doc2[$key] = $doc[$key] }
        $ops = [System.Collections.ArrayList]@($doc2.operations)
        if ($ops.Count -gt 0) {
            $first = [ordered]@{}
            foreach ($k in @($ops[0].Keys)) { $first[$k] = $ops[0][$k] }
            $first.risk = 'Critical'
            $ops[0] = $first
            $doc2.operations = @($ops)
        }
        $h1 = Get-XboxOSPlanContentHash -CanonicalPayload (Get-XboxOSCanonicalPlanPayload -PlanDocument $doc)
        $h2 = Get-XboxOSPlanContentHash -CanonicalPayload (Get-XboxOSCanonicalPlanPayload -PlanDocument $doc2)
        $h1 | Should -Not -Be $h2
    }

    It 'detects duplicate Eligible operations for the same target' {
        $inventory = New-XboxOSInventorySnapshot `
            -AppxAvailability Available `
            -FeatureAvailability Empty `
            -AppxPackages @('Contoso.Weather_1.0.0.0_neutral_~_abcdefghijklm') `
            -Features @() `
            -Source 'unit-dup' `
            -VerificationStatus Authoritative
        $remove = [pscustomobject]@{
            candidates = @(
                [pscustomobject]@{ id = 'A'; enabled = $true; patterns = @('Contoso.Weather*') }
                [pscustomobject]@{ id = 'B'; enabled = $true; patterns = @('Contoso.Weather_1.0.0.0_neutral_~_abcdefghijklm') }
            )
        }
        $compat = [pscustomobject]@{
            protectedAppxPatterns        = @('Microsoft.WindowsStore*')
            protectedFeatureNamePatterns = @()
        }
        $plan = New-XboxOSServicingPlan `
            -Inventory $inventory `
            -RemoveAppsManifest $remove `
            -DisableFeaturesManifest ([pscustomobject]@{ candidates = @(); neverDisable = @() }) `
            -CompatibilityManifest $compat

        $plan.summary.Conflicting | Should -BeGreaterThan 0
        $plan.approvalGate | Should -Be 'Blocked'
        $plan.summary.Eligible | Should -Be 0
    }

    It 'detects incorrect advertised inventory counts' {
        $assert = Assert-XboxOSInventorySnapshot -Inventory ([pscustomobject]@{
                appxAvailability         = 'Available'
                featureAvailability      = 'Empty'
                appxPackages             = @('Contoso.Count_1.0.0.0_neutral_~_abcdefghijklm')
                features                 = @()
                advertisedAppxCount      = 99
                advertisedFeatureCount   = 0
                legacyNestedCountIgnored = $false
            })
        $assert.Valid | Should -BeFalse
        ($assert.Errors -join ' ') | Should -Match 'Advertised AppX count'
    }

    It 'blocks inventories with duplicate identities' {
        $snap = New-XboxOSInventorySnapshot `
            -AppxAvailability Available `
            -FeatureAvailability Empty `
            -AppxPackages @('Contoso.A_1.0.0.0_neutral_~_abcdefghijklm', 'Contoso.A_1.0.0.0_neutral_~_abcdefghijklm') `
            -Features @() `
            -Source 'dup-appx' `
            -VerificationStatus Authoritative
        $snap.verificationStatus | Should -Be 'Blocked'
        $plan = New-XboxOSServicingPlan `
            -Inventory $snap `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        $plan.approvalGate | Should -Be 'Blocked'
    }

    It 'blocks unknown feature states from becoming Eligible' {
        $inventory = New-XboxOSInventorySnapshot `
            -AppxAvailability Empty `
            -FeatureAvailability Available `
            -AppxPackages @() `
            -Features @([pscustomobject]@{ Name = 'WorkFolders-Client'; State = 'Enable Pending' }) `
            -Source 'unit-state' `
            -VerificationStatus Authoritative
        $plan = New-XboxOSServicingPlan `
            -Inventory $inventory `
            -RemoveAppsManifest ([pscustomobject]@{ candidates = @() }) `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        @($plan.operations | Where-Object { $_.targetIdentity -eq 'WorkFolders-Client' -and $_.status -eq 'Blocked' }).Count |
            Should -Be 1
        @($plan.operations | Where-Object { $_.targetIdentity -eq 'WorkFolders-Client' -and $_.status -eq 'Eligible' }).Count |
            Should -Be 0
    }

    It 'blocks failed DISM captures and truncated inventories' {
        $failedPath = Join-Path $script:TempRoot 'failed-compat.json'
        $payload = [ordered]@{
            success = $false
            sourceIndexName = 'Windows 11 Pro'
            sourceIndex = 6
            appxCount = 0
            featureCount = 0
            packageCount = 0
            commands = @(
                [pscustomobject]@{ Step = 'Get-Packages'; ExitCode = 87; Output = @('Error') }
                [pscustomobject]@{ Step = 'Get-ProvisionedAppxPackages'; ExitCode = 87; Output = @('Error') }
                [pscustomobject]@{ Step = 'Get-Features'; ExitCode = 87; Output = @('Error') }
            )
        }
        ($payload | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $failedPath -Encoding UTF8
        $inventory = Import-XboxOSInventoryFromCompatReport -Path $failedPath
        $inventory.verificationStatus | Should -BeIn @('Unverified', 'Blocked')
        $plan = New-XboxOSServicingPlan `
            -Inventory $inventory `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        $plan.approvalGate | Should -Be 'Blocked'
        $plan.executionAuthorized | Should -BeFalse
    }

    It 'imports Milestone 1 compat report as Authoritative when transcripts are complete' {
        $compat = 'C:\XboxOS\Logs\DISM-Compatibility-20261014-2.json'
        if (-not (Test-Path -LiteralPath $compat)) {
            Set-ItResult -Skipped -Because 'M1 compat JSON not present on this host'
            return
        }
        $inventory = Import-XboxOSInventoryFromCompatReport -Path $compat
        $inventory.verificationStatus | Should -Be 'Authoritative'
        $inventory.appxPackages.Count | Should -Be 47
        $inventory.features.Count | Should -Be 136
        $inventory.legacyNestedCountIgnored | Should -BeTrue
    }

    It 'cannot become executable through approval metadata alone' {
        $plan = New-XboxOSServicingPlan `
            -Inventory $script:Inventory `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        $plan.approvalGate | Should -Be 'PendingOperatorApproval'
        $plan.executionAuthorized | Should -BeFalse
        $plan.approvalSemantics.eligibleMeansApproved | Should -BeFalse
        $plan.approvalSemantics.pendingOperatorApprovalIsExecutable | Should -BeFalse
        $plan.approvalSemantics.planEngineExecutesOperations | Should -BeFalse
        $plan.modifyingCommandsInvoked | Should -BeFalse
        $plan.canonicalPlanDocument.executionAuthorized | Should -BeFalse
    }

    It 'writes JSON/Markdown reports that agree on summary and non-execution' {
        $plan = New-XboxOSServicingPlan `
            -Inventory $script:Inventory `
            -RemoveAppsManifest $script:RemoveApps `
            -DisableFeaturesManifest $script:DisableFeatures `
            -CompatibilityManifest $script:Compatibility
        $paths = Save-XboxOSServicingPlanReport -Plan $plan -OutputDirectory $script:TempRoot -Stem 'unit-plan'
        $json = Get-Content -LiteralPath $paths.Json -Raw | ConvertFrom-Json
        $md = Get-Content -LiteralPath $paths.Markdown -Raw
        $json.modifyingCommandsInvoked | Should -BeFalse
        $json.executionAuthorized | Should -BeFalse
        $json.contentHash | Should -Be $plan.contentHash
        $md | Should -Match ([regex]::Escape($plan.contentHash))
        $md | Should -Match ('\| Eligible \| {0} \|' -f $plan.summary.Eligible)
        $md | Should -Match 'not executable'
    }

    It 'New-ServicingPlan.ps1 is plan-only (no Commit/Remove/Disable switches)' {
        $text = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts\New-ServicingPlan.ps1') -Raw
        $text | Should -Match 'New-XboxOSServicingPlan'
        $text | Should -Not -Match '/Commit'
        $text | Should -Not -Match '/Remove-ProvisionedAppxPackage'
        $text | Should -Not -Match '/Disable-Feature'
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
