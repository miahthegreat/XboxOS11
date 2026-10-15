# Milestone 4 — Disposable Image Preflight Contracts

Milestone 4 integrates the M2 plan engine and M3 safety architecture with a **read-only** disposable-image lifecycle. Writable servicing remains unauthorized.

## Versions

| Contract | Version |
|----------|---------|
| Preflight engine | `4.1.1` |
| Read-only DISM adapter | `readonly-dism-v1` |
| Disposable workspace | `workspace-v1` |
| Image integrity | `image-integrity-v1` |
| Approval authentication design | `approval-auth-v1` |
| Coordinates with | plan `2.1.0` / `plan-hash-v1`, safety `3.0.0` |

## Hard invariants

| Flag | Value |
|------|-------|
| `realDismExecutionEnabled` | Always `false` (writable / mutating DISM) |
| `modifyingCommandsInvoked` | Always `false` |
| `executionAuthorized` | Always `false` |
| Live read-only activity | Recorded separately (`realReadOnlyInspectionOccurred`, `disposableExportOccurred`, `readOnlyMountOccurred`) |

## Read-only DISM adapter (`readonly-dism-v1`)

Allowlisted operations only (no general argument passthrough):

| Operation | Class |
|-----------|-------|
| DISM version inspection | PureInspection |
| Source WIM/ESD image info | PureInspection |
| Disposable WIM export (+ `/CheckIntegrity`) | DisposablePreparation |
| Exported-image verification | PureInspection |
| Read-only image mount | DisposablePreparation |
| Get packages / AppX / features | PureInspection |
| Mounted-image inspection | PureInspection |
| Unmount `/Discard` | Cleanup |

**Prohibited:** writable mount, `/Commit`, AppX removal, feature disable, driver/package inject, production ISO build, global cleanup without ownership proof.

Adapters:

- `New-XboxOSMockReadOnlyDismAdapter` — CI / simulation
- `New-XboxOSRealReadOnlyDismAdapter` — allowlisted native DISM (injectable runner for tests)

## Source-image identification (`image-integrity-v1`)

- Expected ISO path: `C:\XboxOS\Sources\Windows11_Client_x64_en-us_26300_9457.iso`
- Expected SHA256: `BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650`
- Edition: Windows 11 Pro (exact name match; index discovered dynamically — never hardcode index 6)
- Expected build `26300.9457`, DisplayVersion `26H2` (kept separate from observed values)
- Live path mounts the ISO, resolves `sources\install.wim` or `install.esd`, exports Pro, then dismounts the ISO
- After read-only mount, **observed** edition/build/UBR/DisplayVersion/architecture are collected from DISM image info + mounted SOFTWARE hive (never substituted from expected constants)
- Fail closed when observed identity cannot be established or does not match expected source identity
- After `/Unmount-Image /Discard`, `/Get-MountedImageInfo` must confirm the owned mount is gone; cleanup success requires that confirmation
- Original ISO is never modified; SHA256 re-verified after the run

Fail closed on hash mismatch, edition ambiguity, missing elevation (live), insufficient disk, unsafe paths (OneDrive / traversal / reparse), unrelated mounts, incomplete inventory, or unverified cleanup.

## Disposable workspace (`workspace-v1`)

- Work root: `C:\XboxOS\Work` (never OneDrive / never inside repo)
- Reports: `C:\XboxOS\Logs`
- Ownership token binds process, workspace path, and disposable WIM identity
- Cleanup is scoped; no global `/Cleanup-Mountpoints` without ownership validation

## Inventory / drift / dependency

Reuse M3 `drift-v1` and `dependency-v1` results. Fresh Authoritative inventory from the adapter (or fixtures in CI) must be compared to the M2 plan snapshot. Incomplete dependency graphs remain `Unknown` / `MissingEvidence`. Approval cannot override critical gaps. Prior approvals are not reused when inventory fingerprints differ.

## Approval authentication design (`approval-auth-v1`)

Local JSON approvals are not trusted as authenticated. Design target:

- RSA-SHA256 signatures over canonical binding payload
- Trusted public key store
- Expiration, revocation, replay prevention (nonce + contentHash)
- Operator identity + plan/image binding
- Audit integrity

Milestone 4 ships schema validation and signature verify tests with **test keys only**. Signature success never enables real DISM mutation. Test RSA keys are development fixtures only and must never be treated as production-trusted signing keys.

## Preflight decision reporting

| Namespace | Mode |
|-----------|------|
| `m4-simulation` | Simulation — mocks/fixtures (CI default) |
| `m4-live-readonly` | LiveReadOnly — separate report stem; does not overwrite M1 evidence |

Both must keep writable-execution flags false.

## Operator-approved live read-only test (manual only)

**Do not run this from CI or unattended automation.** Requires an elevated PowerShell session, the expected ISO at the path below, and free space under `C:\XboxOS\Work`.

```powershell
# Elevated PowerShell only — creates temporary files, exports a disposable WIM,
# and temporarily changes host DISM mount state. Source ISO is not modified.
pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\Users\schmi\OneDrive\WinDev Apps\XboxOS11\scripts\Test-DisposableImagePreflight.ps1" `
  -Mode LiveReadOnly `
  -IsoPath "C:\XboxOS\Sources\Windows11_Client_x64_en-us_26300_9457.iso" `
  -WorkRoot "C:\XboxOS\Work" `
  -OutputDirectory "C:\XboxOS\Logs" `
  -OutputStem "XboxOS11-disposable-preflight-m4-live-readonly" `
  -ConfirmLiveReadOnlyPreflight `
  -AllowLiveReadOnlyPreflight `
  -IUnderstandTemporaryHostState
```

Expected report outputs (outside OneDrive):

- `C:\XboxOS\Logs\XboxOS11-disposable-preflight-m4-live-readonly.json`
- `C:\XboxOS\Logs\XboxOS11-disposable-preflight-m4-live-readonly.md`
