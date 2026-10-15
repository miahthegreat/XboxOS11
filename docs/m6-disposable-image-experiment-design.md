# Milestone 6 — Disposable-Image Experiment Design and Functional Validation

**Status:** Design proposal only. Not implemented. Not authorized.

This document proposes the next milestone after Milestone 5 closure. Milestone 5 remains analysis-only; its `Blocked` readiness decision and `MissingEvidence` effective assessments are **not** execution authorization.

## Goal

Define a controlled path to plan, authorize, and (only when separately approved) execute **disposable-image-only** mutation experiments with strict allowlists, snapshots, integrity checks, isolated VM functional validation, evidence collection, and rollback — without treating MissingEvidence as authorized.

## Non-goals

- No host OS modification.
- No production ISO builds.
- No reuse of analysis-readiness / `ReadyForReview` as writable-execution authorization.
- No automatic treatment of curated independence statements as complete dependency proof.
- No enabling of `realDismExecutionEnabled` / `executionAuthorized` / `servicingAuthorized` unless a future, separately reviewed authorization gate is satisfied for that run.

## Authorization layers (must remain distinct)

| Layer | Purpose | Does not imply |
|-------|---------|----------------|
| A. Non-mutating experiment planning | Select candidate ops, bound evidence, write experiment plan hash | Mutation |
| B. Explicit operator authorization | Human-reviewed allowlist + risk acceptance for a named disposable workspace | Host/production servicing |
| C. Disposable-image-only mutation | Scoped DISM against owned disposable WIM only | Production image / source ISO changes |
| D. Functional validation | Isolated VM install + runtime tests | Production readiness |
| E. Experimental risk-acceptance policy (optional future) | If any mutation is proposed despite unresolved dependency evidence, require a **separately defined** policy + explicit human authorization | Analysis-readiness approval |

**Hard rule:** No operation with effective `MissingEvidence` may be treated as authorized solely because the experiment is disposable. If a future milestone proposes controlled modifications despite unresolved dependency evidence, that requires layer E — never a silent bypass of Milestone 5 readiness.

## Proposed design pillars

### 1. Non-mutating experiment planning

- Input: authoritative inventory fingerprint, plan hash, Milestone 5 readiness report.
- Output: experiment plan document with operation allowlist, evidence binding, expected pre/post hashes, rollback steps.
- Default decision remains Blocked until authorization artifacts exist.

### 2. Explicit operator authorization

- Per-run authorization record: operator identity, UTC, disposable workspace path, operation IDs, risk statement, expiry.
- Distinct flags from analysis readiness (do not set `servicingAuthorized` from readiness engine alone).
- Test-key approval remains insufficient for production; lab may use explicitly labeled lab keys.

### 3. Disposable-image-only mutation

- Source ISO read-only and integrity-verified (pre/post SHA256).
- Mutations only against owned disposable WIM/export from Milestone 4 patterns.
- Strictly scoped operation allowlists (deny-by-default).
- No AppX/feature changes outside the authorized allowlist.

### 4. Pre-change snapshots and integrity verification

- Capture inventory fingerprint, WIM SHA256, mount ownership, hive ownership before mutation.
- Verify ownership and integrity before every mutating step; abort on mismatch.

### 5. Evidence-bound operation selection

- Each allowlisted op must cite evidence IDs and readiness fields from the bound Milestone 5+ report.
- MissingEvidence ops require layer-E risk acceptance **in addition to** operator authorization; they are never silently promoted.

### 6. Reversible experiment execution

- Prefer discardable mounts (`/Discard`) and verified cleanup (mount inventory empty; hive unload independently absent).
- Commit to disposable WIM only when the experiment plan explicitly requests a retained lab artifact; never commit to source media.

### 7. Isolated VM installation and runtime testing

- Install disposable image into an isolated VM (not the host).
- Collect runtime evidence separately from offline inventory.

### 8. Functional validation matrix (acceptance targets)

| Area | Acceptance intent |
|------|-------------------|
| Xbox Full Screen Experience | Documented entry path reachable; failure → discard + Blocked evidence |
| Gaming Services | Service/app smoke; failure → discard |
| Microsoft Store | Install small free lab app; failure → discard |
| Controllers | USB and/or Bluetooth enumeration + GameInput/XInput smoke |
| Audio | Render test tone / basic output path |
| Graphics | Adapter enumeration; no security surface disablement |
| Networking | DHCP + TLS reachability to Store/Xbox endpoints |
| Windows Update | Scan-only / lab WSUS; no host mutation |
| Recovery | Documented recovery path still available; rollback verified |

### 9. Post-test evidence collection

- Emit `ControlledTestResult` evidence with timestamps, environment, limitations, and bound plan/inventory hashes.
- Preserve provenance; never overwrite M1–M5 baselines under `C:\XboxOS\Logs`.

### 10. Rollback and failure handling

- On any integrity, ownership, or critical functional failure: stop mutation, discard mount, retain logs, mark RecoveryRequired / experiment Failed.
- Source ISO remains untouched; host remains unmodified.

## Proposed Milestone 6 acceptance criteria

Milestone 6 is **accepted as a design-and-lab-control milestone** only when all of the following are true (implementation of mutation remains gated):

1. **Planning artifacts** exist: experiment plan schema, allowlist schema, authorization record schema, and evidence-binding rules are documented and tested in simulation.
2. **Authorization separation** is enforced in code/contracts: readiness decision cannot set execution/servicing flags; MissingEvidence cannot be auto-authorized by “disposable” alone.
3. **Disposable-only boundary** is enforceable: source ISO protection, owned workspace, owned mount/hive lifecycle, and deny-by-default allowlists are specified and regression-tested (simulation and/or dry-run).
4. **Snapshot/integrity protocol** is specified: pre/post hashes, ownership checks, abort conditions.
5. **Functional validation plan** covers Xbox FSE, Gaming Services, Store, controllers, audio, graphics, networking, Windows Update, and recovery — with failure → discard semantics.
6. **Evidence provenance** rules preserve prior baselines and attach Git SHA, plan hash, inventory fingerprint, and architecture fields (Unknown allowed; never assumed).
7. **Risk-acceptance policy stub** exists as a separate document for any future mutation despite unresolved dependency evidence; it is not satisfied by Milestone 5 closure.
8. **No unintended mutation** in Milestone 6 merge: default CI and default CLI paths perform no DISM mutation; host OS unchanged.

If Milestone 6 later includes a first disposable mutation lab run, that run requires an additional explicit operator authorization for that workspace and must still keep production servicing unauthorized.

## Relationship to Xbox mode / later milestones

Roadmap items formerly labeled “Xbox mode integration” remain downstream of disposable-image experiment controls and evidence closure. Xbox FSE configuration on desktop hardware must not precede validated disposable-lab controls and must not weaken security surfaces for synthetic gains.

## Explicit stop line

This proposal does **not** authorize implementing Milestone 6, running DISM, mounting/modifying images, removing AppX, disabling features, producing a custom ISO, or enabling writable servicing.
