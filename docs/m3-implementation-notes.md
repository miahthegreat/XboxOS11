# Milestone 3 — Implementation Notes

## Layout

| Path | Role |
|------|------|
| `modules/XboxOS.Build/ExecutionSafety.ps1` | Approval, drift, dependency, transaction simulation, reports |
| `scripts/Test-ExecutionSafety.ps1` | Dry-run safety validation CLI (no real DISM) |
| `tests/ExecutionSafety.Tests.ps1` | Pester coverage |
| `docs/m3-execution-safety-contracts.md` | Contracts |
| `docs/m3-transaction-state-machine.md` | State machine / recovery |

Dotted into `XboxOS.Build.psm1` beside `ServicingPlan.ps1`.

## Design choices

1. **No enable switch** for real DISM — `Get-XboxOSRealDismExecutionEnabled` always returns `$false`.
2. **Mock backend** (`New-XboxOSMockServicingBackend`) records simulated steps; never calls `dism.exe` for mutations.
3. **Approval records** are JSON objects under operator-chosen paths (default `C:\XboxOS\Logs`); no secrets.
4. **Drift checks** consume inventory snapshots / fixtures only — no image mounts in M3.
5. **Dependency completeness** remains fail-closed: M2 `Unverified` Eligible ops cannot become `Verified` without explicit evidence objects.
6. **Simulated authorization** is labeled `simulatedAuthorizationResult` and is distinct from real `executionAuthorized`.

## Limitations / unresolved risks

- Dependency evidence model is intentionally conservative; production graphs are not yet fully enumerated.
- Transaction `Completed` means simulated completion only.
- Future milestones must add a separate, reviewed real backend behind additional safety gates — not a boolean flip in this module.

## Preserved evidence

Milestone 1/2 artifacts under `C:\XboxOS\Logs` remain read-only inputs. M3 writes new safety reports with distinct stems.
