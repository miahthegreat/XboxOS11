#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'XboxOS11 Milestone 6E controlled live discovery (Gate A, injected invokers only)' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        Import-Module (Join-Path $repoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') -Force
        $script:RepoRoot = $repoRoot.Path
        $script:Allowlist = Import-XboxOSHostDiscoveryAllowlistCatalog -Path (Join-Path $script:RepoRoot 'config\host-discovery-allowlist.json')
        $script:TempRoot = Join-Path $env:TEMP ('XboxOS11-m6e-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        $script:FixturePriv = Join-Path $script:RepoRoot 'tests\Fixtures\approval-auth\test-approval-private.pem'
        $script:FixturePub = Join-Path $script:RepoRoot 'tests\Fixtures\approval-auth\test-approval-public.pem'

        # Ephemeral operator key generated outside tests/Fixtures: treated as a trusted (non-fixture) identity.
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        try {
            $script:OperatorPriv = Join-Path $script:TempRoot 'operator-private.pem'
            $script:OperatorPub = Join-Path $script:TempRoot 'operator-public.pem'
            Set-Content -LiteralPath $script:OperatorPriv -Value $rsa.ExportPkcs8PrivateKeyPem() -Encoding UTF8
            Set-Content -LiteralPath $script:OperatorPub -Value $rsa.ExportSubjectPublicKeyInfoPem() -Encoding UTF8
        }
        finally { $rsa.Dispose() }

        $script:GitSha = 'e6e6e6e6e6e6e6e6e6e6e6e6e6e6e6e6e6e6e6e6'
        $script:CleanGit = [pscustomobject]@{ gitCommitSha = $script:GitSha; verificationState = 'VerifiedClean'; workingTreeClean = $true; errors = @() }
        $script:HostId = New-XboxOSObservedHostIdentity -OsObservation @{
            hostLabel = 'GAMING-RIG-01'; edition = 'Windows 11 Pro'; build = '26300.9457'; architecture = '64-bit'
        }
        $script:Scope = New-XboxOSHostDiscoveryScopeForRealHost

        $script:NewApproval = {
            param(
                [string]$Priv = $script:OperatorPriv,
                [string]$Pub = $script:OperatorPub,
                [datetime]$IssuedUtc = [datetime]::UtcNow,
                [datetime]$ExpiresUtc = [datetime]::UtcNow.AddHours(1),
                [switch]$TestKey
            )
            New-XboxOSAuthorizedHostDiscoveryApprovalRecord -OperatorId 'lab-operator' -HostIdentity $script:HostId `
                -DiscoveryScope $script:Scope -GitCommitSha $script:GitSha -ApprovedCategories @($script:Scope.categories) `
                -RunIdentity ('m6e-run-' + [guid]::NewGuid().ToString('N')) -PrivateKeyPemPath $Priv -PublicKeyPemPath $Pub `
                -IssuedUtc $IssuedUtc -ExpiresUtc $ExpiresUtc -ReadOnlyAcknowledged -AllowTestKeyForSimulationOnly:$TestKey
        }
        $script:NewStore = {
            New-XboxOSDurableReplayStore -Path (Join-Path $script:TempRoot ('auth-' + [guid]::NewGuid().ToString('N') + '\used-approvals.jsonl')) -RepoRoot $script:RepoRoot
        }
        $script:Invokers = [ordered]@{
            'Get-OsInfo'                     = { param($Context) @{ edition = 'Windows 11 Pro'; build = '26300.9457'; architecture = '64-bit'; firmware = 'UEFI'; hostLabel = 'GAMING-RIG-01' } }
            'Get-CpuVirtualization'          = { param($Context) @{ virtualizationFirmwareEnabled = $true; logicalProcessors = 16; hypervisorPresent = $true } }
            'Get-HyperVManagementPresence'   = { param($Context) @{ moduleAvailable = $true; getVmAvailable = $true; featureState = 'NotQueried' } }
            'Get-VmInventory'                = { param($Context) @{ availability = 'Available'; vms = @(@{ name = 'Secret-Prod-VM'; state = 'Off'; generation = 2 }) } }
            'Get-VmSwitchInventory'          = { param($Context) @{ availability = 'Available'; switches = @(@{ name = 'IsolatedSwitch'; type = 'Private' }) } }
            'Get-NetworkAdapters'            = { param($Context) @{ adapters = @(@{ name = 'Ethernet 2'; ifIndex = 7; status = 'Up' }) } }
            'Get-VhdMetadata'                = { param($Context) @{ vhds = @(@{ vmName = 'Secret-Prod-VM'; path = 'C:\Users\alice\VMs\prod.vhdx' }) } }
            'Get-HostResources'              = { param($Context) @{ cpuCount = 16; memoryGiB = 64; freeDiskGiB = 400 } }
            'Get-WorkspaceBoundaries'        = { param($Context) @{ evaluated = $true; workspaceRootExists = $false; workspaceCloudSynced = $false } }
            'Get-LabCredentialPrerequisites' = { param($Context) @{ labKeyCustodyDocumented = $false; productionTrustPresent = $false } }
        }
        $script:Ack = { param($a) Get-XboxOSControlledLiveOperatorAcknowledgmentText -RunIdentity ([string]$a.runIdentity) }
        $script:Run = {
            param($Approval, $Store, [System.Collections.IDictionary]$Invokers = $script:Invokers, [string]$Ack = $null, [string]$Pub = $script:OperatorPub, [scriptblock]$AsOf = $null, [switch]$TestKey)
            if ($null -eq $Ack -or $Ack -eq '') { $Ack = & $script:Ack $Approval }
            Invoke-XboxOSControlledLiveHostDiscovery -Allowlist $script:Allowlist -HostIdentity $script:HostId -DiscoveryScope $script:Scope `
                -Approval $Approval -PublicKeyPemPath $Pub -ReplayStore $Store -OperatorAcknowledgment $Ack `
                -ToolingGitState $script:CleanGit -RepoRoot $script:RepoRoot -Invokers $Invokers -AsOfUtcProvider $AsOf -AllowSimulationTestKey:$TestKey
        }
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        Reset-XboxOSAuthorizedHostDiscoveryNonceRegistry
    }

    It 'reports the M6E engine and keeps every live/global flag inactive' {
        Get-XboxOSControlledLiveDiscoveryEngineVersion | Should -Be '6.4.0-e'
        Get-XboxOSControlledLiveReplayStoreSchemaVersion | Should -Be 'host-discovery-replay-store-v1'
        Get-XboxOSAuthorizedHostDiscoveryLiveActivationEnabled | Should -BeFalse
        Get-XboxOSControlledLiveRealHostCommandsInvoked | Should -BeFalse
        Get-XboxOSControlledLiveDefaultReplayStorePath | Should -Be 'C:\XboxOS\Lab\Auth\used-approvals.jsonl'
    }

    It 'blocks by default when no approval is supplied' {
        $r = Invoke-XboxOSControlledLiveHostDiscovery -Allowlist $script:Allowlist -HostIdentity $script:HostId -DiscoveryScope $script:Scope
        $r.decision | Should -Be 'HostDiscoveryBlocked'
        $r.reportNamespace | Should -Be 'm6e'
        $r.hostDiscoveryAuthorized | Should -BeFalse
        $r.labProvisioningAuthorized | Should -BeFalse
        $r.writableServicingAuthorized | Should -BeFalse
        $r.networkIsolationVerified | Should -BeFalse
        $r.evidence.observationProvenance | Should -Be 'NotObserved'
        @($r.evidence.commands).Count | Should -Be 0
    }

    Context 'durable replay store' {
        It 'refuses store paths inside the repository or OneDrive' {
            { New-XboxOSDurableReplayStore -Path (Join-Path $script:RepoRoot 'artifacts\used.jsonl') -RepoRoot $script:RepoRoot } | Should -Throw '*repository*'
            { New-XboxOSDurableReplayStore -Path 'C:\Users\x\OneDrive\auth\used.jsonl' -RepoRoot $script:RepoRoot } | Should -Throw '*cloud*'
        }

        It 'claims an approval once and rejects nonce/run replay within a process' {
            $store = & $script:NewStore
            $a = & $script:NewApproval
            $claim = Register-XboxOSDurableApprovalClaim -Store $store -Approval $a
            $claim.sequence | Should -Be 1
            $claim.prevHash | Should -Be ('0' * 64)
            { Register-XboxOSDurableApprovalClaim -Store $store -Approval $a } | Should -Throw '*Durable replay detected*'
            (Read-XboxOSDurableReplayStore -Store $store).integrity | Should -Be 'Valid'
            (Test-XboxOSDurableApprovalClaim -Store $store -Approval $a -ClaimRecordHash $claim.recordHash).valid | Should -BeTrue
        }

        It 'rejects replay from a separate process using the exported approval file' {
            $store = & $script:NewStore
            $a = & $script:NewApproval
            $approvalPath = Export-XboxOSControlledLiveApproval -Approval $a -Path (Join-Path $script:TempRoot ('approval-' + [guid]::NewGuid().ToString('N') + '.json'))
            Register-XboxOSDurableApprovalClaim -Store $store -Approval $a | Out-Null

            $child = Join-Path $script:TempRoot 'child-replay.ps1'
            @'
param($ModulePath, $StorePath, $ApprovalPath, $RepoRoot)
Import-Module $ModulePath -Force
$store = New-XboxOSDurableReplayStore -Path $StorePath -RepoRoot $RepoRoot
$approval = Import-XboxOSControlledLiveApproval -Path $ApprovalPath
try { Register-XboxOSDurableApprovalClaim -Store $store -Approval $approval | Out-Null; 'CLAIMED' } catch { 'REJECTED: ' + $_.Exception.Message }
'@ | Set-Content -LiteralPath $child -Encoding UTF8
            $exe = (Get-Process -Id $PID).Path
            $out = & $exe -NoProfile -File $child (Join-Path $script:RepoRoot 'modules\XboxOS.Build\XboxOS.Build.psd1') $store.path $approvalPath $script:RepoRoot
            ($out -join "`n") | Should -Match 'REJECTED: Durable replay detected'
        }

        It 'fails closed when a record is modified' {
            $store = & $script:NewStore
            Register-XboxOSDurableApprovalClaim -Store $store -Approval (& $script:NewApproval) | Out-Null
            $text = [System.IO.File]::ReadAllText($store.path)
            [System.IO.File]::WriteAllText($store.path, ($text -replace '"outcome":"Claimed"', '"outcome":"Forged"'))
            (Read-XboxOSDurableReplayStore -Store $store).integrity | Should -Be 'Tampered'
            { Register-XboxOSDurableApprovalClaim -Store $store -Approval (& $script:NewApproval) } | Should -Throw '*integrity failure*'
        }

        It 'detects tail truncation and store deletion through the head anchor' {
            $store = & $script:NewStore
            Register-XboxOSDurableApprovalClaim -Store $store -Approval (& $script:NewApproval) | Out-Null
            Register-XboxOSDurableApprovalClaim -Store $store -Approval (& $script:NewApproval) | Out-Null
            $lines = [System.IO.File]::ReadAllLines($store.path)
            [System.IO.File]::WriteAllLines($store.path, @($lines[0]))
            (Read-XboxOSDurableReplayStore -Store $store).integrity | Should -Be 'Tampered'
            Remove-Item -LiteralPath $store.path -Force
            (Read-XboxOSDurableReplayStore -Store $store).integrity | Should -Be 'Tampered'
        }
    }

    Context 'independent approval verification' {
        It 'accepts a trusted operator approval and survives export/import' {
            $a = & $script:NewApproval
            $check = Test-XboxOSControlledLiveApproval -Record $a -HostIdentity $script:HostId -DiscoveryScope $script:Scope -ExpectedGitCommitSha $script:GitSha -PublicKeyPemPath $script:OperatorPub
            $check.valid | Should -BeTrue
            $check.trustedKey | Should -BeTrue
            $path = Export-XboxOSControlledLiveApproval -Approval $a -Path (Join-Path $script:TempRoot 'roundtrip.json')
            $b = Import-XboxOSControlledLiveApproval -Path $path
            (Test-XboxOSControlledLiveApproval -Record $b -HostIdentity $script:HostId -DiscoveryScope $script:Scope -ExpectedGitCommitSha $script:GitSha -PublicKeyPemPath $script:OperatorPub).valid | Should -BeTrue
        }

        It 'rejects field edits even when the original signature and payload are kept' {
            $a = & $script:NewApproval
            $a.operatorId = 'attacker'
            $check = Test-XboxOSControlledLiveApproval -Record $a -HostIdentity $script:HostId -DiscoveryScope $script:Scope -ExpectedGitCommitSha $script:GitSha -PublicKeyPemPath $script:OperatorPub
            $check.valid | Should -BeFalse
            ($check.errors -join ';') | Should -Match 'Signed payload does not match'
        }

        It 'rejects repository fixture keys for live trust' {
            $a = & $script:NewApproval -Priv $script:FixturePriv -Pub $script:FixturePub -TestKey
            $check = Test-XboxOSControlledLiveApproval -Record $a -HostIdentity $script:HostId -DiscoveryScope $script:Scope -ExpectedGitCommitSha $script:GitSha -PublicKeyPemPath $script:FixturePub
            $check.valid | Should -BeFalse
            ($check.errors -join ';') | Should -Match 'test signing keys'
        }

        It 'rejects long-lived, expired, wrong-host, and wrong-commit approvals' {
            $long = & $script:NewApproval -ExpiresUtc ([datetime]::UtcNow.AddHours(8))
            (Test-XboxOSControlledLiveApproval -Record $long -HostIdentity $script:HostId -DiscoveryScope $script:Scope -ExpectedGitCommitSha $script:GitSha -PublicKeyPemPath $script:OperatorPub).errors -join ';' | Should -Match 'lifetime exceeds'

            $a = & $script:NewApproval
            (Test-XboxOSControlledLiveApproval -Record $a -HostIdentity $script:HostId -DiscoveryScope $script:Scope -ExpectedGitCommitSha $script:GitSha -PublicKeyPemPath $script:OperatorPub -AsOfUtc ([datetime]::UtcNow.AddHours(2))).errors -join ';' | Should -Match 'expired'

            $otherHost = New-XboxOSObservedHostIdentity -OsObservation @{ hostLabel = 'OTHER'; edition = 'Windows 11 Pro'; build = '26300.9457'; architecture = '64-bit' }
            (Test-XboxOSControlledLiveApproval -Record $a -HostIdentity $otherHost -DiscoveryScope $script:Scope -ExpectedGitCommitSha $script:GitSha -PublicKeyPemPath $script:OperatorPub).errors -join ';' | Should -Match 'Host identity mismatch'
            (Test-XboxOSControlledLiveApproval -Record $a -HostIdentity $script:HostId -DiscoveryScope $script:Scope -ExpectedGitCommitSha 'deadbeef' -PublicKeyPemPath $script:OperatorPub).errors -join ';' | Should -Match 'Git commit SHA mismatch'
        }
    }

    Context 'read-only invoker gate' {
        It 'accepts every shipped live invoker and rejects mutation constructs' {
            $map = Get-XboxOSLiveReadOnlyInvokerMap
            foreach ($k in $map.Keys) {
                (Test-XboxOSReadOnlyInvokerScript -ScriptBlock $map[$k]).readOnly | Should -BeTrue -Because $k
            }
            (Test-XboxOSReadOnlyInvokerScript -ScriptBlock { New-VM -Name x }).readOnly | Should -BeFalse
            (Test-XboxOSReadOnlyInvokerScript -ScriptBlock { $c = 'Remove-VM'; & $c }).readOnly | Should -BeFalse
            (Test-XboxOSReadOnlyInvokerScript -ScriptBlock { Get-VM > C:\out.txt }).readOnly | Should -BeFalse
            (Test-XboxOSReadOnlyInvokerScript -ScriptBlock { [System.IO.File]::Delete('C:\x') }).readOnly | Should -BeFalse
        }

        It 'covers exactly the allowlisted typed operations' {
            $ids = @($script:Allowlist.allowedOperations | ForEach-Object { [string]$_.operationId }) | Sort-Object
            @((Get-XboxOSLiveReadOnlyInvokerMap).Keys | Sort-Object) | Should -Be $ids
        }

        It 'classifies missing modules as Unavailable and access failures as Unverified' {
            $nf = [System.Management.Automation.ErrorRecord]::new([System.Management.Automation.CommandNotFoundException]::new('Get-VM is not recognized'), 'x', 'ObjectNotFound', $null)
            (Get-XboxOSControlledLiveErrorClassification -ErrorRecord $nf).status | Should -Be 'Unavailable'
            $ad = [System.Management.Automation.ErrorRecord]::new([System.UnauthorizedAccessException]::new('Access is denied.'), 'x', 'PermissionDenied', $null)
            (Get-XboxOSControlledLiveErrorClassification -ErrorRecord $ad).status | Should -Be 'Unverified'
        }
    }

    Context 'activation gates' {
        It 'blocks a live (non-injected) activation in CI before any claim or command' {
            $store = & $script:NewStore
            $a = & $script:NewApproval
            $env = Test-XboxOSControlledLiveExecutionEnvironment -Environment @{ CI = 'true' } -IsElevated $false
            $env.allowed | Should -BeFalse
            $act = New-XboxOSControlledLiveDiscoveryActivation -Approval $a -HostIdentity $script:HostId -DiscoveryScope $script:Scope `
                -PublicKeyPemPath $script:OperatorPub -ReplayStore $store -OperatorAcknowledgment (& $script:Ack $a) `
                -ToolingGitState $script:CleanGit -ExecutionEnvironment $env
            $act.activated | Should -BeFalse
            ($act.blockers -join ';') | Should -Match 'CI/automation'
            (Read-XboxOSDurableReplayStore -Store $store).integrity | Should -Be 'Empty'
            Get-XboxOSControlledLiveRealHostCommandsInvoked | Should -BeFalse
        }

        It 'requires explicit acceptance of an elevated session' {
            (Test-XboxOSControlledLiveExecutionEnvironment -Environment @{} -IsElevated $true).allowed | Should -BeFalse
            (Test-XboxOSControlledLiveExecutionEnvironment -Environment @{} -IsElevated $true -OperatorAcceptsElevatedSession).allowed | Should -BeTrue
            (Test-XboxOSControlledLiveExecutionEnvironment -Environment @{} -IsElevated $false).allowed | Should -BeTrue
        }

        It 'never pairs simulation test keys with live invokers' {
            $a = & $script:NewApproval -Priv $script:FixturePriv -Pub $script:FixturePub -TestKey
            { New-XboxOSControlledLiveDiscoveryActivation -Approval $a -HostIdentity $script:HostId -DiscoveryScope $script:Scope `
                    -PublicKeyPemPath $script:FixturePub -ReplayStore (& $script:NewStore) -OperatorAcknowledgment (& $script:Ack $a) `
                    -ToolingGitState $script:CleanGit -AllowSimulationTestKey } | Should -Throw '*injected*'
        }

        It 'blocks on wrong acknowledgment, dirty tooling, and mismatched commit without consuming the approval' {
            $store = & $script:NewStore
            $a = & $script:NewApproval
            (& $script:Run $a $store -Ack 'yes').blockers -join ';' | Should -Match 'acknowledgment must exactly equal'
            $dirty = [pscustomobject]@{ gitCommitSha = $script:GitSha; verificationState = 'Dirty'; workingTreeClean = $false }
            $r = Invoke-XboxOSControlledLiveHostDiscovery -Allowlist $script:Allowlist -HostIdentity $script:HostId -DiscoveryScope $script:Scope `
                -Approval $a -PublicKeyPemPath $script:OperatorPub -ReplayStore $store -OperatorAcknowledgment (& $script:Ack $a) `
                -ToolingGitState $dirty -Invokers $script:Invokers
            $r.decision | Should -Be 'HostDiscoveryBlocked'
            ($r.blockers -join ';') | Should -Match 'VerifiedClean'
            (Read-XboxOSDurableReplayStore -Store $store).integrity | Should -Be 'Empty'
        }
    }

    Context 'controlled run with injected invokers' {
        It 'completes read-only inspection, records the durable claim, and keeps provisioning blocked' {
            $store = & $script:NewStore
            $a = & $script:NewApproval
            $r = & $script:Run $a $store
            $r.decision | Should -Be 'ReadOnlyHostInspectionCompleted'
            $r.hostDiscoveryAuthorized | Should -BeTrue
            $r.readOnlyHostInspectionCompleted | Should -BeTrue
            $r.hypervisorObserved | Should -BeTrue
            $r.independentHostObservation | Should -BeFalse
            $r.evidence.observationProvenance | Should -Be 'InjectedInvoker'
            $r.networkIsolationVerified | Should -BeFalse
            $r.labProvisioningAuthorized | Should -BeFalse
            $r.writableServicingAuthorized | Should -BeFalse
            $r.provisioningDecision | Should -Be 'LabProvisioningBlocked'
            @($r.evidence.commands).Count | Should -Be 10
            @($r.evidence.commands | Where-Object { $_.operationId -eq 'Get-DismMountMetadata' }).Count | Should -Be 0
            $r.evidence.commands[0].commandSha256 | Should -Match '^[0-9A-Fa-f]{64}$'
            $state = Read-XboxOSDurableReplayStore -Store $store
            $state.integrity | Should -Be 'Valid'
            @($state.entries | ForEach-Object { $_.eventType }) | Should -Be @('ApprovalClaimed', 'RunCompleted')
            $state.entries[1].outcome | Should -Be 'ReadOnlyHostInspectionCompleted'
            Get-XboxOSControlledLiveRealHostCommandsInvoked | Should -BeFalse
        }

        It 'redacts host, VM, adapter, and user-path metadata from the report' {
            $r = & $script:Run (& $script:NewApproval) (& $script:NewStore)
            $json = @($r.evidence.commands | ForEach-Object { $_.redactedData }) | ConvertTo-Json -Depth 16
            $json | Should -Not -Match 'Secret-Prod-VM'
            $json | Should -Not -Match 'GAMING-RIG-01'
            $json | Should -Not -Match 'alice'
            $json | Should -Not -Match 'Ethernet 2'
        }

        It 'refuses to rerun a consumed approval' {
            $store = & $script:NewStore
            $a = & $script:NewApproval
            (& $script:Run $a $store).decision | Should -Be 'ReadOnlyHostInspectionCompleted'
            $again = & $script:Run $a $store
            $again.decision | Should -Be 'HostDiscoveryBlocked'
            ($again.blockers -join ';') | Should -Match 'Durable replay detected'
        }

        It 'aborts when an injected invoker attempts a mutation' {
            $bad = [ordered]@{}
            foreach ($k in $script:Invokers.Keys) { $bad[$k] = $script:Invokers[$k] }
            $bad['Get-VmSwitchInventory'] = { param($Context) Set-VMSwitch -Name 'IsolatedSwitch' -SwitchType External }
            $store = & $script:NewStore
            $r = & $script:Run (& $script:NewApproval) $store -Invokers $bad
            $r.decision | Should -Be 'DiscoveryAborted'
            ($r.blockers -join ';') | Should -Match 'Read-only invoker gate rejected'
            (Read-XboxOSDurableReplayStore -Store $store).entries[-1].outcome | Should -Be 'DiscoveryAborted'
        }

        It 'revalidates the approval before each operation and aborts after expiry' {
            $a = & $script:NewApproval -ExpiresUtc ([datetime]::UtcNow.AddMinutes(30))
            $asOf = { param($op) if ($op -eq 'Get-HostResources') { [datetime]::UtcNow.AddHours(1) } else { [datetime]::UtcNow } }
            $r = & $script:Run $a (& $script:NewStore) -AsOf $asOf
            $r.decision | Should -Be 'DiscoveryAborted'
            ($r.blockers -join ';') | Should -Match "Get-HostResources.*expired"
            @($r.evidence.commands | Where-Object { $_.operationId -eq 'Get-HostResources' }).Count | Should -Be 0
        }

        It 'records access failures as Unverified without elevation' {
            $denied = [ordered]@{}
            foreach ($k in $script:Invokers.Keys) { $denied[$k] = $script:Invokers[$k] }
            $denied['Get-VmInventory'] = { param($Context) throw 'You do not have the required permission to complete this task.' }
            $r = & $script:Run (& $script:NewApproval) (& $script:NewStore) -Invokers $denied
            $r.decision | Should -Be 'ReadOnlyHostInspectionCompleted'
            $vm = @($r.evidence.commands | Where-Object { $_.operationId -eq 'Get-VmInventory' })[0]
            $vm.status | Should -Be 'Unverified'
            $vm.exitStatus | Should -Be 'AccessDenied'
            $vm.elevationAttempted | Should -BeFalse
            $r.evidence.unverifiedOperations | Should -Contain 'Get-VmInventory'
        }

        It 'can only use fixture keys on the injected path when explicitly allowed' {
            $a = & $script:NewApproval -Priv $script:FixturePriv -Pub $script:FixturePub -TestKey
            (& $script:Run $a (& $script:NewStore) -Pub $script:FixturePub).decision | Should -Be 'HostDiscoveryBlocked'
            $a2 = & $script:NewApproval -Priv $script:FixturePriv -Pub $script:FixturePub -TestKey
            $r = & $script:Run $a2 (& $script:NewStore) -Pub $script:FixturePub -TestKey
            $r.decision | Should -Be 'ReadOnlyHostInspectionCompleted'
            $r.evidence.trustedKey | Should -BeFalse
        }
    }

    Context 'transactions and reports' {
        It 'never reaches provisioning or writable states' {
            { Assert-XboxOSControlledLiveTransactionTransition -From 'ReadOnlyHostInspectionCompleted' -To 'LabProvisioning' } | Should -Throw
            { Assert-XboxOSControlledLiveTransactionTransition -From 'HostDiscoveryAuthorized' -To 'WritableExecution' } | Should -Throw
            { Assert-XboxOSControlledLiveTransactionTransition -From 'LiveDiscoveryPlanned' -To 'ReadOnlyInspectionRunning' } | Should -Throw
        }

        It 'rejects reports that claim isolation or provisioning' {
            { Assert-XboxOSControlledLiveDiscoverySafetyInvariants -Report ([pscustomobject]@{ networkIsolationVerified = $true }) } | Should -Throw
            { Assert-XboxOSControlledLiveDiscoverySafetyInvariants -Report ([pscustomobject]@{ labProvisioningAuthorized = $true }) } | Should -Throw
        }

        It 'saves m6e reports only under m6e stems' {
            $r = & $script:Run (& $script:NewApproval) (& $script:NewStore)
            $out = Join-Path $script:TempRoot 'reports'
            $saved = Save-XboxOSControlledLiveDiscoveryReport -Report $r -OutputDirectory $out
            Test-Path -LiteralPath $saved.JsonPath | Should -BeTrue
            (Get-Content -LiteralPath $saved.MarkdownPath -Raw) | Should -Match 'ReadOnlyHostInspectionCompleted'
            { Save-XboxOSControlledLiveDiscoveryReport -Report $r -OutputDirectory $out -Stem 'XboxOS11-host-lab-discovery-m6d' } | Should -Throw
        }
    }
}
