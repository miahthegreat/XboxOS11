# Milestone 6A — Authorization Boundaries

**Status:** Implemented as distinct, non-interchangeable record types. Execution authorization remains structurally disabled.

## Layers (not interchangeable)

| Layer | Code | Purpose | May set writable flags? |
|-------|------|---------|-------------------------|
| A | `ExperimentPlanning` | Build bound experiment plan | No |
| B | `OperatorReviewConsent` | Simulated operator review/consent | No |
| C | `ExperimentalRiskAcceptance` | Simulated risk acceptance for MissingEvidence | No |
| D | `ExecutionAuthorization` | Writable execution grant | **Structurally disabled** |
| E | `FunctionalValidation` | Runtime validation evidence gate | No |

A JSON field such as `approved=true` is **never** trusted alone. Layer B/C simulation requires a valid binding hash and, when signed, a valid test-key signature. Test PEMs under `tests/Fixtures/approval-auth/` remain **test-only**.

## Safety invariants (always False)

- `realDismExecutionEnabled`
- `modifyingCommandsInvoked`
- `executionAuthorized`
- `servicingAuthorized`
- `experimentalMutationEnabled`
- `experimentalExecutionAuthorized`

No simulation outcome may flip these flags.

## MissingEvidence policy

All eight M5 Eligible operations currently have effective readiness `MissingEvidence`.

| Rule | Behavior |
|------|----------|
| Disposable ≠ VerifiedSafe | Effective readiness cannot be promoted to `VerifiedSafeForConsideration` merely because the experiment is disposable |
| No auto-execution | MissingEvidence never authorizes execution |
| Risk acceptance separate | Layer C is a proposed future control; simulation does not grant Layer D |
| Protected components | Simulated risk acceptance cannot override protected Xbox/Gaming Services restrictions |
| Production paths | Experimental override remains disabled |
| Final decision | Always `BlockedForExecution` in Milestone 6A |

Catalog candidate readiness and effective readiness remain distinct fields (preserved from M5).

## Replay and forgery

Authorization records bind: experiment content hash, plan hash, inventory fingerprint, ISO SHA256, operator id, layer, nonce, expiry. Replay of a prior nonce, expired consent, mismatched operator, forged signature, or allowlist change → fail closed / Invalidated.

## Milestone 6B boundary

Milestone 6B implements **lab infrastructure simulation** only. It must:

1. Keep Layer D disabled (structurally) until a separately reviewed execution gate exists.
2. Never mutate source ISO or host OS; no writable DISM adapter.
3. Require Layer B (+ Layer C when MissingEvidence) **and** an explicit future lab execution gate — never reuse M5 readiness or 6A planning approval as execution authorization.
4. Preserve M1–M6A report baselines; write only under the `m6b` evidence namespace.

See [m6b-lab-infrastructure-contracts.md](m6b-lab-infrastructure-contracts.md).
