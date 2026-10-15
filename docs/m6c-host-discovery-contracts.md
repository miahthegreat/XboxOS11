# Milestone 6C — Host Discovery Contracts

**Status:** Implemented (MockedSimulation only). Real-host inspection remains unauthorized.

## Engine and schemas

| Item | Value |
|------|-------|
| Engine | `6.2.0-c` |
| Module | `0.6.3` |
| Host identity | `host-identity-v1` |
| Approval | `host-discovery-approval-v1` |
| Scope | `host-discovery-scope-v1` |
| Allowlist | `host-discovery-allowlist-v1` |
| Isolation observations | `host-discovery-isolation-v1` |
| Evidence | `host-discovery-evidence-v1` / namespace `m6c` |
| Report | `host-discovery-report-v1` |
| Transaction | `host-discovery-transaction-v1` |

## Approval gate

`HostDiscovery` is a distinct approval layer. It must not reuse M6A operator consent, M6B trust-policy validation, or Layer D. Binding includes operator id, host identity key, scope digest, Git SHA, approved categories, read-only acknowledgment, nonce, and expiry.

Default decision: **`HostDiscoveryBlocked`**.

## Adapter

`New-XboxOSMockHostDiscoveryAdapter` mode is **`MockedSimulation` only**. No automatic real-host switch. Commands are allowlisted in `config/host-discovery-allowlist.json`; denied patterns reject side-effecting operations. No arbitrary shell executor is exposed.

## Isolation

`Test-XboxOSHostDiscoveryIsolationObservations` evaluates independent criteria. A switch named `IsolatedSwitch` or a Private/Internal type is **not** sufficient for `ActualIsolationVerified=True`. Mock/fixture observations cannot produce production verification.

## CLI

`scripts/Test-HostLabDiscovery.ps1` — default blocked; fixture simulation via `-Simulation -AllowMockedApproval`; exit code `2` when inspection remains blocked.
