# Milestone 6C — Read-Only Hypervisor and Host Lab Discovery

**Status:** Design parent. Simulation/mock implementation lives in Milestone 6C contracts (`HostLabDiscovery.ps1`). Real-host enumeration and Layer D remain unauthorized.

This document proposes a separately gated, **read-only** process to inspect the actual Windows host and virtualization environment. It does **not** authorize VM provisioning, networking changes, VHD mutation, DISM writable servicing, Layer D activation, or any Windows image modification.

Milestone 6B established simulation-only lab infrastructure. **`PolicyValidated` / declared `IsolatedSwitch` is not proof of isolation.** Milestone 6C exists to collect independently observed host facts under explicit operator approval — still without mutating the host or lab.

## Goal

Define a future implementation milestone that can discover and evidence:

1. Windows edition, build, and virtualization capabilities
2. Hyper-V availability and management tools (without assuming Hyper-V is installed or enabled)
3. Existing virtual machines
4. Virtual switches and network adapters
5. Network isolation configuration (observed, not inferred from topology JSON alone)
6. Existing VHD/VHDX resources
7. Available CPU, memory, and storage
8. Host filesystem and workspace boundaries
9. Existing relevant DISM mount metadata (**read-only inspection only**)
10. Lab credential and trust prerequisites
11. Evidence collection with hashing, timestamps, and Git traceability
12. Potential conflicts with existing VM or network infrastructure

## Critical separation

| Concern | Milestone 6C scope | Explicitly out of scope |
|---------|--------------------|-------------------------|
| Read-only host / hypervisor discovery | Design (+ later implement) | — |
| Independent isolation verification criteria | Design | Treating IsolatedSwitch config as proof |
| Operator approval gate for inspection | Design | Silent auto-inspection |
| VM / switch / VHD create-modify-delete | **Forbidden** | Forever in 6C |
| Host firewall / networking changes | **Forbidden** | Forever in 6C |
| Writable DISM / WIM export-mount | **Forbidden** | Forever in 6C |
| Layer D / experimental mutation | **Forbidden** | Forever in 6C |
| Lab provisioning | **Blocked** | Later gated milestone |

**Discovery success ≠ permission to provision or mutate.**

## Operator approval prerequisite

Before any real-host inspection command runs, a future implementation must require an **explicit, non-replayable operator approval** record that binds at least:

- Operator identity
- Host identity (machine name / OS build)
- Intended discovery scope
- Nonce and expiry
- Git commit SHA of the tooling revision
- Statement that inspection is read-only

Without a valid approval, the process must fail closed with decision **`HostDiscoveryBlocked`** (name illustrative). Simulated or copied approvals from M6A/M6B must not authorize discovery.

## Discovery model (proposed)

### Provider abstraction

Keep the M6B provider abstraction. Default remains non-assuming:

- Do **not** assume Hyper-V is enabled or installed
- Prefer capability probes that are read-only (`Get-*` / CIM query patterns)
- When management modules or cmdlets are absent → record `Unknown` / `Unavailable`, never invent presence

### Discovery domains

| Domain | Examples of read-only signals | Mutation forbidden |
|--------|-------------------------------|--------------------|
| OS / virt capabilities | Edition, build, `Win32_Processor.VirtualizationFirmwareEnabled`, optional feature state queries | Enabling Hyper-V / Optional Features |
| Hyper-V tools | Module presence, `Get-Command` for `Get-VM` etc. | `Enable-WindowsOptionalFeature`, install roles |
| VMs | Enumerate existing VMs if tools available | New/Start/Stop/Remove-VM |
| Switches / adapters | Enumerate switches/adapters; note isolation modes claimed by host | New/Set/Remove-VMSwitch; netsh changes |
| Isolation verification | Independent criteria (below) | Creating IsolatedSwitch to “make tests pass” |
| VHD/VHDX | Locate existing files under approved roots; hash metadata only | New-VHD, mount, expand, convert |
| Resources | CPU count, memory, free disk on approved volumes | Resizing volumes |
| Workspace boundaries | Canonical path checks, OneDrive/reparse rejection (reuse M6B) | Creating workspaces |
| DISM mount metadata | Read-only listing of known mount points / registry mount keys if safely readable | Mount/Dismount/Cleanup-WindowsImage |
| Credentials / trust | Presence of lab key custody prerequisites (paths/labels only) | Creating secrets in repo |
| Conflicts | Overlapping VM names, shared switches, production bridge indicators | “Fixing” conflicts |

### Independent isolation verification criteria

Finding a configuration named `IsolatedSwitch` (in topology JSON or even on the host) is **insufficient**. Future verification must require separately collected evidence such as:

| Criterion | Pass condition (illustrative) | Fail / Unverified |
|-----------|-------------------------------|-------------------|
| Switch exists | Named switch observed via read-only host query | Missing tools → Unverified |
| Switch type | Observed type matches private/internal isolation expectations | External/bridged → fail closed for lab use |
| Host OS sharing | No unrestricted host OS sharing / admin shares exposed to guest | Unrestricted shares → fail |
| Production bridge | No binding to production corp/domain uplink for lab switch | Bridged to production → fail |
| Guest visibility | Documented expected guest view; not assumed from name | Unobserved → Unverified |
| Cross-lab leakage | Lab switch not shared with production VMs | Shared with production VMs → fail |

Until these are independently evidenced, status remains **`NetworkIsolationNotVerified`** / **`ActualIsolationVerified=False`** even if policy is `PolicyValidated`.

## Evidence custody (proposed)

- Separate report namespace: **`m6c`**
- Fields: Git commit SHA, host identity, discovery timestamps, command inventory (read-only), artifact hashes, Unknown/Unverified markers, approval binding digests
- Must not overwrite M1–M6B baselines under `C:\XboxOS\Logs`
- Incomplete information remains **`Unknown`** or **`Unverified`** — never silently upgraded to Verified

## Fail-closed decisions (proposed)

| Condition | Decision |
|-----------|----------|
| Missing operator approval | `HostDiscoveryBlocked` |
| Approval replay / expired / role collapse | `HostDiscoveryBlocked` |
| Hypervisor cmdlets unavailable | Continue with `Unavailable` domain results; do not invent; still no provisioning |
| Insufficient permissions | Domain `Unverified`; never elevate or prompt for privilege escalation automation |
| Unsupported configuration | Fail closed for lab readiness promotion; discovery report still retained |
| Unverified isolation | Keep `ActualIsolationVerified=False` |
| Any write API attempted by tooling | Hard invariant violation |

Terminal lab-provisioning outcome remains **`LabProvisioningBlocked`**. Layer D remains disabled.

## Relationship to prior milestones

| Milestone | Role relative to 6C |
|-----------|---------------------|
| M6A | Experiment planning / auth simulation; still not execution |
| M6B | Simulated lab topology + policy; isolation not host-verified |
| **M6C** | Read-only host discovery + independent isolation evidence criteria |
| Later | Separately gated provisioning / mutation — not designed here |

## Explicit non-goals

Do not (in design or any future 6C implementation):

- Execute writable DISM
- Export, mount, or modify a WIM/ISO
- Create, start, stop, or delete VMs
- Create or change virtual switches
- Create, attach, or modify VHD/VHDX files
- Change host firewall or networking
- Remove AppX packages or disable Windows features
- Activate Layer D or experimental mutation
- Treat M6B simulation success as host-discovery authorization

## Proposed acceptance criteria (implementation milestone, future)

Milestone 6C may be accepted only when all of the following are true — still without authorizing provisioning or mutation:

1. **Read-only discovery** — All host/hypervisor inspection is read-only; no VM, switch, VHD, or network setting is changed.
2. **No privileged provisioning** — No infrastructure create/enable/install actions occur.
3. **No image mutation** — No Windows images are exported or mounted; no writable DISM.
4. **Explicit operator approval** — Real-host inspection requires a valid, non-replayable approval bound to scope and tooling revision.
5. **Separate evidence namespace** — Results stored under `m6c`; M1–M6B reports remain untouched.
6. **Honest unknowns** — Incomplete host information remains `Unknown` or `Unverified`.
7. **Independent isolation criteria** — Declared IsolatedSwitch alone never sets `ActualIsolationVerified=True`.
8. **Provisioning remains blocked** — Final lab decision remains non-provisioning (`LabProvisioningBlocked` or equivalent).
9. **Layer D remains disabled** — No path from discovery evidence to execution authorization.
10. **Hyper-V not assumed** — Unavailable hypervisor tools fail closed into documented Unverified/Unavailable states, not fabricated readiness.
11. **Simulation-tested contracts** — Pester coverage for approval missing/replay, unavailable commands, insufficient permissions, isolation-not-proven, and all mutation/provisioning flags False.
12. **CI green** — Parser, Pester, and PSSA error gates pass without weakening safety checks.

## Remaining risks (pre-implementation)

1. Read-only APIs may still require administrator rights on some hosts — approval and documentation must address elevation without automating privilege gain.
2. CIM/WMI surfaces vary across Windows SKUs; Unknown must dominate over guesswork.
3. Enumerating existing VMs/switches may expose sensitive names — evidence redaction policy needed.
4. Operators may misread a successful discovery report as permission to provision — documentation and decision enums must remain explicit.

This proposal does **not** authorize implementing Milestone 6C, running hypervisor commands, or enabling experimental mutation.
