# Milestone 2 — Operation ordering and recovery design

This document describes the **proposed** future servicing order and recovery strategy. Milestone 2 does **not** implement automatic commits or execute writable servicing.

## Proposed execution order (future)

| Order band | Operations | Rationale |
|-----------:|------------|-----------|
| 100–199 | Provisioned AppX removals (`RemoveProvisionedAppx`) | Reduce package surface before feature changes; each op targets one exact PackageName |
| 200–299 | Optional feature disables (`DisableOptionalFeature`) | Only for features currently `Enabled`; `AlreadySatisfied` skipped |
| 300–399 | Driver integration (`Add-Driver`) | Deferred until driver inventory + INF validation plan exists |
| 400–499 | Update packages (SSU → SafeOS → LCU → other) | Deferred; must use `Get-XboxOSOrderedUpdatePackages` |
| 900 | Validation / inventory-after | Confirm expected outcomes before any commit consideration |

Within a band, operations sort by stable `operationId` for determinism.

### Dependencies (explicit, not assumed)

- AppX removal does **not** prove feature disable safety.
- Feature disable does **not** prove AppX dependency safety.
- Missing dependency information is recorded on the operation as a warning and elevates risk; it never becomes an implicit pass.
- Protected Store/Xbox/Gaming Services/identity/Game Bar/runtime packages always outrank removal candidates.

## Recovery strategy (future writable servicing)

### Immutable source ISO

- Original ISO remains read-only evidence.
- Never modify the ISO in place.
- Record SHA256 before/after any mount of the ISO (read-only mount only for export).

### Disposable working WIM

- Export a single edition (exact Windows 11 Pro index) to a disposable WIM under `C:\XboxOS\Work`.
- All mutating DISM targets the disposable WIM only.
- Workspace must pass `Assert-XboxOSBuildSafety` / `Assert-XboxOSServicingPathSafety` (no OneDrive, not inside the repo).

### Backup and checkpoint requirements

Before the first mutating command in a future milestone:

1. Confirm disposable WIM hash after export.
2. Write a plan JSON checkpoint that matches the approved plan `contentHash`.
3. Refuse to proceed if the live inventory no longer matches the plan inventory hash.

### Mount ownership and cleanup

- Single owner process per mount directory.
- On any failure: `/Unmount-Image /Discard` then verify no mounts remain via `/Get-MountedImageInfo`.
- `/Cleanup-Mountpoints` only as a secondary recovery step.

### DISM exit-code handling

- Non-zero exit codes fail the phase (`Assert-XboxOSPhaseOutcome`).
- Do not continue the sequence after a failed mutating command.
- Capture full command line, exit code, and tail of output in the build report.

### Abort conditions

Abort (discard, do not commit) when:

- Inventory becomes Unknown mid-flight
- A protected package/feature is selected
- Ambiguous or conflicting operations appear
- Mount/workspace safety checks fail
- Operator approval is missing or plan hash mismatches

### Unmount with `/Discard` on failed servicing

Failed or aborted servicing **must** unmount with `/Discard`. Milestone 2 forbids implementing automatic `/Commit`.

### Final verification before any future `/Commit`

A future milestone may commit only after **all** of:

1. Operator approval recorded for the exact plan `contentHash`
2. Post-change inventory matches expected Eligible outcomes
3. Protected identities still present
4. No unexpected mount remains
5. Disposable WIM integrity check passes

Until those gates exist and pass, `/Commit` remains unauthorized.

## Approval gate

| Gate value | Meaning |
|------------|---------|
| `Blocked` | Unknown inventory, conflicts, or ambiguous matches — no approval path until resolved |
| `NoActionableChanges` | Only Absent / AlreadySatisfied / Protected — nothing to approve |
| `PendingOperatorApproval` | One or more `Eligible` ops exist — still **not** permission to execute |

Milestone 1 matrix eligibility never satisfies this gate by itself.
