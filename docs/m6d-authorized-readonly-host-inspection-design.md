# Milestone 6D — Operator-Authorized Real-Host Discovery

**Status:** Design proposal only. **Not implemented. Not authorized.**

This document proposes an optional, separately approved capability to perform **one bounded, read-only inspection** of a named Windows host and its virtualization environment. It does **not** authorize VM provisioning, networking changes, VHD mutation, DISM writable servicing, Layer D activation, or Windows image modification.

Milestone 6C delivered mocked discovery contracts with default **`HostDiscoveryBlocked`**. Milestone 6D exists only to define how a future operator may authorize **real-host read-only observation** under fail-closed controls — still without provisioning or mutation.

## Goal

Define a future implementation milestone that can, after explicit per-run operator consent:

1. Inspect Windows edition and build on a named host
2. Observe available virtualization capabilities
3. Observe Hyper-V management tools and feature status (without enabling Hyper-V)
4. Enumerate existing VM inventory (read-only)
5. Observe virtual switch types and membership
6. Observe network adapters and switch bindings
7. Observe existing VHD/VHDX metadata (no attach/create)
8. Observe CPU, memory, and storage capacity
9. Validate workspace safety and reparse boundaries
10. Optionally observe existing DISM mount inventory when that category is explicitly approved
11. Detect conflicts with production infrastructure
12. Emit independently reviewable `m6d` evidence

## Critical separation

| Concern | Milestone 6D scope | Explicitly out of scope |
|---------|--------------------|-------------------------|
| Operator-authorized read-only host inspection | Design (+ later implement) | Silent/default real-host runs |
| Bound per-run consent | Design | Unattended escalation / privilege acquisition |
| Independent isolation evidence states | Design | Treating switch inventory as complete guest isolation |
| VM / switch / VHD / network mutation | **Forbidden** | Forever in 6D |
| Writable DISM / image mutation | **Forbidden** | Forever in 6D |
| Layer D / experimental mutation | **Forbidden** | Forever in 6D |
| Lab provisioning | **Blocked** | Later gated milestone |

**Authorized discovery ≠ permission to provision or mutate.**

## Authorization requirements

No real-host discovery by default.

Before any live inspection command runs, require an explicit operator consent record for **one bounded run** that binds at least:

| Field | Requirement |
|-------|-------------|
| Operator identity | Required |
| Actual host identity | Must match the machine under inspection |
| Tooling Git SHA | Must match the executing tooling revision |
| Discovery scope | Approved categories only |
| Expiry | Fail closed when expired |
| Nonce | Non-replayable |
| Read-only acknowledgment | Required |

Reject:

- Expired approvals
- Replayed nonces
- Host identity mismatch
- Git SHA mismatch
- Scope mismatch
- Copied/simulated M6C fixture approvals presented as live consent
- Any approval that claims provisioning or Layer D rights

No unattended escalation or automated privilege acquisition. Approval must not be reusable for provisioning or modification.

## Discovery implementation (proposed)

Reuse the M6C allowlist model with a **strictly allowlisted real-host read-only adapter** (no generic shell-command executor).

Covered domains (read-only only):

- Windows edition and build
- Available virtualization capabilities
- Hyper-V management tools and feature status
- Existing VM inventory
- Virtual switch types and membership
- Network adapters and switch bindings
- Existing VHD/VHDX metadata
- CPU, memory, and storage capacity
- Workspace safety and reparse boundaries
- Existing DISM mount inventory, **only if** that category is explicitly approved
- Conflicts with production infrastructure

Denied forever in 6D: `New-VM` / Start/Stop/Remove VM, New/Set/Remove VMSwitch, New-VHD / Mount-VHD, Enable/Disable WindowsOptionalFeature, Mount/Dismount/Cleanup-WindowsImage, netsh / firewall mutation, arbitrary `Invoke-Expression` / process launch for discovery.

## Independent isolation evidence

Distinguish explicitly (do not collapse):

| State | Meaning |
|-------|---------|
| Hypervisor available | Management tools/feature signals observed |
| Virtual switch present | Named switch observed |
| Virtual switch configuration observed | Type/bindings observed |
| Production-network attachment observed | Evidence of external/bridged/production uplink |
| Network isolation independently verified | Mandatory independent criteria all directly observed |
| Guest isolation untested | Guest-side isolation not evidenced |
| Evidence incomplete | Partial results; not complete |

**Host switch inventory alone must not establish complete guest network isolation.**

Finding or naming `IsolatedSwitch`, or observing Private/Internal type, remains insufficient without the full independent criteria set (existence, type, production bridge absence, admin-share exposure, firewall evidence, production VM sharing, etc.).

## Evidence and privacy

Require for each authorized run:

- Per-command result and exit status
- Host identity binding
- UTC timestamps
- Evidence hashes
- Tooling Git SHA
- Approval scope and binding digest
- Redaction of sensitive machine/VM/network identifiers
- Separate report namespace: **`m6d`**
- Prior M1–M6C evidence untouched

Fixture/mock evidence must remain labeled and must not be interchangeable with independently observed host evidence.

## Fail-closed behavior

| Condition | Behavior |
|-----------|----------|
| Unavailable commands | Remain `Unavailable` |
| Permission errors | Remain `Unverified` (no auto-elevation) |
| Partial results | Must not be presented as complete |
| Non-allowlisted command | Rejected; abort |
| Unexpected side effect | Abort the run; transition to failure/recovery |
| Missing/invalid approval | `HostDiscoveryBlocked` |
| Real provisioning / writable servicing | Remain unauthorized |

Terminal outcomes must keep lab provisioning blocked and Layer D disabled.

## Acceptance criteria

### Implementation acceptance (future coding milestone)

1. Read-only real-host adapter implemented behind explicit authorization
2. Approval validation implemented (host, Git SHA, scope, expiry, nonce, replay)
3. Mocked negative cases tested (expired/replay/mismatch/denied commands/side effects)
4. CI passes without performing live host inspection during implementation
5. No generic shell executor
6. All mutation/provisioning/Layer D flags remain False
7. `m6d` namespace does not overwrite prior baselines

### Operational acceptance (later explicit operator decision)

1. Operator authorizes a **named host** and **bounded scope**
2. Exactly **one** read-only run executes under that consent
3. Evidence is reviewed independently
4. No VM, switch, network, VHD, source ISO, or Windows image changes occur
5. Unverified isolation remains unverified unless independent criteria are met with direct observation
6. Provisioning and Layer D remain blocked

## Relationship to prior milestones

| Milestone | Role relative to 6D |
|-----------|---------------------|
| M6B | Simulated lab topology / policy; isolation not host-verified |
| M6C | Mocked discovery framework; default HostDiscoveryBlocked |
| **M6D** | Optional operator-authorized real-host read-only inspection |
| Later | Separately gated provisioning / mutation — not designed here |

## Remaining risks (pre-implementation)

1. Elevation may be required for some read-only queries — must be human-driven, never automated.
2. Enumerating VMs/switches can expose sensitive names — redaction is mandatory.
3. Operators may treat a successful 6D run as isolation proof or provisioning permission — decision language must stay explicit.
4. Partial host visibility can look “green” if Unknown/Unverified is not surfaced prominently.

This proposal does **not** authorize implementing Milestone 6D, running live host-discovery commands, or enabling experimental mutation.
