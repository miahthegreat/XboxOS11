# Milestone 6A — Experiment Planning Contracts

**Status:** Implemented (simulation / planning only). No writable DISM.

Milestone 6A provides deterministic, fail-closed experiment **planning** and authorization **simulation**. It reuses M2 plan hashes, M3 approval binding ideas, M4 workspace ownership rules, and M5 readiness assessments through explicit interfaces — it does not duplicate those engines.

## Versions

| Artifact | Value |
|----------|-------|
| Experiment engine | `6.0.0-a` |
| Experiment plan schema | `experiment-plan-v1` |
| Allowlist schema | `experiment-allowlist-v1` |
| Authorization layer schema | `experiment-auth-layer-v1` |
| Snapshot schema | `experiment-snapshot-v1` |
| Transaction schema | `experiment-transaction-v1` |
| Functional validation schema | `functional-validation-v1` |
| Plan content hash | `experiment-plan-hash-v1` |

## Experiment plan (`experiment-plan-v1`)

Required safety-critical fields:

| Field | Binding |
|-------|---------|
| `experimentId` | Unique id for the planned experiment |
| `schemaVersion` | `experiment-plan-v1` |
| `sourceIsoSha256` | Bound source ISO identity |
| `editionName`, `buildNumber`, `architecture` | Source image identity |
| `sourceIndex` | Exact image index |
| `inventoryFingerprint` | M2 inventory fingerprint |
| `servicingPlanContentHash` | M2 `plan-hash-v1` content hash |
| `readinessReportIdentity` | Path + decision + engine + plan/inventory hashes from M5 |
| `git` | Commit SHA + dirty-tree status |
| `operations[]` | Exact `operationId`, `targetIdentity`, plan status, M5 readiness fields, closure, capability impacts |
| `expectedScope` | Declared experiment scope (analysis / disposable-lab-future) |
| `workspaceConstraints` | Disposable workspace rules (evaluated, not created) |
| `requiredSnapshots` | Snapshot contract ids |
| `requiredFunctionalTests` | Validation catalog test ids |
| `abortConditions` | Fail-closed abort rules |
| `recoveryRequirements` | Recovery expectations |
| `contentHash` | Deterministic `experiment-plan-hash-v1` over safety-critical inputs |

Missing required fields, conflicting identities, or stale evidence → reject / BlockedForExecution.

## Content hash (`experiment-plan-hash-v1`)

Canonical UTF-8 JSON SHA-256 over: schema/engine versions, source identity, inventory fingerprint, servicing plan hash, readiness report identity, selected operation IDs + target identities + effective readiness + closure completeness, workspace constraint digest, required snapshot/test ids, abort/recovery digests. Excludes wall-clock-only fields (`generatedUtc`).

## Allowlist (`experiment-allowlist-v1`)

Deny-by-default. Only operations present in the bound M2 plan may be considered. Exact `operationId` + `targetIdentity` match required. Selection for an experiment **never** authorizes execution.

## Transaction states (`experiment-transaction-v1`)

`Planned` → `AwaitingOperatorReview` → `ReviewRecorded` → `RiskAcceptanceRequired` → `BlockedForExecution` | `ExperimentPrepared` | `Aborted` | `RecoveryRequired`

No reachable writable-execution transition in Milestone 6A. Terminal planning outcome is **`BlockedForExecution`**.

## Interfaces reused (not duplicated)

| Milestone | Interface |
|-----------|-----------|
| M2 | `New-XboxOSServicingPlan`, `contentHash`, inventory fingerprint |
| M3 | Binding-hash discipline; `Assert-XboxOSExecutionSafetyInvariants` |
| M4 | Path ownership / OneDrive / ISO immutability constraints; test PEM signing helpers |
| M5 | `operationAssessments`, catalog vs effective readiness, inventory provenance |

## CLI

`scripts/Test-DisposableExperimentPlan.ps1` — non-elevated; writes `C:\XboxOS\Logs\XboxOS11-experiment-plan-m6a.{json,md}` (separate namespace; never overwrites M1–M5 baselines).
