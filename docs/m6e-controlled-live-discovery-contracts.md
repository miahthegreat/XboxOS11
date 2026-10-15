# Milestone 6E — Controlled Live Read-Only Host Discovery Contracts (Gate A)

**Status:** Gate A implemented. Gate B (one operator-controlled run) is a manual procedure. Merging this code never runs live discovery.

Design parent: [m6e-controlled-live-discovery-design.md](m6e-controlled-live-discovery-design.md)

## Engine and schemas

| Contract | Value |
|----------|-------|
| Engine | `6.4.0-e` |
| Module | `0.6.5` |
| Approval (reused from M6D) | `host-discovery-real-approval-v1`, layer `HostDiscoveryReal` |
| Durable replay store | `host-discovery-replay-store-v1` |
| Per-run activation | `host-discovery-live-activation-v1` |
| Evidence / report | `host-discovery-live-evidence-v1` / `host-discovery-live-report-v1`, namespace **`m6e`** |
| Transaction | `host-discovery-live-transaction-v1` |

Module file: `modules/XboxOS.Build/ControlledLiveDiscovery.ps1`. Tests: `tests/ControlledLiveDiscovery.Tests.ps1`.

## Gate A control matrix

| Control (design) | Implementation |
|------------------|----------------|
| Explicit per-run human authorization | `-OperatorAcknowledgment` must equal `I authorize read-only host discovery run <runIdentity>` exactly (case-sensitive) |
| Trusted non-test approval key | Every `*public*.pem` under `tests/Fixtures` is a forbidden fingerprint; fixture keys only work with injected invokers **and** `-AllowSimulationTestKey` |
| Exact host identity binding | Approval `hostIdentityKey` must equal the observed host identity (`New-XboxOSObservedHostIdentity`) |
| Clean and verified Git commit | Activation requires `VerifiedClean` tooling state **and** commit equal to the approval commit |
| Approved operation scope | Each operation's category must be in `approvedCategories`; scope digest must match |
| Single-use run identity | Durable claim rejects a reused nonce, run identity, or binding hash |
| Durable replay prevention across processes | Append-only, hash-chained JSONL store with exclusive file lock and head anchor (below) |
| Short approval expiration | Lifetime ≤ 4 hours; issued-in-future (> 5 min skew) rejected; expiry checked before every operation |
| Independent authorization validation | `Test-XboxOSControlledLiveApproval` is separate from the executor and never consults process-local registries |
| Signed fields cannot drift | Verifier recomputes the signing payload from record fields and requires byte equality with the signed payload |
| Read-only command allowlist | Typed operation IDs from `config/host-discovery-allowlist.json` plus a static AST gate over each invoker script |
| Per-operation revalidation | Approval, durable claim, and store integrity re-checked immediately before every operation |
| Permission failures | Classified `Unverified` / `AccessDenied`; missing modules `Unavailable` / `ModuleMissing`; never invented empty inventories |
| Non-elevated default | Elevated sessions blocked unless `-OperatorAcceptsElevatedSession` |
| No automatic privilege escalation | No code path requests elevation; `elevationAttempted` is always `false` |
| No CI execution | Live (non-injected) activation is blocked when `CI`, `GITHUB_ACTIONS`, or `TF_BUILD` is set |
| Redaction | Host labels, VM names, adapter names, switch names, and paths redacted with per-run stable pseudonyms |
| No mutation / provisioning | `LabProvisioning` / `WritableExecution` transitions unreachable; report invariants reject any provisioning, servicing, or isolation claim |

## Durable replay store

Default path: `C:\XboxOS\Lab\Auth\used-approvals.jsonl` (refused inside the repository or any cloud-synchronized folder).

- One canonical JSON record per line: `schemaVersion, sequence, eventType, nonce, runIdentity, bindingHash, hostIdentityKey, gitCommitSha, publicKeyFingerprint, issuedUtc, expiresUtc, recordedUtc, outcome, prevHash, recordHash`.
- `recordHash` = SHA-256 of the exact line with `recordHash` blanked; `prevHash` chains to the previous record (genesis = 64 zeros).
- `<store>.head` holds `sequence|recordHash` of the last record so tail truncation and whole-file deletion are detected.
- Claims are made under an exclusive `FileShare.None` lock; the chain is verified before every append. Any integrity error fails closed.
- Event types: `ApprovalClaimed` (before the first observation) and `RunCompleted` (outcome `ReadOnlyHostInspectionCompleted` or `DiscoveryAborted`).
- No private keys, tokens, or signatures are stored.

Residual risk: an attacker with write access who deletes both the store and its head anchor resets replay history. Store custody (NTFS ACLs, backups) is an operator responsibility; see [m6e-unresolved-risks](#remaining-risks).

## Read-only invoker gate

`Get-XboxOSLiveReadOnlyInvokerMap` defines one fixed script per allowlisted operation. `Test-XboxOSReadOnlyInvokerScript` rejects:

- Any command outside: `Get-CimInstance, Get-ItemProperty, Get-Module, Get-Command, Get-VM, Get-VMSwitch, Get-VMHardDiskDrive, Get-VMNetworkAdapter, Get-NetAdapter, Get-PSDrive, Get-WindowsImage, Test-Path, Select-Object, Where-Object, ForEach-Object, Measure-Object, Sort-Object, Test-XboxOSCloudSynchronizedPath`
- Dynamic command names (`& $name`) and dot-sourcing
- .NET method calls other than `Round, ToString, Trim, ToLowerInvariant, ToUpperInvariant, Contains, Count, Sum`
- `$env:` / `$global:` / `$script:` / provider-scoped assignments
- File redirection

The gate runs in tests over every shipped invoker and again immediately before each operation executes.

## Decisions and distinct safety conditions

| Report field | Meaning |
|--------------|---------|
| `decision` | `HostDiscoveryBlocked`, `ReadOnlyHostInspectionCompleted`, or `DiscoveryAborted` |
| `hostDiscoveryAuthorized` | Every Gate A check passed and the durable claim was recorded |
| `readOnlyHostInspectionCompleted` | All approved operations ran under that claim |
| `hypervisorObserved` | Hyper-V management module observed present |
| `independentHostObservation` | `true` only for live invokers (never in CI) |
| `networkIsolationVerified` | Always `false` — inventory alone cannot prove isolation |
| `labProvisioningAuthorized` / `writableServicingAuthorized` | Always `false` |

## Operator procedure (Gate B)

1. Generate an operator key outside the repo: `scripts/New-ControlledLiveDiscoverySigningKey.ps1` (default `C:\XboxOS\Lab\Keys`).
2. From a clean checkout, issue one approval: `scripts/New-ControlledLiveDiscoveryApproval.ps1 -OperatorId <id> -PrivateKeyPemPath … -PublicKeyPemPath … -ObserveHostIdentity`.
3. Review the checklist without observing the host: `scripts/Invoke-ControlledLiveHostDiscovery.ps1 -ApprovalPath … -PublicKeyPemPath … -ShowChecklistOnly`.
4. Run once, non-elevated, with the exact acknowledgment printed by step 2: `… -OperatorAcknowledgment 'I authorize read-only host discovery run <runIdentity>'`.
5. Review the `m6e` report in `C:\XboxOS\Logs`. The approval is now consumed; a rerun is blocked.

Exit codes: `0` completed, `2` blocked, `3` aborted.

## Remaining risks

1. Store and head deletion together resets replay history (custody/ACL control, not cryptographic).
2. `Get-VM` and related cmdlets usually need Hyper-V Administrators membership; non-elevated runs typically report those as `Unverified`.
3. The AST gate covers the shipped invoker scripts. It does not sandbox cmdlets those scripts call; it relies on those cmdlets being read-only `Get-*` APIs.
4. A Gate B run has **not** been executed as part of this milestone.
