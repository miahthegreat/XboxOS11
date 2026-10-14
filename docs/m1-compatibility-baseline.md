# Milestone 1 — Read-only compatibility baseline

## Status

Milestone 1 is **complete** as a read-only foundation. Writable Windows image servicing is **not** authorized by this baseline.

| Item | Result |
|------|--------|
| Branch / PR | `fix/m1-dryrun-workspace-safety` / [PR #1](https://github.com/miahthegreat/XboxOS11/pull/1) |
| Elevated DISM compatibility | Passed (`DISM-Compatibility-20261014-2`) |
| Source image | Windows 11 Pro, build `26300.9457`, DisplayVersion `26H2` |
| Inventory schema | Flat arrays with full counts and DISM state metadata |
| Manifest overlap | `SMB1Protocol-Deprecation` protected via `neverDisable` only |
| Compatibility matrix | `docs/XboxOS11-compatibility-matrix-26300.9457.md` |

## Captured inventory (26300.9457 / 26H2)

| Inventory | Count | Notes |
|-----------|------:|-------|
| Packages | 146 | Installed=78, Staged=68 |
| Provisioned AppX | 47 | Flat `PackageName` identities |
| Optional features | 136 | Enabled=13, Disabled=122, Disabled with Payload Removed=1 (`NetFx3`) |

Feature-state accounting must remain complete: every inventory row contributes to exactly one DISM state bucket. Do not report only Enabled+Disabled when other states exist.

## Compatibility matrix semantics

| Status | Meaning |
|--------|---------|
| Present | Found, but candidate disabled in manifest (or non-actionable other state) |
| Absent | Not found in inventory |
| Protected | Blocked by compatibility / neverDisable policy |
| Eligible | Actionable later (AppX unprotected+enabled; features currently **Enabled**) |
| AlreadyDisabled | Disable candidate already satisfied; future servicing should **skip** |
| Ambiguous | Prefix match rejected; never authorize from ambiguous prefixes |
| Conflicting | Manifest inconsistency (enabled disable candidate ∩ neverDisable) |

Eligible is a planning signal only. It does **not** authorize removal, disable, export, or ISO production.

## Safety constraints carried into Milestone 2

- No writable DISM servicing without a separate approval gate
- Preserve ambiguity rejection and protected-component priority
- Keep workspace/logs under `C:\XboxOS` (never OneDrive for WIM/mount)
- Preserve `C:\XboxOS\Logs\DISM-Compatibility-20261014-2.*` as evidence
- Milestone 2 should start as design and safety validation before any image mutation

## Regenerating the matrix (read-only)

```powershell
.\scripts\Build-CompatibilityMatrix.ps1 `
  -CompatJsonPath 'C:\XboxOS\Logs\DISM-Compatibility-20261014-2.json'
```

This command does not run DISM or modify Windows images.
