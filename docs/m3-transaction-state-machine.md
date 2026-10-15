# Milestone 3 — Transactional Servicing State Machine

Simulation-only controller. Real DISM modifying backends are unavailable.

## States

| State | Meaning |
|-------|---------|
| `Created` | Transaction object created; no work started |
| `PreflightValidated` | Plan hash, inventory, schema, and path safety passed |
| `AwaitingApproval` | Waiting for a valid `approval-v1` record |
| `ApprovedForPreparation` | Approval bound and still valid; preparation allowed in simulation |
| `WorkspacePrepared` | Simulated disposable workspace prepared (source ISO untouched) |
| `WorkingImageValidated` | Simulated working image identity verified |
| `ReadyForExecution` | All preconditions met for **simulated** steps only |
| `Executing` | Mock backend running simulated operations |
| `VerificationPending` | Simulated ops finished; verification required |
| `CommitPending` | Verification passed; commit would be next (blocked for real DISM) |
| `Completed` | Simulated transaction completed without real mutation |
| `Aborted` | Clean abort before mutation/commit |
| `RecoveryRequired` | Failure needs recovery action |
| `Recovered` | Recovery completed (typically discard) |
| `Failed` | Terminal failure |

## Valid transitions (summary)

```
Created → PreflightValidated | Failed
PreflightValidated → AwaitingApproval | Failed
AwaitingApproval → ApprovedForPreparation | Aborted | Failed
ApprovedForPreparation → WorkspacePrepared | RecoveryRequired | Failed
WorkspacePrepared → WorkingImageValidated | RecoveryRequired | Aborted
WorkingImageValidated → ReadyForExecution | RecoveryRequired | Aborted
ReadyForExecution → Executing | Aborted | Failed
Executing → VerificationPending | RecoveryRequired | Failed
VerificationPending → CommitPending | RecoveryRequired | Failed
CommitPending → Completed | RecoveryRequired | Failed   # Completed is simulated only
* → Aborted | RecoveryRequired | Failed   # guarded by policy
RecoveryRequired → Recovered | Failed
Recovered → Aborted | Failed
```

Illegal transitions throw / mark `Failed` with an audit event. No transition may silently skip to commit.

## Distinctions the controller must enforce

1. **Source ISO protection** — never modified; fingerprint checked
2. **Disposable workspace** — simulated under `C:\XboxOS\Work` paths only
3. **Mount ownership** — mock mount token; discard on failure
4. **Operation execution** — mock backend only
5. **Verification** — required before any commit-pending state
6. **Discard vs commit** — real commit path disabled; simulated commit never invokes DISM

## Recovery recommendations

| Failure class | Default recovery |
|---------------|------------------|
| Interrupted preparation | Discard workspace; restart from Created |
| Approval expired/revoked/invalidated | Abort; issue new plan/approval |
| Source fingerprint mismatch | Abort; re-import evidence; new plan |
| Inventory drift | Abort; regenerate plan from fresh inventory |
| Protected / ambiguous / duplicate | Abort; fix manifests or inventory |
| Unexpected feature state | Abort; new plan |
| Missing dependency evidence | Abort; do not approve override |
| Simulated DISM failure | Discard mount; RecoveryRequired → Recovered |
| Interrupted unmount | RecoveryRequired; verify mock mount cleared |
| Verification failure | Discard; do not commit |
| Commit rejection | Remain non-committed; Failed or Recovered via discard |

No failure path may silently proceed to commit.
