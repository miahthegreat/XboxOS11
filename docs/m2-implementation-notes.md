# Milestone 2 — Implementation notes and unresolved risks

## Decisions

1. **Plan-only engine** lives in `modules/XboxOS.Build/ServicingPlan.ps1` and is dotted into `XboxOS.Build.psm1`.
2. **Statuses** use `AlreadySatisfied` (not `AlreadyDisabled`) for cross-operation consistency; feature disables that are already disabled map here.
3. **Approval gate** values: `Blocked` / `PendingOperatorApproval` / `NoActionableChanges`. `executionAuthorized` is always `$false`.
4. **Determinism** uses `plan-hash-v1` covering engine/schema versions, source image, inventory fingerprint, manifest fingerprints, full operation safety fields, errors, and execution-relevant warnings (see `docs/m2-canonical-plan-hash.md`).
5. **Inventory import** reconstructs exclusively from successful DISM transcripts; legacy nested counts (=1) are ignored when transcripts are complete; non-Authoritative inventories fail closed.
6. **Exact AppX identities** are mandatory for `Eligible` removals; wildcard identities are `Blocked`.
7. **Duplicate Eligible** rows for the same `targetIdentity` are `Conflicting` (fail closed).
8. **Eligible dependencyCompleteness** is always `Unverified` (never `Established`).

## Unresolved risks (carry to review / M3+)

| Risk | Notes |
|------|-------|
| Incomplete dependency graph | Engine records explicit dependency warnings; it does not prove Store/Xbox safety for Eligible AppX removals |
| Drivers/updates | Not planned as Eligible in M2; require dedicated inventories before scheduling |
| Host vs offline AppX | Plans use provisioned offline PackageName identities only |
| State drift | A future execution milestone must re-hash inventory before applying an approved plan |
| Approval UX | Operator approval recording format is not implemented (gate is advisory/status only) |

## Safety confirmation

Milestone 2 tooling does not call `/Commit`, `/Remove-ProvisionedAppxPackage`, `/Disable-Feature`, `/Add-Driver`, or `/Add-Package` for execution. `modifyingCommandsInvoked` is hard-coded `$false` on generated plans.
