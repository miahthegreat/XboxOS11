# Milestone 6B — Lab Infrastructure Contracts

**Status:** Implemented (simulation). Real hypervisor provisioning and Layer D remain unauthorized.

## Engine and schemas

| Item | Value |
|------|-------|
| Engine | `6.1.0-b` |
| Module | `0.6.1` |
| Topology | `lab-topology-v1` |
| Isolation | `lab-isolation-v1` |
| Ownership | `lab-ownership-v1` |
| Snapshot | `lab-snapshot-v1` |
| Transaction | `lab-transaction-v1` |
| Evidence | `lab-evidence-v1` |
| Key policy | `lab-key-policy-v1` |
| Report | `isolated-lab-report-v1` / namespace `m6b` |

## Configuration model (`config/lab-topology.json`)

Covers: hypervisor provider abstraction, VM identity/generation/firmware, CPU/memory/disk, virtual disk ownership roots, network isolation, host/guest communication constraints, guest credential handling, snapshot capabilities, logging/evidence roots, cleanup ownership.

Default provider is **Simulation** (Hyper-V-oriented shape, does not assume Hyper-V installed or enabled). Valid configuration is permission to **plan** infrastructure, not to create it.

## Boundary validation

`Test-XboxOSLabInfrastructureBoundaries` enforces absolute canonical paths, reparse/junction rejection, workspace ownership token derivation, source ISO immutability declaration, non-overlapping roots, simulated mount/hive conflicts, host Windows / reserved volume protection, OneDrive/cloud-sync exclusion, VM disk destination safety, and network isolation gates reused from topology.

## Ownership and snapshots

Ownership binds lab ID, VM ID, workspace ID, owner, plan hash, readiness binding digest, source ISO SHA-256, and an ownership token. Snapshots bind to the same identities and are rejected when reused across labs/VMs/plans.

## Authorization

Reuses M6A layers A–E. Layer D remains structurally disabled. `Test-XboxOSLabKeyPolicy` validates trust-root labeling, custody/rotation/revocation fields, scope, expiration, nonce replay prevention, and operator/authorizer separation. Test PEM fixtures must not claim production trust; signatures never activate writable mutation.

## CLI

`scripts/Test-IsolatedLabReadiness.ps1` — simulation readiness only; exit code `2` when provisioning remains blocked (expected).

## Control matrix

| Control | Implemented | Simulation-tested | Real hypervisor validated | Authorized for mutation |
|---------|-------------|-------------------|---------------------------|-------------------------|
| Topology catalog | Yes | Yes | No | No |
| Boundary checks | Yes | Yes | No | No |
| Isolation policy | Yes | Yes | No | No |
| Ownership/snapshots | Yes | Yes | No | No |
| Key policy fields | Yes | Yes | No | No |
| Transaction machine | Yes | Yes | No | No |
| Functional test plan binding | Yes | Yes | No | No (results not invented) |
| Evidence custody (`m6b`) | Yes | Yes | No | No |
| Real VM / VHD provisioning | No | N/A | No | No |
| Layer D / writable DISM | No | Blocked | No | No |

Parent design: [m6b-isolated-disposable-lab-design.md](m6b-isolated-disposable-lab-design.md).
