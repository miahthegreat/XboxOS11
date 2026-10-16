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

## M6B: Isolated disposable-image lab infrastructure (simulation) — complete

Simulation-only lab topology, boundary validation, VM isolation **policy**, ownership/snapshots, key-policy checks, integrity/recovery simulation, functional-test plan binding, and `m6b` evidence custody — without activating Layer D, provisioning real VMs, or implementing writable DISM.

- Design parent: [m6b-isolated-disposable-lab-design.md](m6b-isolated-disposable-lab-design.md)
- Contracts: [m6b-lab-infrastructure-contracts.md](m6b-lab-infrastructure-contracts.md)
- Isolation: [m6b-vm-isolation-policy.md](m6b-vm-isolation-policy.md)
- Integrity/recovery: [m6b-integrity-recovery.md](m6b-integrity-recovery.md)
- Evidence: [m6b-evidence-custody.md](m6b-evidence-custody.md)
- Unresolved risks: [m6b-unresolved-risks.md](m6b-unresolved-risks.md)
- CLI: `scripts/Test-IsolatedLabReadiness.ps1` (authoritative M1/M4+M5+M6A chain; inline only with explicit switches)
- Engine `6.1.1-b`; decision always **LabProvisioningBlocked** (or **RecoveryRequired** on injected failure); Layer D structurally disabled
- Isolation: `PolicyValidated` ≠ actual verification (`HypervisorNotInspected` / `NetworkIsolationNotVerified` / `ActualIsolationVerified=False`)
- PSSA review: [m6b-pssa-warning-review.md](m6b-pssa-warning-review.md)
- Merged via PR #12 (`ca30aec`); completion baseline: [m6b-completion-baseline.md](m6b-completion-baseline.md)

**Infrastructure complete ≠ permission to provision VMs or modify Windows images.**

## M6C: Read-only hypervisor and host lab discovery (simulation) — complete

Mocked, allowlisted, read-only discovery contracts for host/hypervisor inspection — without enumerating the live host in CI, provisioning VMs, changing networking, running DISM, or enabling Layer D.

- Design parent: [m6c-real-host-lab-discovery-design.md](m6c-real-host-lab-discovery-design.md)
- Contracts: [m6c-host-discovery-contracts.md](m6c-host-discovery-contracts.md)
- CLI: `scripts/Test-HostLabDiscovery.ps1` (default **HostDiscoveryBlocked**; mocked approval only with explicit switches)
- Engine `6.2.0-c`; module `0.6.3`; adapter mode **MockedSimulation**; `ActualIsolationVerified` remains false for fixture evidence
- Distinct `HostDiscovery` approval layer (not M6A/M6B/Layer D reuse)
- Unavailable Hyper-V tools → Unavailable/Unknown inventories (not empty)
- Merged via PR #14 (`43b66b0`); completion baseline: [m6c-completion-baseline.md](m6c-completion-baseline.md)

**Framework complete ≠ permission to inspect a production host, provision VMs, or modify Windows images.**

## M6D: Operator-authorized real-host discovery (implementation; live inactive) — complete

Typed, allowlisted, operator-authorization contracts for future read-only host inspection — tested with mocks only. Live activation remains False; default CLI decision remains **HostDiscoveryBlocked**. No provisioning, networking mutation, DISM writable servicing, or Layer D.

- Design: [m6d-authorized-readonly-host-inspection-design.md](m6d-authorized-readonly-host-inspection-design.md)
- Adapter: [m6d-readonly-host-adapter.md](m6d-readonly-host-adapter.md)
- Authorization: [m6d-operator-authorization.md](m6d-operator-authorization.md)
- Isolation evidence: [m6d-isolation-evidence.md](m6d-isolation-evidence.md)
- Operational runbook (future manual): [m6d-operational-runbook.md](m6d-operational-runbook.md)
- Unresolved risks: [m6d-unresolved-risks.md](m6d-unresolved-risks.md)
- CLI: `scripts/Test-AuthorizedHostDiscovery.ps1` (default **HostDiscoveryBlocked**; mocked approval only with explicit dual switches)
- Engine `6.3.0-d`; module `0.6.4`; evidence namespace **`m6d`**; `ActualIsolationVerified` remains false for mock evidence
- Distinct `HostDiscoveryReal` approval layer (rejects M6C mock approvals and fixture test keys for live trust)
- Merged via PR #16 (`8418035`); completion baseline: [m6d-completion-baseline.md](m6d-completion-baseline.md)

**Implementation complete ≠ operational host inspection authorization.**

## M6E: Controlled live read-only host discovery (Gate A) — complete

Gate A controls for a real-host read-only adapter: durable cross-process replay protection, an independent approval verifier, a static read-only invoker gate, per-run operator activation, per-operation revalidation, and `m6e` evidence. CI exercises injected invokers only.

- Design: [m6e-controlled-live-discovery-design.md](m6e-controlled-live-discovery-design.md)
- Contracts and operator procedure: [m6e-controlled-live-discovery-contracts.md](m6e-controlled-live-discovery-contracts.md)
- CLI: `scripts/Invoke-ControlledLiveHostDiscovery.ps1` (default **HostDiscoveryBlocked**, exit 2); key/approval helpers `scripts/New-ControlledLiveDiscoverySigningKey.ps1`, `scripts/New-ControlledLiveDiscoveryApproval.ps1`
- Engine `6.4.0-e`; module `0.6.5`; `networkIsolationVerified`, `labProvisioningAuthorized`, `writableServicingAuthorized` always False
- Gate B (one operator-controlled run) is manual and has not been executed

## Product target: Native WinUI 3 XboxOS11 Builder

A desktop application that imports a supported Windows 11 ISO, discovers editions, applies gaming presets or custom component selection with dependency/safety warnings, integrates drivers, configures unattended setup, exports a custom ISO, and saves reusable JSON profiles with build logs.

User workflow (separate from lab authorization architecture):

1. Select a supported Windows 11 ISO
2. Choose a prebuilt gaming preset or Custom
3. Review dependency-aware component changes
4. Configure drivers and installation options
5. Validate the proposed build
6. Produce a customized bootable ISO
7. Save and reuse the build configuration

## M7: Builder backend — complete

Presets, reusable build profiles, strict validation, dependency-aware component review, safe unattend generation, profile-driven builds with a media overlay, first-logon post-install, and a JSON API/event protocol for the native frontend.

- Contracts: [m7-builder-backend-contracts.md](m7-builder-backend-contracts.md)
- CLIs: `scripts/Invoke-XboxOSBuild.ps1` (profile-driven build, `-DryRun`, `-EmitEvents`), `scripts/Invoke-XboxOSBuilderApi.ps1` (frontend API)
- Presets: `config/presets/` (`gaming-balanced`, `gaming-lean`, `handheld-xbox-mode`, `stock-safe`)
- Post-install entrypoint: `postinstall/Invoke-PostInstall.ps1`
- Builder engine `7.0.0`; module `0.7.0`

## M8: Native WinUI 3 Builder application — complete

WinUI 3 / .NET 10 desktop frontend over the M7 API: ISO selection and edition discovery, preset/custom selection, dependency-aware component review, driver and setup options, unattend preview, validation, live build progress with cancellation, and profile save/open/recent.

- Design and verification: [m8-winui-builder.md](m8-winui-builder.md)
- Projects: `src/XboxOS11.Builder.App` (WinUI 3, unpackaged), `src/XboxOS11.Builder.Core`, `tests/dotnet/XboxOS11.Builder.Core.Tests`
- CI: `builder` job (xUnit + PowerShell contract tests, WinUI x64 build)

## M9: Gaming performance and Xbox mode — complete

Supported, documented, reversible post-install gaming optimizations with exact restore, X3D/Radeon-aware verification, and Builder/App integration. Power plan, Game Bar, and security features are explicitly never changed.

- Design and verification: [m9-gaming-performance.md](m9-gaming-performance.md)
- Catalog: `config/gaming-tweaks.json`; applier/restorer: `postinstall/Set-GamingOptimizations.ps1`
- Profile: optional `setup.postInstall.optimizations`; API catalog exposes `optimizations` and `neverChange`

## M10: Recovery, maintenance, and release engineering — complete

Single-source versioning (`VERSION` = 1.0.0), a recovery build record and `Restore-XboxOS11Components.ps1` on every image, release packaging with checksums and a manifest, a tag-triggered draft-release workflow, a changelog, and a product-first README.

- Recovery: [recovery.md](recovery.md)
- Release engineering: [release-engineering.md](release-engineering.md)
- Readiness and remaining human steps: [v1-release-readiness.md](v1-release-readiness.md)
- Changelog: [CHANGELOG.md](../CHANGELOG.md)

## M11: Lean image (Tiny11-class, serviceable) — complete

`gaming-tiny` preset; expanded app and capability removal; offline defaults for new accounts; component cleanup, ResetBase, and ESD recompression; optional local account; opt-in unsupported-hardware setting. Store, Xbox, Edge/WebView2, Defender, Windows Update, and WinRE are always kept.

- Design, Tiny11 comparison, and evidence status: [m11-lean-image.md](m11-lean-image.md)
