# Milestone 6B — VM Isolation Policy

**Status:** Implemented as **policy** validation against declared topology (`PolicyValidated` / `ConfigurationDeclared`). Not inspected on a real hypervisor (`HypervisorNotInspected`, `NetworkIsolationNotVerified`). `actualIsolationVerified` is always false in Milestone 6B.

## Defaults (must hold)

| Rule | Default |
|------|---------|
| Dedicated disposable VM | Required |
| Production domain membership | Forbidden |
| Inherited production / host credentials | Forbidden |
| Unrestricted shared folders | Forbidden |
| Production network bridge | Forbidden |
| Host administrative shares | Forbidden |
| Outbound network | Explicit allowlist required |
| Guest credentials | `EphemeralLabOnly`; secrets not stored in repo |
| Validation posture | Offline by default |

## Offline vs online Microsoft services

Default topology sets `offlineValidationDefault=true`. Tests that need Microsoft Store, Xbox authentication, or Windows Update connectivity require a separately reviewed connectivity profile. Milestone 6B records those cases as `MissingEvidence` or notes them as EnvironmentLimited — it does **not** invent Passed results.

## Network allowlist (catalog example)

Documented allowlist entries (not activated as host firewall rules):

- `store.microsoft.com`
- `xboxlive.com`
- `login.live.com`
- `update.microsoft.com`

No host networking changes are performed by Milestone 6B tooling.

## Test retention

Explicit test-data retention rules live in cleanup ownership: owned disposable artifacts only; global DISM cleanup forbidden; unload of unrelated registry hives forbidden.

## Implementation

`Test-XboxOSLabVmIsolationPolicy` returns a versioned `lab-isolation-v1.1` result with explicit statuses:

| Field | Meaning |
|-------|---------|
| `policyValidationStatus` | `PolicyValidated` or `PolicyInvalid` |
| `configurationStatus` | Always `ConfigurationDeclared` for catalog topology |
| `hypervisorInspectionStatus` | Always `HypervisorNotInspected` (no hypervisor queries) |
| `networkIsolationVerificationStatus` | Always `NetworkIsolationNotVerified` |
| `environmentLimitationStatus` | `EnvironmentLimited` |
| `futureEvidenceSlots` | Placeholders for VM / switch / firewall / networking evidence |

A valid declared `IsolatedSwitch` policy does **not** imply a virtual switch exists or that isolation was proven. Failures fail closed into `LabProvisioningBlocked` / `RecoveryRequired` simulation decisions.
