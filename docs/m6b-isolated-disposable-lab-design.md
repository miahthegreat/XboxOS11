# Milestone 6B — Isolated Disposable-Image Lab Infrastructure

**Status:** Design proposal only. Not implemented. Not authorized.

This document proposes infrastructure for eventually conducting controlled Windows image experiments. It does **not** authorize writable DISM, Layer D activation, AppX removal, feature disablement, ISO/host mutation, or any real image operation.

Milestone 6A remains analysis/simulation only. Analysis-readiness and experiment-planning approval must never be reused as execution authorization.

## Goal

Define and (in a future implementation milestone) build **lab infrastructure** that can safely host disposable-image experiments under explicit human authorization — while keeping production installation media and the host OS untouched.

## Critical separation

| Concern | Milestone 6B scope | Explicitly out of scope until later |
|---------|--------------------|-------------------------------------|
| Lab VM / workspace infrastructure | Design (+ later implement) | — |
| Operator / risk-acceptance records | Design binding to 6A layers | Activating Layer D |
| Writable DISM adapter | **Forbidden in 6B** | Future gated milestone |
| Actual AppX/feature mutation | **Forbidden in 6B** | Future gated milestone |
| Production ISO / host OS changes | **Forbidden forever in this design** | — |

**Acceptance of lab infrastructure ≠ authorization of image modifications.**

## Design pillars

### 1. Isolated virtual machine environment

- Experiments run only inside an isolated disposable VM (or equivalent sandbox), never on the build host OS image.
- Network, credential, and storage boundaries documented; host remains unmodified.

### 2. Disposable workspace and WIM ownership

- Reuse M4 ownership patterns: owned workspace identity, owned WIM path, owned mount path, ownership tokens.
- Workspace outside OneDrive / cloud sync; rooted absolute paths only (6A.1 normalization rules).
- No global DISM cleanup; no stale mount or untracked hive ownership.

### 3. Source ISO immutability

- Source ISO is read-only evidence; pre/post SHA256 verification required for any lab run that touches media.
- Production installation media must never be a mutation target.

### 4. Independent operator authorization

- Layer B operator review/consent remains a distinct record type (6A contracts).
- Lab runs require fresh, non-replayable authorization bound to experiment content hash, readiness binding digest, plan hash, inventory fingerprint, and ISO identity.

### 5. Separate experimental risk acceptance

- Layer C risk acceptance remains separate from Layer B and from Layer D.
- MissingEvidence operations cannot be treated as authorized merely because the lab is disposable.
- Any future mutation despite unresolved dependency evidence requires a separately defined risk-acceptance policy document — not satisfied by M5/M6A closure.

### 6. Trusted approval-key management

- Retire test-PEM-only trust for lab mutation gates.
- Define key custody, rotation, scope (lab-only), and revocation.
- Signature validity must never alone set `executionAuthorized` / `experimentalExecutionAuthorized` without the full gate chain.

### 7. Strict operation allowlists

- Deny-by-default; exact operation ID + target identity; Eligible-only; protected identities rejected even if forged Eligible (6A.1).
- Allowlist selection remains distinct from execution authorization.

### 8. Before/after image integrity checks

- Snapshot contracts for source identity, inventory fingerprint, disposable WIM hash, mount/hive ownership, plan hash, and evidence bindings (6A snapshot schema).
- Abort on any integrity or ownership mismatch.

### 9. Snapshot and rollback strategy

- Prefer discardable mounts; verified cleanup (empty mount inventory; hive unload independently absent).
- Rollback = discard disposable artifacts; never “repair” by mutating the source ISO or host.

### 10. Controlled test-image creation

- Disposable WIM/export derived from verified source only.
- Test-image creation in 6B, if implemented, must remain non-mutating toward production media and must not enable Layer D by default.
- Default CI/CLI paths remain non-mutating.

### 11. Functional validation and evidence collection

- Execute (in a later mutation-capable milestone) the 6A functional validation catalog under the VM.
- Emit `ControlledTestResult` evidence with timestamps, environment, limitations, and bound hashes.
- Do not claim capability pass without runtime evidence.

### 12. RecoveryRequired handling

- On cleanup/integrity failure: transition to `RecoveryRequired`; stop further experiments on that workspace; retain logs.
- No writable-execution transition from recovery states.

### 13. Evidence retention and chain of custody

- Preserve M1–M6A baselines under `C:\XboxOS\Logs`; never overwrite.
- Lab evidence uses a distinct namespace; retain Git SHA, plan hash, inventory fingerprint, readiness binding digest, and architecture (Unknown allowed).

### 14. No host OS or production media alteration

- Hard invariant across all 6B implementation work.

## Proposed Milestone 6B acceptance criteria (infrastructure only)

Milestone 6B may be accepted as an **infrastructure milestone** only when all of the following are true — still without authorizing mutation:

1. Isolated VM lab topology is documented and (if coded) simulation-tested without writable DISM.
2. Disposable workspace ownership, ISO immutability, and path safety are enforced in code/contracts with regression tests.
3. Operator authorization and risk-acceptance schemas remain non-interchangeable with Layer D; Layer D stays structurally disabled.
4. Trusted lab-key management design is documented (implementation may be staged); test keys remain labeled test-only.
5. Allowlist + readiness-binding digest gates from 6A remain mandatory inputs to any future lab run planner.
6. Snapshot/integrity/rollback/RecoveryRequired protocols are specified and tested in simulation.
7. Evidence retention rules preserve prior baselines and attach full provenance.
8. **No unintended mutation:** default CI and default CLI perform no DISM mutation; host OS and source ISO unchanged.
9. A written statement that **lab infrastructure acceptance does not authorize image modifications** is present in the 6B completion baseline.

## Explicit non-goals

- No writable DISM adapter.
- No Layer D activation.
- No AppX removal, feature disable, driver/update injection.
- No custom production ISO.
- No host OS modification.
- No treating MissingEvidence as authorized because an experiment is disposable.

## Stop line

This proposal does **not** authorize implementing Milestone 6B, running DISM, mounting/modifying images, or enabling experimental mutation.
