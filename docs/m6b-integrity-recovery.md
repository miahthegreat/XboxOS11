# Milestone 6B — Integrity and Recovery

**Status:** Simulated transaction state machine only. No real infrastructure provisioning.

## States

Allowed simulation states:

- `InfrastructurePlanned`
- `ConfigurationValidated`
- `AwaitingReview`
- `LabProvisioningBlocked`
- `SimulationReady`
- `SimulationCompleted`
- `Aborted`
- `RecoveryRequired`

Named but **unreachable** (fail closed): `RealProvisioning`, `WritableExecution`, `LiveMutation`.

## Happy path (still blocked)

`InfrastructurePlanned` → `ConfigurationValidated` → (`AwaitingReview`) → `SimulationReady` → `SimulationCompleted` → **`LabProvisioningBlocked`**.

No transition may reach real provisioning or writable execution.

## Simulated fail-closed cases

`Invoke-XboxOSLabSimulatedFailure` covers:

| Failure | Outcome |
|---------|---------|
| ISO hash mismatch | `RecoveryRequired` |
| Workspace ownership mismatch | `RecoveryRequired` |
| VM identity mismatch | `RecoveryRequired` |
| Snapshot mismatch | `RecoveryRequired` |
| Stale mount metadata | `RecoveryRequired` |
| Untracked registry hive | `RecoveryRequired` |
| Evidence substitution | `RecoveryRequired` |
| Interrupted experiment | `RecoveryRequired` |
| Cleanup verification failure | `RecoveryRequired` |

Guarantees during failure simulation:

- No global DISM cleanup
- No unload of unrelated registry hives
- No real provisioning attempt
- Layer D remains disabled

## Recovery expectations

Recovery requirements recorded in evidence manifests instruct operators to leave the source ISO and host OS untouched, discard only owned disposable artifacts, and retain `m6b` evidence without overwriting M1–M6A baselines.
