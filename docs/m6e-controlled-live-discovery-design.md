# Milestone 6E — Controlled Live Read-Only Host Discovery

**Status:** Design proposal only. **Not implemented. Not authorized.**

This document proposes the next controlled stage after Milestone 6D: enabling a **real-host read-only adapter** only under two independent acceptance gates. It does **not** authorize VM provisioning, host modifications, Windows image mutation, DISM writable servicing, or Layer D.

Milestone 6D delivered tested contracts with live activation structurally False. Milestone 6E exists only to define how implementation review (Gate A) and a single operator-controlled run (Gate B) may later authorize **read-only observation** — still without provisioning or mutation.

Merging this design (or any future implementation PR) must **not** automatically execute live discovery.

## Goal

Define controls and procedures so that, after explicit dual-gate acceptance:

1. A real-host read-only adapter can execute allowlisted observation commands only
2. Exactly one named, bounded run can be operator-authorized
3. Evidence is emitted under a separate **`m6e`** namespace
4. Successful inspection never implies provisioning or writable servicing authorization

## Two independent acceptance gates

### Gate A — Implementation review

Additional controls required **before** enabling a real-host read-only adapter in product code:

| Control | Requirement |
|---------|-------------|
| Explicit per-run human authorization | No silent/default live path |
| Trusted non-test approval key | Fixture/test keys rejected for live trust |
| Exact host identity binding | Approval host key must match selected host |
| Clean and verified Git commit | Dirty/unverified tooling blocks live execution |
| Approved operation scope | Categories and allowlist only |
| Single-use run identity | One run identity per authorization |
| Durable replay prevention across processes | Persist nonce/run records beyond process memory |
| Short approval expiration | Fail closed when expired |
| Independent authorization validation | Separate verifier from command executor |
| Read-only command and parameter allowlist | Typed ops only; reject free-form args/shell |
| Per-operation authorization revalidation | Re-check immediately before each op |
| Safe handling of permission failures | Remain `Unverified`; no auto-repair |
| Non-elevated default | Default path must not require elevation |
| No automatic privilege escalation | Human-driven elevation only, if ever needed |
| Sensitive information redaction | Host/VM/network/path/credential metadata |
| No host mutation or infrastructure provisioning | Structurally blocked transitions |

#### Process-local nonce limitation (M6D)

Milestone 6D registers nonces and run identities in **process-local** HashSet registries. That prevents replay inside one process but cannot stop:

- Restarting the process and reusing a captured approval
- Concurrent processes sharing the same approval artifact
- Copying approval JSON across machines/sessions

#### Persistent replay protection (design)

Gate A implementation must introduce durable anti-replay, for example:

- Append-only, integrity-protected store under a non-cloud path (e.g. `C:\XboxOS\Lab\Auth\used-approvals.jsonl` or equivalent)
- Records: nonce, run identity, binding hash, host identity key, Git SHA, issued/expires UTC, consumed UTC
- Atomic claim: refuse if nonce or run identity already present
- Optional signature over store checkpoints
- Retention past approval expiry so late replays still fail
- No secret material (private keys/tokens) stored in the replay log

Until durable replay protection exists, live activation must remain disabled.

### Gate B — Operator-controlled execution

Separate procedure for **exactly one** future approved read-only discovery run. This procedure must not run automatically upon merging code.

#### Before any real command

1. Present exact allowlisted commands and approved scope to the operator
2. Verify the selected host identity
3. Verify the tooling Git revision (clean, matches approval)
4. Verify approval authenticity (trusted key, signature, expiry, unused nonce/run identity)
5. Verify log destination and redaction settings (outside OneDrive; operator-reviewed)
6. Confirm rollback is unnecessary because no modifying operations are permitted
7. Obtain explicit authorization for **that particular run** (human acknowledgment recorded)

#### During the run

- Execute only typed allowlisted read-only operations
- Revalidate approval before each operation
- Abort on unexpected side effects, non-allowlisted attempts, or permission anomalies that suggest unsafe continuation
- Never auto-elevate

#### After the run

- Emit `m6e` evidence
- Leave unverified isolation unverified
- Keep provisioning and Layer D blocked
- Mark run identity / nonce consumed in durable store

## Evidence requirements (`m6e` namespace)

Reports under **`m6e`** must record:

- Approval binding (hash, layer, run identity, key fingerprint)
- Host identity
- Git SHA and verification state
- Exact commands and statuses (including exit/unavailable)
- Discovery start/completion UTC timestamps
- Independently observed hypervisor capabilities
- Existing VM and virtual-switch metadata (redacted)
- Network-isolation limitations
- Storage and resource availability
- Redaction status
- Source evidence hashes
- Unavailable / Unverified fields
- Final blocked provisioning decision

Prior M1–M6D baselines must remain untouched.

## Safety condition distinctions

Keep these states **distinct** (never collapse):

| State | Meaning |
|-------|---------|
| `HostDiscoveryAuthorized` | Valid live read-only approval for this run |
| `ReadOnlyHostInspectionCompleted` | Allowlisted read-only ops finished under that approval |
| `HypervisorObserved` | Hypervisor/management facts independently observed |
| `NetworkIsolationVerified` | Full independent isolation criteria met with direct observation |
| `LabProvisioningAuthorized` | Separate future gate — **not** granted by 6E inspection |
| `WritableServicingAuthorized` | Separate future gate — **not** granted by 6E inspection |

**Successful read-only inspection must never imply provisioning or modification authorization.**

Host switch inventory (including a switch named `IsolatedSwitch`) alone must not establish `NetworkIsolationVerified`.

## Relationship to prior milestones

| Milestone | Role relative to 6E |
|-----------|---------------------|
| M6C | Mocked discovery framework; default HostDiscoveryBlocked |
| M6D | Authorized contracts; live activation inactive; process-local anti-replay |
| **M6E** | Controlled live read-only discovery under Gate A + Gate B |
| Later | Separately gated provisioning / mutation — not designed here |

## Acceptance criteria

### Gate A acceptance (implementation)

1. Durable replay protection implemented and tested
2. Real-host read-only adapter remains behind explicit activation
3. Trusted-key enforcement and host/Git/scope/expiry/run binding verified
4. Mocked negative cases remain green in CI (no live commands in CI)
5. All mutation/provisioning/Layer D flags remain False
6. `m6e` namespace does not overwrite prior baselines

### Gate B acceptance (operational; later explicit operator decision)

1. Operator authorizes one named host and bounded scope
2. Pre-run checklist completed and recorded
3. Exactly one read-only run executes
4. Evidence reviewed independently under `m6e`
5. No VM, switch, network, VHD, source ISO, or Windows image changes occur
6. Unverified isolation remains unverified unless independent criteria are met
7. `LabProvisioningAuthorized` and `WritableServicingAuthorized` remain false

## Product boundary

User-facing WinUI 3 XboxOS11 Builder workflows (ISO select → preset/custom → dependency review → drivers/options → validate → ISO export → save config) remain **separate** from this lab authorization architecture. Milestone 6E must not implement the GUI, ISO production, or new servicing functionality.

## Remaining risks (pre-implementation)

1. Durable store compromise or deletion could weaken replay protection — integrity checks and fail-closed behavior required.
2. Elevation UX may tempt automation — must stay human-gated.
3. Operators may treat `ReadOnlyHostInspectionCompleted` as provisioning permission — decision enums must stay explicit.
4. Partial host visibility can look “green” if Unavailable/Unverified is not prominent.

This proposal does **not** authorize implementing Milestone 6E, running live host-discovery commands, or enabling experimental mutation.
