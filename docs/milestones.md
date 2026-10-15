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

## M2: Servicing plan engine and safety validation (complete)

Deterministic, inventory-aware **plan-only** engine. No writable Windows image servicing.

Completed:

- Contracts: [m2-servicing-plan-contracts.md](m2-servicing-plan-contracts.md)
- Canonical hash: [m2-canonical-plan-hash.md](m2-canonical-plan-hash.md) (`plan-hash-v1`)
- Ordering / recovery: [m2-operation-ordering-and-recovery.md](m2-operation-ordering-and-recovery.md)
- Implementation notes: [m2-implementation-notes.md](m2-implementation-notes.md)
- CLI: `scripts/New-ServicingPlan.ps1` (dry-run reports under `C:\XboxOS\Logs`)
- Statuses: Eligible, AlreadySatisfied, Absent, Protected, Ambiguous, Conflicting, Blocked, NotEvaluated
- Merged via PR #2 (`9f076c8`); writable DISM / `/Commit` remain unauthorized

Baseline documentation: [m2-completion-baseline.md](m2-completion-baseline.md).

## M3: Servicing execution safety (complete — simulation only)

Approval contracts, inventory drift detection, dependency guards, and transactional state machine with mock backends. Real DISM mutation remains disabled.

Completed:

- Contracts: [m3-execution-safety-contracts.md](m3-execution-safety-contracts.md)
- State machine: [m3-transaction-state-machine.md](m3-transaction-state-machine.md)
- Implementation notes: [m3-implementation-notes.md](m3-implementation-notes.md)
- Unresolved risks: [m3-unresolved-risks.md](m3-unresolved-risks.md)
- CLI: `scripts/Test-ExecutionSafety.ps1` (simulation reports under `C:\XboxOS\Logs`)
- Merged via PR #4 (`be7f21c`); `realDismExecutionEnabled` remains always `false`

Baseline documentation: [m3-completion-baseline.md](m3-completion-baseline.md).

## M4: Disposable image integration and read-only execution preflight (complete)

Read-only DISM allowlist adapter, disposable workspace ownership, owned registry-hive lifecycle, inventory/drift/dependency preflight, and operator-gated live read-only ISO export/mount. Writable servicing remains unauthorized.

Completed:

- Contracts: [m4-disposable-image-preflight-contracts.md](m4-disposable-image-preflight-contracts.md)
- Implementation notes: [m4-implementation-notes.md](m4-implementation-notes.md)
- Unresolved risks: [m4-unresolved-risks.md](m4-unresolved-risks.md)
- CLI: `scripts/Test-DisposableImagePreflight.ps1` (default Mode=Simulation; LiveReadOnly operator-gated)
- Merged via PR #6 (`3c2a5d8`); live run `preflight-20261015034144569` lifecycle Completed / decision Blocked (dependencies)
- `realDismExecutionEnabled` / `modifyingCommandsInvoked` / `executionAuthorized` remain `false`

Baseline documentation: [m4-completion-baseline.md](m4-completion-baseline.md).

## M5: Dependency evidence and servicing readiness (complete — analysis only)

Evidence-driven dependency graph, capability requirements, operation-specific readiness classifications, and servicing-readiness reports. No writable DISM.

Completed:

- Contracts: [m5-dependency-evidence-contracts.md](m5-dependency-evidence-contracts.md)
- Future test strategy: [m5-future-modification-test-strategy.md](m5-future-modification-test-strategy.md)
- Implementation notes: [m5-implementation-notes.md](m5-implementation-notes.md)
- Unresolved risks: [m5-unresolved-risks.md](m5-unresolved-risks.md)
- CLI: `scripts/Test-ServicingReadiness.ps1` (default authoritative inventory; `-Simulation` cannot produce production ReadyForReview)
- Engine `5.1.0`; authoritative decision **Blocked**; all eight Eligible ops effective **MissingEvidence**
- Merged via PR #8 (`9cb6f6f`); all four execution safety flags remain `false`

Baseline documentation: [m5-completion-baseline.md](m5-completion-baseline.md).

**Implementation complete ≠ servicing ready.** Writable servicing remains unauthorized.

## M6A: Disposable-image experiment planning and authorization simulation (complete)

Deterministic, fail-closed experiment planning and authorization simulation. No writable DISM. No WIM create/mount.

Completed:

- Contracts: [m6a-experiment-planning-contracts.md](m6a-experiment-planning-contracts.md)
- Authorization boundaries: [m6a-authorization-boundaries.md](m6a-authorization-boundaries.md)
- Functional validation matrix: [m6a-functional-validation-matrix.md](m6a-functional-validation-matrix.md)
- Unresolved risks: [m6a-unresolved-risks.md](m6a-unresolved-risks.md)
- Design parent: [m6-disposable-image-experiment-design.md](m6-disposable-image-experiment-design.md)
- CLI: `scripts/Test-DisposableExperimentPlan.ps1` (ExternalValidated default; InlineSimulation only with explicit switches)
- Engine `6.0.1-a`; decision always **BlockedForExecution**; Layer D structurally disabled
- Merged via PR #10 (`c69cc58`); all six safety/mutation flags remain `false`

Baseline documentation: [m6a-completion-baseline.md](m6a-completion-baseline.md).

**Planning complete ≠ execution authorized.** Writable servicing remains unauthorized.

## M6B: Isolated disposable-image lab infrastructure (simulation)

Simulation-only lab topology, boundary validation, VM isolation policy, ownership/snapshots, key-policy checks, integrity/recovery state machine, functional-test plan binding, and `m6b` evidence custody — without activating Layer D, provisioning real VMs, or implementing writable DISM.

- Design parent: [m6b-isolated-disposable-lab-design.md](m6b-isolated-disposable-lab-design.md)
- Contracts: [m6b-lab-infrastructure-contracts.md](m6b-lab-infrastructure-contracts.md)
- Isolation: [m6b-vm-isolation-policy.md](m6b-vm-isolation-policy.md)
- Integrity/recovery: [m6b-integrity-recovery.md](m6b-integrity-recovery.md)
- Evidence: [m6b-evidence-custody.md](m6b-evidence-custody.md)
- Unresolved risks: [m6b-unresolved-risks.md](m6b-unresolved-risks.md)
- CLI: `scripts/Test-IsolatedLabReadiness.ps1`
- Engine `6.1.0-b`; decision always **LabProvisioningBlocked** (or **RecoveryRequired** on injected failure); Layer D structurally disabled

## Later: Xbox mode integration

Supported Xbox FSE configuration, controller-first startup, and launcher integration—only after disposable-lab controls and Microsoft-supported mechanisms are validated on desktop hardware.

## M7: Gaming performance

Benchmark-driven service and startup optimization for Ryzen 7 7800X3D and Radeon RX 9070 XT, without disabling security for synthetic gains.

## M8: Recovery and maintenance

Windows Update validation, recovery options, rollback mechanisms, and compatibility testing.

## M9: Release engineering

Versioned build manifests, release documentation, automated validation, and reproducible local builds.
