# Milestone Roadmap

## M1: Image build foundation (complete)

Reproducible Windows ISO customization pipeline and read-only DISM compatibility baseline.

Completed:

- Prerequisite validation and workspace isolation (`C:\XboxOS`)
- Source ISO import helpers and exact Windows 11 Pro index discovery
- Inventory-before/after with flat, state-aware DISM parsing
- Manifest-driven AppX / feature planning with protected-component safeguards
- Optional INF drivers and CAB/MSU update helpers (dry-run safe)
- Validation reports, oscdimg ISO export helpers, Pester + GitHub Actions
- Elevated read-only DISM compatibility against Windows 11 Pro 26H2 (`26300.9457`)
- Compatibility matrix distinguishing Eligible vs AlreadyDisabled (no writable servicing)

Baseline documentation: [m1-compatibility-baseline.md](m1-compatibility-baseline.md).

## M2: Servicing plan engine and safety validation (in progress)

Deterministic, inventory-aware **plan-only** engine. No writable Windows image servicing.

- Contracts: [m2-servicing-plan-contracts.md](m2-servicing-plan-contracts.md)
- Ordering / recovery: [m2-operation-ordering-and-recovery.md](m2-operation-ordering-and-recovery.md)
- Implementation notes: [m2-implementation-notes.md](m2-implementation-notes.md)
- CLI: `scripts/New-ServicingPlan.ps1` (dry-run reports under `C:\XboxOS\Logs`)
- Statuses include Eligible, AlreadySatisfied, Absent, Protected, Ambiguous, Conflicting, Blocked, NotEvaluated
- Writable DISM / `/Commit` remain unauthorized pending separate review and merge of this milestone

## M3: Xbox mode integration

Supported Xbox FSE configuration, controller-first startup, and launcher integration—only after validating Microsoft-supported mechanisms on desktop hardware.

## M4: Gaming performance

Benchmark-driven service and startup optimization for Ryzen 7 7800X3D and Radeon RX 9070 XT, without disabling security for synthetic gains.

## M5: Recovery and maintenance

Windows Update validation, recovery options, rollback mechanisms, and compatibility testing.

## M6: Release engineering

Versioned build manifests, release documentation, automated validation, and reproducible local builds.
