# Milestone 6C Completion Baseline

Milestone 6C is **complete as a mocked, read-only host-discovery framework**. It delivered versioned HostDiscovery approval, an allowlisted MockedSimulation adapter, independent isolation-observation evaluation, host inventory placeholders with honest Unavailable/Unknown handling, `m6c` evidence custody, and a default-blocked CLI — without enumerating the live host, provisioning infrastructure, changing networking, running DISM, or enabling Layer D.

**Acceptance of Milestone 6C must not be interpreted as permission to inspect a production host, provision virtual machines, or modify Windows images.** Real-host inspection remains unauthorized until a separately approved future milestone (proposed: Milestone 6D).

## Merge and CI

| Item | Value |
|------|-------|
| Pull request | [#14](https://github.com/miahthegreat/XboxOS11/pull/14) |
| Validated PR HEAD | `c8fde926df943e5529083cf34e12440f72432f40` |
| Merge commit on `main` | `43b66b09b22a21f4c8a34d5d3f6c227e24c8ba2f` |
| Pre-merge Validate CI | [run 38691052439](https://github.com/miahthegreat/XboxOS11/actions/runs/38691052439) — success on `c8fde92` |
| Post-merge Validate CI (`main`) | [run 38692219388](https://github.com/miahthegreat/XboxOS11/actions/runs/38692219388) — success on `43b66b0` |
| Automated tests at closure | Parser **0** errors (48 files); Pester **213** passed / 0 failed / 0 skipped; PSScriptAnalyzer **0** errors / **88** warnings |

Local `main` and `origin/main` both point at `43b66b0` after fast-forward. Working tree clean at merge closure.

## Engine and schemas

| Contract | Version / value |
|----------|-----------------|
| Host discovery engine | `6.2.0-c` |
| Module | `0.6.3` |
| Host identity | `host-identity-v1` |
| HostDiscovery approval | `host-discovery-approval-v1` |
| Discovery scope | `host-discovery-scope-v1` |
| Command allowlist | `host-discovery-allowlist-v1` |
| Hypervisor capabilities | `host-discovery-hypervisor-v1` |
| VM inventory | `host-discovery-vm-inventory-v1` |
| Switch inventory | `host-discovery-switch-v1` |
| Host resources | `host-discovery-resource-v1` |
| Isolation observations | `host-discovery-isolation-v1` |
| Evidence | `host-discovery-evidence-v1` / namespace `m6c` |
| Report | `host-discovery-report-v1` |
| Transaction | `host-discovery-transaction-v1` |

Supporting docs:

- [m6c-host-discovery-contracts.md](m6c-host-discovery-contracts.md)
- Design parent: [m6c-real-host-lab-discovery-design.md](m6c-real-host-lab-discovery-design.md)

## Read-only command allowlist

Catalog: `config/host-discovery-allowlist.json`.

- Explicit allowed operation IDs (OS info, CPU virt, Hyper-V presence, VM/switch inventory, adapters, VHD metadata, resources, workspace boundaries, DISM mount metadata, credential prerequisites)
- Denied patterns for mutation (`New-VM`, `Enable-WindowsOptionalFeature`, `Mount-WindowsImage`, `netsh`, etc.)
- No generic arbitrary PowerShell/shell executor

## Mocked discovery adapter

| Property | Closure result |
|----------|----------------|
| Adapter mode | **`MockedSimulation`** |
| Automatic real-host switch | **Disabled** |
| Real host commands invoked | **False** |
| Live `Get-VM` / switch enumeration in CI | **Not performed** |

Fixture simulation with mocked approval requires explicit CLI switches: `-Simulation -AllowMockedApproval`.

## Decision and approval

| Outcome | Value |
|---------|-------|
| Default decision | **`HostDiscoveryBlocked`** |
| Mocked approval + simulation | Still **`HostDiscoveryBlocked`** for real inspection; simulation may reach `DiscoverySimulated` / `EvidenceIncomplete` before structural block |
| Approval layer | Distinct **`HostDiscovery`** (not M6A consent, M6B trust-policy, or Layer D) |
| Binding | Operator id, host identity key, scope digest, Git SHA, approved categories, read-only acknowledgment, nonce, expiry |
| Replay / expiry / mismatch | Fail closed → `RecoveryRequired` / blocked |

## Unknown / Unavailable handling

| Condition | Representation |
|-----------|----------------|
| Hyper-V management tools unavailable | `Unavailable` (not empty inventory) |
| VM inventory when `Get-VM` unavailable | `availability=Unavailable`, `vms=$null` — **never assumed empty host** |
| Switch inventory unavailable | `Unavailable` / isolation criteria Unverified |
| Firewall evidence absent | `Unavailable` |
| Incomplete observations | `EvidenceIncomplete` / completeness Partial or Incomplete |

## Isolation verification

| Field | Closure result |
|-------|----------------|
| `ActualIsolationVerified` | **`False`** for fixture/mock observations |
| `NetworkIsolationVerificationStatus` | **`NetworkIsolationNotVerified`** |
| Switch named `IsolatedSwitch` | **Not proof** of isolation |
| Private/Internal observed type | Necessary but **not sufficient** |
| Fixture claiming production verification | Rejected |

## Evidence custody

- Report namespace: **`m6c`**
- Captures tooling Git SHA, host identifier (redacted label), scope digest, timestamps, command classifications, source type (`FixtureDerived`), evidence hashes, approval binding, M5/M6A/M6B references where supplied
- Save path refuses overwrite of M1–M6B baseline stems and OneDrive output roots
- Prior baselines under `C:\XboxOS\Logs` remain untouched

## Hard safety invariants (always False)

| Flag | Value |
|------|-------|
| `realDismExecutionEnabled` | `False` |
| `modifyingCommandsInvoked` | `False` |
| `executionAuthorized` | `False` |
| `servicingAuthorized` | `False` |
| `experimentalMutationEnabled` | `False` |
| `experimentalExecutionAuthorized` | `False` |
| `labRealProvisioningEnabled` | `False` |
| `labHypervisorCommandsInvoked` | `False` |
| `layerDActivated` | `False` |
| `hostDiscoveryRealHostCommandsInvoked` | `False` |
| `realHostInspectionEnabled` | `False` |

## Outstanding risks

1. No live host validation — MockedSimulation only; real-host behavior unproven.
2. Isolation remains unverified until independently observed evidence exists (proposed Milestone 6D).
3. Some discovery domains may require elevation on real hosts — elevation must never be automated.
4. Sensitive VM/network names need redaction policy when live inspection is later authorized.
5. Operators may misread a successful mocked run as host-inspection authorization — decision enums remain explicit (`HostDiscoveryBlocked`).

## Distinction: framework pass vs host inspection authorization

| Question | Answer |
|----------|--------|
| Did Milestone 6C merge with green CI and documented contracts? | **Yes** |
| May tooling inspect the live host based on this pass? | **No** |
| Does mocked HostDiscovery approval enable real-host commands? | **No** |
| Does Unavailable Hyper-V imply zero VMs on the host? | **No** |
| Does fixture isolation observation set ActualIsolationVerified? | **No** |
| May provisioning or Layer D proceed? | **No** |

Proposed next phase (documentation only): [m6d-authorized-readonly-host-inspection-design.md](m6d-authorized-readonly-host-inspection-design.md).
