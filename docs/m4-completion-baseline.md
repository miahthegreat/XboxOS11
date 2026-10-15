# Milestone 4 Completion Baseline

Milestone 4 is **complete**. It delivered disposable-image integration with a gated **read-only** DISM preflight: allowlisted adapter, owned workspace/mount lifecycle, owned registry-hive load/unload with independent absence verification, observed source identity, inventory/drift/dependency evaluation, and separate `m4-live-readonly` evidence.

No writable Windows image servicing was authorized or executed.

## Merge and CI

| Item | Value |
|------|-------|
| Pull request | [#6](https://github.com/miahthegreat/XboxOS11/pull/6) |
| Validated PR HEAD (live-tested) | `94a3021aa0855951d856f39404ae7913a5cdc050` |
| Merge commit on `main` | `3c2a5d8ff022de08ef11fe9e22e30f97ea678f0d` |
| Pre-merge Validate CI | [run 38675743192](https://github.com/miahthegreat/XboxOS11/actions/runs/38675743192) — success on `94a3021` |
| Post-merge Validate CI (`main`) | [run 38678525075](https://github.com/miahthegreat/XboxOS11/actions/runs/38678525075) — success on `3c2a5d8` |
| Automated tests at merge | Parser 0 errors; Pester **139** passed / 0 failed; PSScriptAnalyzer 0 errors |

## Engine and report namespace

| Contract | Version / value |
|----------|-----------------|
| Preflight engine | `4.1.2` |
| Report namespace (live) | `m4-live-readonly` |
| Drift schema | `drift-v1` |
| Dependency schema | `dependency-v1` |
| Image integrity schema | `image-integrity-v1` |

## Real-host live read-only evidence (preserved outside Git)

Original reports (do not overwrite; M1 baseline also preserved):

- `C:\XboxOS\Logs\XboxOS11-disposable-preflight-m4-live-readonly.json`
- `C:\XboxOS\Logs\XboxOS11-disposable-preflight-m4-live-readonly.md`
- M1 reference: `C:\XboxOS\Logs\DISM-Compatibility-20261014-2.json`

| Field | Observed |
|-------|----------|
| Run ID | `preflight-20261015034144569` |
| Engine | `4.1.2` |
| Transaction | `Completed` |
| Decision | `Blocked` (dependency fail-closed only) |
| Lifecycle completed | `True` |
| Cleanup | `Succeeded` (`cleanupVerified=True`) |
| Source ISO SHA256 (pre/post) | `BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650` (unchanged) |
| Edition / build / DisplayVersion | Windows 11 Pro / `26300.9457` / `26H2` |
| Source index (dynamic) | `6` → exported disposable WIM index `1` |
| Disposable WIM SHA256 | `FCBF9E61A733320898FF592ACF50FB3DF6B533869DE70AA8B1A40D4DD7EB1DC3` |
| Inventory totals | packages **146**, AppX **47**, features **136** |
| Inventory fingerprint | `ACBAD6D4750FA7980A1E6023AFEEE49FEA8937E2FB4E85F644814D5AC1EE84EA` |
| Inventory drift | `Match` |
| Registry hive mount | `HKLM\XboxOSPreflight-preflight-20261015034144-7358add36c2d` |
| Registry-hive cleanup | verified (`registryHiveCleanupVerified=True`, unload independently absent) |
| Owned WIM cleanup | `/Unmount-Image /Discard` exit 0; final mount inventory empty; `mountOwned=False` |
| Retained disposable WIM (host evidence) | `C:\XboxOS\Work\preflight-20261015034156442\install-pro-disposable.wim` |

**Git SHA note:** The operator confirmed the live run used `94a3021…`. That commit was **not** embedded in the live JSON/Markdown report (traceability gap for Milestone 5).

**Architecture metadata gap:** `sourceImage.architecture` was empty in the live report (DISM/hive did not populate it). Edition/build identity still verified.

## Hard safety invariants (always)

| Flag | Live value |
|------|------------|
| `realDismExecutionEnabled` | `False` |
| `modifyingCommandsInvoked` | `False` |
| `executionAuthorized` | `False` |
| `liveReadOnlyAuthorized` | `True` (operator-gated; not writable authorization) |
| `realReadOnlyInspectionOccurred` | `True` |
| `disposableExportOccurred` | `True` |
| `readOnlyMountOccurred` | `True` |
| `sourceIsoProtected` | `True` |

## Preflight dependency blockers (carried forward)

Live `dependencyResult.aggregateOutcome`: **MissingEvidence** (`failClosed=True`, `approvalCannotOverride=True`).

Exact blockers:

1. `Eligible operation dependencies remain Unknown; approval cannot override.`
2. `Dependency categories: MissingEvidence`

Category snapshot:

| Category | Outcome |
|----------|---------|
| XboxInfrastructure, MicrosoftStore, XboxIdentity, ControllerSupport, NetworkingSecurity | Verified |
| GamingServices, GameBar, Servicing | MissingEvidence |
| GraphicsAudio, MediaPlayback | Unknown |

Lifecycle success does **not** authorize writable servicing. Dependency incompleteness remains a planning/authorization blocker.

## Outstanding risks

See [m4-unresolved-risks.md](m4-unresolved-risks.md):

1. Dependency evidence incomplete for several categories.
2. Architecture field not populated in live reports.
3. Live report omits Git commit SHA.
4. Host retains disposable WIM workspace evidence (manual housekeeping; not Git).
5. Approval auth still test-key only — not production-trusted.
6. M4 success never enables mutation flags.

## Explicit restrictions (still in force)

- No writable mounts, AppX removal, feature disable, driver/update injection.
- No WIM commits, production ISO builds, or host Windows modifications.
- No approval bypass and no real DISM enablement for writable servicing.
- Do not delete or overwrite M1/M4 live evidence under `C:\XboxOS\Logs` as part of normal docs work.

## Milestone 5 proposal (not started)

**Proposed title:** Dependency Evidence and Servicing Readiness

Scope before any writable servicing design:

1. Operation-specific AppX and Windows feature dependencies
2. Gaming Services, Xbox identity, Game Bar, Store, and controller support
3. Dependency provenance and evidence quality
4. Read-only component capability validation
5. Inventory-bound servicing eligibility
6. Automated protection-rule regression tests
7. Missing architecture metadata in reports
8. Git commit traceability in generated reports
9. Safe, independently reviewed approval requirements for future writable servicing
10. Controlled testing strategy for any future image modifications

Milestone 5 implementation must not begin until separately scoped and reviewed.
