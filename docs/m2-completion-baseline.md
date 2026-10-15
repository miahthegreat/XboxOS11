# Milestone 2 Completion Baseline

Milestone 2 is **complete**. It delivered a deterministic, inventory-bound, plan-only servicing engine. No writable Windows image servicing was authorized or executed.

## Merge and CI

| Item | Value |
|------|-------|
| Pull request | [#2](https://github.com/miahthegreat/XboxOS11/pull/2) |
| PR HEAD (validated) | `65c3b525ae28252871d7a602ffdf564ca7f0f8f6` |
| Merge commit on `main` | `9f076c8dd4f6fecb38e8c2c88b127d8e8395836e` |
| Validate CI (PR) | [run 38654087872](https://github.com/miahthegreat/XboxOS11/actions/runs/38654087872) — success |
| Local tests at merge | Parser 0 errors (30 files); Pester 89 passed / 0 failed; PSScriptAnalyzer 0 errors |

## Engine and hashing

| Item | Value |
|------|-------|
| Servicing plan engine | `2.1.0` (`Get-XboxOSServicingPlanEngineVersion`) |
| Canonical hash schema | `plan-hash-v1` (see [m2-canonical-plan-hash.md](m2-canonical-plan-hash.md)) |
| Inventory schema | `2.0` (supported set: `2.0` only) |
| Module version | `0.2.1` |

## Baseline dry-run plan (Milestone 1 evidence)

Source inventory: `C:\XboxOS\Logs\DISM-Compatibility-20261014-2.json` (Authoritative when DISM transcripts are complete).

| Field | Value |
|-------|-------|
| contentHash | `79ACF41CCD2FB47BB582409F073580A056A83AF746A0C894612DCF1FDFA2ABCB` |
| approvalGate | `PendingOperatorApproval` |
| executionAuthorized | `False` |
| modifyingCommandsInvoked | `False` |
| Eligible | 8 |
| AlreadySatisfied | 4 |
| Absent | 4 |
| Ambiguous | 0 |
| Conflicting | 0 |
| Blocked | 0 |
| NotEvaluated | 0 |
| Total | 16 |

All Eligible operations have `dependencyCompleteness=Unverified`. Identical inputs regenerate the same `contentHash`. JSON and Markdown reports agree on hash and status counts.

## Approval-gate behavior

- `Eligible` is planning metadata only — **not** approval to mutate an image.
- `PendingOperatorApproval` does **not** permit execution.
- The plan engine never executes operations.
- Approval for one inventory/manifest fingerprint must not be reused after state drift.
- A future executor must independently re-verify approval, image identity, inventory fingerprint, manifest fingerprints, protection evaluation, and recomputed `contentHash` immediately before any mutation.

## Inventory validation requirements

Authoritative planning requires:

1. Source compatibility-report `success=True`
2. Relevant DISM command exit codes = 0
3. Expected inventory sections / transcripts present
4. Advertised totals consistent with parsed entries (legacy nested count `=1` ignored when transcripts are complete)
5. No duplicate package or feature identities
6. Feature records include valid names and states
7. Exact AppX package identities (no wildcards)
8. Supported inventory schema version
9. Source-image identity / edition metadata
10. Non-truncated command-output reconstruction

Incomplete or Unverified imports may be analyzed, but planning fails closed (`approvalGate=Blocked`).

## Outstanding dependency risks

- Eligible operations intentionally remain `dependencyCompleteness=Unverified`; unknown dependencies must never silently become Established or executable.
- Dependency warnings are explicit and distinct from established safety.
- No executable approval mechanism exists in Milestone 2.

## Explicit restrictions (still in force)

- Do not mount Windows images read/write for servicing.
- Do not remove AppX packages or disable features from this plan.
- Do not commit a serviced WIM or modify the source ISO.
- Do not build a production ISO from Milestone 2 outputs.
- Do not change the host Windows installation.
- Do not treat this plan as authorization for writable servicing.

## Proposed Milestone 3 scope (not started)

Focus before Xbox-mode product work:

1. **Execution safety harness** — disposable/clone image testing only; never source ISO mutation
2. **Approval contracts** — bind operator approval to `contentHash`, image identity, and inventory/manifest fingerprints; reject drift
3. **Pre-flight re-verification** — recompute plan hash and protection evaluation immediately before each mutating step
4. **Inventory drift checks** — fail closed if live inventory diverges from the approved plan fingerprint
5. **Transactional recovery** — ordered apply/rollback semantics aligned with [m2-operation-ordering-and-recovery.md](m2-operation-ordering-and-recovery.md)
6. **Audit trail** — immutable logs proving `executionAuthorized` was earned, not inferred from Milestone 2 metadata

Milestone 3 implementation must not begin until separately scoped and reviewed.
