# XboxOS11 Architecture

## Purpose

XboxOS11 is a manifest-driven PowerShell framework that customizes an official Microsoft Windows 11 installation image into a gaming-focused ISO. It prefers reproducible offline servicing with DISM over ad-hoc host tweaks.

## Design principles

1. **Manifest-driven** — removal, feature, driver, service, and compatibility policy live in `config/*.json`.
2. **Inventory-first** — components are discovered in the mounted image before modification.
3. **Protected gaming surface** — Store, Xbox, Gaming Services, Defender, Update, DirectX, WebView2, and related dependencies cannot be removed through normal manifests.
4. **Isolated workspace** — each build uses `artifacts/workspace/<buildId>` and never modifies the host OS image store by default.
5. **Fail closed** — ambiguous package matches, DISM errors, and failed phases discard uncommitted image changes.
6. **No Microsoft redistribution** — the repo never contains Windows ISOs, WIMs, CABs, or MSUs.

## Pipeline

```text
Test-Prerequisites
    -> Import-Source (mount ISO, copy tree, export edition WIM)
    -> Mount-Image
    -> Inventory-Image (Before)
    -> Remove-Apps
    -> Disable-Features
    -> Add-Drivers (optional INF packages)
    -> Add-Updates (optional CAB/MSU)
    -> Inventory-Image (After)
    -> Dismount-Image (commit on success only)
    -> Validate-Image
    -> Export-ISO (oscdimg, split WIM when needed)
```

`scripts/Build-ISO.ps1` orchestrates these phases, writes structured logs, and emits `BuildReport-*.json`.

## Module layout

`modules/XboxOS.Build` provides shared helpers:

- configuration loading and schema checks
- ADK/DISM discovery
- logging and build context
- package/feature matching and protection
- driver/update discovery and ordering
- workspace safety and mount cleanup

Scripts remain thin wrappers so phases can be run independently during development.

## Post-install layer

`postinstall/` scripts are independently executable and intentionally **not** chained into Windows Setup for Milestone 1:

| Script | Role |
|--------|------|
| `Setup-Gaming.ps1` | Safe Game Mode / optional HAGS toggles |
| `Setup-XboxMode.ps1` | Conservative Xbox mode guidance + optional unattend snippet |
| `Install-Launchers.ps1` | Opt-in winget installs for trusted launcher IDs |
| `Verify-System.ps1` | Presence/health report for gaming dependencies |

## Xbox Full Screen Experience notes

- Documented for Windows 11 24H2+ as **Xbox mode**.
- Desktop enablement is primarily Settings UI / Game Bar / `Win+F11`.
- `Microsoft-Windows-Gaming-Configuration` / `StartupToGamingHome` is a documented OEM unattend setting; do not claim desktop auto-start until validated on the target build.
- Explorer.exe is never replaced.

## Safety boundaries

- No activation bypasses or licensing changes.
- No undocumented binary patching.
- No silent third-party installs.
- TPM, Secure Boot, Defender, and VBS defaults are left alone.
- A smaller ISO is not treated as a performance win by itself.
