# Milestone 6D Completion Baseline

Milestone 6D is **complete as a tested but operationally inactive read-only host-discovery implementation**. It delivered typed allowlisted adapters, a distinct `HostDiscoveryReal` approval layer, redaction, `m6d` evidence custody, and comprehensive mocked failure coverage — without executing live host inspection, provisioning infrastructure, changing networking, running DISM, or enabling Layer D.

**Acceptance of Milestone 6D must not be interpreted as permission to inspect a production host, provision virtual machines, or modify Windows images.** Live host inspection remains unauthorized until a separately approved future milestone (proposed: Milestone 6E).

## Merge and CI

| Item | Value |
|------|-------|
| Pull request | [#16](https://github.com/miahthegreat/XboxOS11/pull/16) |
| Validated PR HEAD | `6b7ee6b02f0cd0e5c07f1692d5475344d65240f8` |
| Merge commit on `main` | `8418035cdd1f1bcbef49f0e2027ae018d380e798` |
| Pre-merge Validate CI | [run 38693685482](https://github.com/miahthegreat/XboxOS11/actions/runs/38693685482) — success on `6b7ee6b` |
| Post-merge Validate CI (`main`) | [run 38694438524](https://github.com/miahthegreat/XboxOS11/actions/runs/38694438524) — success on `8418035` |
| Automated tests at closure | Parser **0** errors; Pester **229** passed / 0 failed / 0 skipped; PSScriptAnalyzer **0** errors |

Local `main` and `origin/main` both point at `8418035` after fast-forward. Working tree clean at merge closure.

## Engine and schemas

| Contract | Version / value |
|----------|-----------------|
| Authorized host discovery engine | `6.3.0-d` |
| Module | `0.6.4` |
| Host identity (shared) | `host-identity-v1` |
| HostDiscoveryReal approval | `host-discovery-real-approval-v1` |
| Discovery scope (real-host flag) | `host-discovery-scope-v1` with `realHostAllowed=true` |
| Command allowlist | `host-discovery-allowlist-v1` (catalog `6.3.0-d`) |
| Operation catalog | `host-discovery-operation-v1` |
| Redaction | `host-discovery-redaction-v1` |
| Evidence | `host-discovery-real-evidence-v1` / namespace `m6d` |
| Report | `host-discovery-real-report-v1` |
| Transaction | `host-discovery-real-transaction-v1` |

Supporting docs:

- [m6d-readonly-host-adapter.md](m6d-readonly-host-adapter.md)
- [m6d-operator-authorization.md](m6d-operator-authorization.md)
- [m6d-isolation-evidence.md](m6d-isolation-evidence.md)
- [m6d-operational-runbook.md](m6d-operational-runbook.md)
- [m6d-unresolved-risks.md](m6d-unresolved-risks.md)
- Design parent: [m6d-authorized-readonly-host-inspection-design.md](m6d-authorized-readonly-host-inspection-design.md)

## Provider interfaces

| Mode | Provider | Status at M6D closure |
|------|----------|------------------------|
| `AuthorizedMockReadOnly` | `MockCommandProvider` | Used by CI and default CLI simulation path |
| `RealHostReadOnly` | `RealHostCommandProvider` | Constructible; **execution blocked** while live activation is False |

`Get-XboxOSAuthorizedHostDiscoveryLiveActivationEnabled` remains **False**. No automatic switch from mock to live.

## Command allowlist

Catalog: `config/host-discovery-allowlist.json`.

- Typed operation IDs only (OS info, CPU virt, Hyper-V presence, VM/switch inventory, adapters, VHD metadata, resources, workspace boundaries, optional DISM mount metadata, credential prerequisites)
- Denied mutation patterns (`New-VM`, switch/VHD mutation, feature enable/disable, Mount-WindowsImage, `Invoke-Expression`, `netsh`, etc.)
- Arbitrary parameters and shell metacharacters rejected via `Test-XboxOSHostDiscoveryOperationSpec`
- No generic shell / unrestricted process executor

## Approval binding and test-key restrictions

Layer **`HostDiscoveryReal`** binds:

- Operator identity
- Host identity key
- Tooling Git SHA
- Approved categories / scope digest
- Approval expiry
- Unique nonce
- Single-run identity
- Read-only acknowledgment
- Public key fingerprint + RSA signature

Rejected for live trust:

- Absent approval (default → `HostDiscoveryBlocked`)
- M6C `HostDiscovery` / `host-discovery-approval-v1` mock records
- Repository fixture test keys without `AllowTestKeyForSimulationOnly` (and never under `RequireTrustedLabSigningIdentity`)
- Expired, replayed, wrong-host, wrong-scope, wrong-Git-SHA, invalid signature

Approval is revalidated before each permitted mock operation on the authorized simulation path.

## Redaction and Unavailable / Unverified

- `Protect-XboxOSHostDiscoverySensitiveValue` / `ConvertTo-XboxOSHostDiscoveryRedactedInventory` redact hostnames, VM names, adapter IDs, IPs, user paths, credential metadata while preserving stable pseudonyms within a run
- Missing Hyper-V tools → inventory `Unavailable` / Unknown (not invented empty hosts)
- Insufficient permissions → `Unverified` (no automatic elevation)
- Isolation remains `NetworkIsolationNotVerified` for mock/fixture observations; switch name `IsolatedSwitch` is not proof

## Default CLI and live-inspection inability

- CLI: `scripts/Test-AuthorizedHostDiscovery.ps1`
- Default decision: **`HostDiscoveryBlocked`**
- Dual switches `-Simulation` + `-AllowMockedAuthorizedApproval` exercise mocks only
- `RealHostReadOnly` adapter operations throw while live activation is False
- Current milestone **cannot** perform live host inspection

## Disabled execution and mutation flags

All remain **False** at closure:

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
| `liveHostInspectionActivated` | `False` |

## Remaining security limitations

1. Process-local nonce/run-identity registries are not durable across processes — insufficient for live multi-process replay prevention (addressed in proposed Milestone 6E).
2. No live host validation — real provider behavior unproven.
3. Elevation for some read-only queries must remain human-driven if ever authorized later.
4. Operators may misread mocked authorized simulation success as live clearance — terminal decision remains `HostDiscoveryBlocked` for live inspection.
5. Isolation/firewall/guest connectivity often remain Unverified even when switches are named.

## Distinction: implementation pass vs live inspection authorization

| Question | Answer |
|----------|--------|
| Did Milestone 6D merge with green CI and documented contracts? | **Yes** |
| May tooling inspect the live host based on this pass? | **No** |
| Can simulated approvals / test keys authorize live inspection? | **No** |
| Can RealHostReadOnly execute while live activation is False? | **No** |
| May provisioning or Layer D proceed? | **No** |

Proposed next phase (documentation only): [m6e-controlled-live-discovery-design.md](m6e-controlled-live-discovery-design.md).
