# Milestone 2 — Servicing plan engine contracts

## Purpose

Define deterministic, inventory-aware **planning** contracts for future Windows image servicing. Generating a plan never executes modifying DISM commands and never treats Milestone 1 matrix `Eligible` as execution permission.

Engine version: `2.1.0`  
Hash schema: `plan-hash-v1` (see [m2-canonical-plan-hash.md](m2-canonical-plan-hash.md))

## Inputs

| Input | Required | Description |
|-------|----------|-------------|
| `Inventory` | Yes | Snapshot with known AppX and feature inventories (see below) |
| `RemoveAppsManifest` | Yes | `config/remove-apps.json` |
| `DisableFeaturesManifest` | Yes | `config/disable-features.json` |
| `CompatibilityManifest` | Yes | `config/compatibility.json` |
| `PlanOptions` | No | Flags such as `IncludeDisabledManifestCandidates` (default `$false`) |

### Inventory snapshot schema

```json
{
  "source": "string",
  "capturedUtc": "datetime|null",
  "appxAvailability": "Unknown|Empty|Available",
  "featureAvailability": "Unknown|Empty|Available",
  "appxPackages": ["exact.PackageName_..."],
  "features": [{ "Name": "FeatureName", "State": "Enabled|Disabled|Disabled with Payload Removed|..." }],
  "packages": [{ "Identity": "...", "State": "Installed|Staged|..." }],
  "notes": ["string"]
}
```

Rules:

- Inventories must come from captured DISM output or an equivalent snapshot.
- The engine **never assumes** a package or feature is present.
- `Unknown` or incomplete inventories fail closed (`approvalGate=Blocked`, operations `NotEvaluated` / plan invalid for execution).

## Outputs

### Plan document

| Field | Description |
|-------|-------------|
| `planId` | Stable id derived from UTC stamp + content hash prefix |
| `engineVersion` | `2.0.0` |
| `generatedUtc` | Generation time (UTC) |
| `dryRun` | Always `true` in Milestone 2 CLI |
| `modifyingCommandsInvoked` | Always `false` for plan generation |
| `inventorySource` | Path or label of inventory |
| `inventoryAvailability` | AppX/feature availability summary |
| `approvalGate` | `PendingOperatorApproval` \| `NoActionableChanges` \| `Blocked` |
| `summary` | Counts by status |
| `operations` | Ordered operation records |
| `warnings` / `errors` | Plan-level messages |
| `contentHash` | SHA256 of canonical operation payload (determinism check) |

### Operation record

| Field | Description |
|-------|-------------|
| `operationId` | Stable id (`appx:<candidate>:<identity>` or `feature:<candidate>:<name>`) |
| `operationType` | `RemoveProvisionedAppx` \| `DisableOptionalFeature` |
| `targetKind` | `AppX` \| `Feature` |
| `targetIdentity` | Exact resolved package name or feature name |
| `manifestSource` | Manifest file basename |
| `manifestRuleId` | Candidate `id` |
| `matchPattern` | Pattern/name used for resolution |
| `currentState` | Inventory state string |
| `proposedAction` | Intended future action |
| `status` | See status taxonomy |
| `protectionEvaluation` | Protected / unprotected detail |
| `dependencies` | Declared dependency notes (explicit; never assumed safe) |
| `executionOrder` | Integer order for a future engine |
| `risk` | `Low` \| `Medium` \| `High` \| `Critical` |
| `expectedOutcome` | Human-readable expected result |
| `skipOrRejectionReason` | Why skipped/rejected (if any) |
| `approvalRequired` | `true` for any future mutating Eligible op |

### Status taxonomy

| Status | Meaning |
|--------|---------|
| `Eligible` | Exact target resolved; unprotected; actionable **only after separate approval** |
| `AlreadySatisfied` | Desired end-state already present (e.g. feature already disabled) |
| `Absent` | Not present in known inventory |
| `Protected` | Blocked by compatibility / neverDisable / core policy |
| `Ambiguous` | Pattern matched multiple identities; rejected |
| `Conflicting` | Manifest or contradictory operation conflict |
| `Blocked` | Safety gate blocked the operation/plan |
| `NotEvaluated` | Inventory unknown/incomplete; fail closed |

## Approval semantics (non-executable)

| Claim | Reality |
|-------|---------|
| `status=Eligible` | Planning metadata only — **not** approved |
| `approvalGate=PendingOperatorApproval` | Operator review cue — **not** permission to mutate |
| `executionAuthorized` | Always `false` in Milestone 2 |
| `modifyingCommandsInvoked` | Always `false` in plan generation |
| Approval reused after drift | Forbidden — fingerprint / `contentHash` must match live state |

A future executor MUST independently re-verify, immediately before any image mutation:

1. Approval record bound to this `contentHash`
2. Source-image identity
3. Inventory fingerprint and Authoritative verification
4. Manifest fingerprints
5. Protected-component evaluation
6. Recomputed `plan-hash-v1` `contentHash`

## Compatibility with Milestone 1

- Consumes M1 compat JSON command outputs or structured inventory fields.
- Reuses `Resolve-XboxOSPackageMatches -RejectAmbiguous`, protection helpers, and feature-state classifiers.
- Matrix `Eligible` is **not** an execution grant; the plan engine re-evaluates from inventory + manifests.
- Legacy nested sample counts (=1) are ignored when DISM transcripts reconstruct complete inventories.

## Non-goals (Milestone 2)

- No `/Remove-ProvisionedAppxPackage`, `/Disable-Feature`, `/Add-Driver`, `/Add-Package`
- No read/write mounts, `/Commit`, ISO rebuild, or host mutation
- No executable approval bypass
