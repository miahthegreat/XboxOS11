# Milestone 3 — Execution Safety Contracts

Milestone 3 defines the **non-executing** safety architecture that will eventually control writable Windows image servicing. No modifying DISM is available in this milestone.

## Versions

| Contract | Version |
|----------|---------|
| Approval schema | `approval-v1` |
| Drift schema | `drift-v1` |
| Dependency schema | `dependency-v1` |
| Transaction schema | `transaction-v1` |
| Engine coordination | Works with plan engine `2.1.0` / `plan-hash-v1` |

## Hard guarantees

| Flag | Milestone 3 value |
|------|-------------------|
| `realDismExecutionEnabled` | Always `false` (no enable switch) |
| `modifyingCommandsInvoked` | Always `false` |
| `executionAuthorized` (real) | Always `false` |
| `simulatedAuthorizationResult` | Explicit simulation label only — never permission for real DISM |

`PendingOperatorApproval` from Milestone 2 is **not** an approval record.

## Approval contract (`approval-v1`)

An approval binds to:

1. Exact plan `contentHash`
2. `hashSchemaVersion`
3. Plan `engineVersion`
4. Source ISO SHA256
5. Exact edition name and image index
6. Source build number and DisplayVersion
7. Inventory fingerprint
8. Manifest fingerprints (remove-apps, disable-features, compatibility)
9. Approved operation IDs and exact target identities
10. Approval timestamp (UTC) and expiration (UTC)
11. Operator identifier (non-secret)
12. Approval scope and intended environment

**Invalidation:** any bound value change ⇒ approval `Invalidated` / validation fail-closed.

**States:** `NotRequested` · `Pending` · `Approved` · `Rejected` · `Expired` · `Revoked` · `Invalidated`

Approvals must not contain secrets. Recording an approval never triggers execution.

**Authentication limitation (Milestone 3):** Local JSON approval records are **not** cryptographically authenticated. Tampering is detectable only via binding-hash recomputation against a trusted plan/inventory. A future milestone must require signed or attested approval records before any writable servicing is considered.

## Drift validation (`drift-v1`)

Compares a candidate plan (+ optional approval) against a freshly supplied inventory snapshot (fixtures / simulated evidence only in M3).

Checks: source image fingerprint, edition/build, AppX identities, feature states, package inventory, manifest fingerprints, engine/hash schema compatibility, operation targets/current states, protection rules, dependency completeness.

**Results:** `Match` · `DriftDetected` · `MissingEvidence` · `IncompatibleSchema` · `ProtectedTarget` · `ValidationError`

All non-`Match` results fail closed. A prior report claiming success never substitutes for verified inventory evidence.

## Dependency validation (`dependency-v1`)

Distinguishes:

| Outcome | Meaning |
|---------|---------|
| `Verified` | Supporting evidence proves dependency safety for the operation set |
| `KnownConflict` | Evidence shows a dependency conflict |
| `Unknown` | Dependencies not established (M2 Eligible default) |
| `MissingEvidence` | Required dependency evidence absent |
| `Unsupported` | Validator cannot evaluate the requested graph |

Operator approval **must not** override unresolved critical dependency outcomes (`Unknown`, `MissingEvidence`, `KnownConflict`, `Unsupported` when critical).

Protected Xbox / Store / Gaming Services / Game Bar / security / networking / graphics / audio / servicing identities always outrank candidates.

Never declare a dependency graph complete without supporting evidence.

## Compatibility with Milestone 2

- Does not change plan-hash-v1 semantics or Eligible/PendingOperatorApproval planning meaning.
- Extends the stack with approval, drift, dependency, and transaction simulation layers.
- M2 plans remain valid inputs; they are never treated as execution grants.

## Non-goals

- No writable mounts, AppX removal, feature disable, driver/update injection, WIM commit, or production ISO build
- No approval bypass
- No real DISM execution enablement
