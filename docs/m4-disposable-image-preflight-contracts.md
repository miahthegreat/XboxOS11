# Milestone 4 — Disposable Image Preflight Contracts

Milestone 4 integrates the M2 plan engine and M3 safety architecture with a **read-only** disposable-image lifecycle. Writable servicing remains unauthorized.

## Versions

| Contract | Version |
|----------|---------|
| Preflight engine | `4.0.0` |
| Read-only DISM adapter | `readonly-dism-v1` |
| Disposable workspace | `workspace-v1` |
| Image integrity | `image-integrity-v1` |
| Approval authentication design | `approval-auth-v1` |
| Coordinates with | plan `2.1.0` / `plan-hash-v1`, safety `3.0.0` |

## Hard invariants

| Flag | Value |
|------|-------|
| `realDismExecutionEnabled` | Always `false` |
| `modifyingCommandsInvoked` | Always `false` |
| `executionAuthorized` | Always `false` |
| Live read-only preflight | Disabled until explicit post-review operator authorization |

## Read-only DISM adapter (`readonly-dism-v1`)

Allowlisted operations only (no general argument passthrough):

| Operation | Class |
|-----------|-------|
| DISM version inspection | PureInspection |
| Source WIM/ISO image info | PureInspection |
| Disposable WIM export | DisposablePreparation |
| Exported-image verification | PureInspection |
| Read-only image mount | DisposablePreparation |
| Get packages / AppX / features | PureInspection |
| Mounted-image inspection | PureInspection |
| Unmount `/Discard` | Cleanup |

**Prohibited:** writable mount, `/Commit`, AppX removal, feature disable, driver/package inject, production ISO build, global cleanup without ownership proof.

## Source-image identification (`image-integrity-v1`)

- Expected ISO path: `C:\XboxOS\Sources\Windows11_Client_x64_en-us_26300_9457.iso`
- Expected SHA256: `BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650`
- Edition: Windows 11 Pro (exact name match; index discovered dynamically — never hardcode index 6)
- Build `26300.9457`, DisplayVersion `26H2` when present

Fail closed on hash mismatch, edition ambiguity, missing elevation (live), insufficient disk, unsafe paths, or unrelated mounts.

## Disposable workspace (`workspace-v1`)

- Work root: `C:\XboxOS\Work` (never OneDrive / never inside repo)
- Reports: `C:\XboxOS\Logs`
- Ownership token binds process, workspace path, and disposable WIM identity
- Cleanup is scoped; no global `/Cleanup-Mountpoints` without ownership validation

## Inventory / drift / dependency

Reuse M3 `drift-v1` and `dependency-v1` results. Fresh Authoritative inventory from the adapter (or fixtures in CI) must be compared to the M2 plan snapshot. Incomplete dependency graphs remain `Unknown` / `MissingEvidence`. Approval cannot override critical gaps.

## Approval authentication design (`approval-auth-v1`)

Local JSON approvals are not trusted as authenticated. Design target:

- RSA-SHA256 signatures over canonical binding payload
- Trusted public key store
- Expiration, revocation, replay prevention (nonce + contentHash)
- Operator identity + plan/image binding
- Audit integrity

Milestone 4 ships schema validation and signature verify tests with **test keys only**. Signature success never enables real DISM mutation.

## Preflight decision reporting

Reports distinguish:

- `Simulation` — mocks/fixtures (CI default)
- `LiveReadOnly` — future operator-authorized path (disabled by default)

Both must keep real execution flags false.
