# Milestone 6B — VM Isolation Policy

**Status:** Implemented as offline validation against topology. Not validated on a real hypervisor.

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

`Test-XboxOSLabVmIsolationPolicy` returns a versioned `lab-isolation-v1` result. Failures fail closed into `LabProvisioningBlocked` / `RecoveryRequired` simulation decisions.
