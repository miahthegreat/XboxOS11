# Milestone 9 — Gaming Performance and Xbox Mode

Post-install gaming configuration that is **supported, documented, measurable, and reversible**, tuned for Ryzen 7 7800X3D / Radeon RX 9070 XT class hardware, without disabling security for synthetic gains.

## Catalog: `config/gaming-tweaks.json` (`xboxos-gaming-tweaks-v1`)

Every tweak maps to a Windows Settings page and to specific registry values.

| ID | Settings page | Scope | Default | Values |
|----|---------------|-------|---------|--------|
| `GameMode` | Gaming › Game Mode | User | on | `HKCU\Software\Microsoft\GameBar\AutoGameModeEnabled=1` |
| `HardwareAcceleratedGpuScheduling` | Display › Graphics › Advanced | Machine (restart) | off | `HKLM\…\GraphicsDrivers\HwSchMode=2` |
| `WindowedGameOptimizations` | Display › Graphics | User | on | `DirectXUserGlobalSettings: SwapEffectUpgradeEnable=1` |
| `VariableRefreshRate` | Display › Graphics | User | off | `DirectXUserGlobalSettings: VRROptimizeEnable=1` |
| `BackgroundRecordingOff` | Gaming › Captures | User | on | `HKCU\…\GameDVR\HistoricalCaptureEnabled=0` |
| `PointerPrecisionOff` | Mouse › Additional settings | User | off | `HKCU\Control Panel\Mouse` speed/thresholds `0` |

`GameMode` and `HardwareAcceleratedGpuScheduling` are driven by the existing profile booleans (`setup.postInstall.gameMode` / `hardwareAcceleratedGpuScheduling`). The others are selected through the optional profile key `setup.postInstall.optimizations`. That key is optional, so older v1 profiles remain valid.

### Never changed

| Item | Why |
|------|-----|
| Power plan | Ryzen X3D processors rely on **Balanced** plus the AMD chipset driver's 3D V-Cache Performance Optimizer. High/Ultimate Performance can hurt gaming performance. |
| Xbox Game Bar | Needed for Xbox mode and used by the V-Cache optimizer to detect games |
| Core isolation / Memory integrity / VBS | Security, and required by some anti-cheat |
| Defender, Windows Update, firewall | Security baseline |
| CPU vulnerability mitigations | Security |

Tests assert that no catalog value touches power, Defender, Update, Device Guard, LSA, memory management, or Game Bar enablement.

## Applying and restoring: `postinstall/Set-GamingOptimizations.ps1`

```powershell
.\Set-GamingOptimizations.ps1 -List                     # catalog + never-changed list
.\Set-GamingOptimizations.ps1 -UseDefaults -WhatIf      # preview
.\Set-GamingOptimizations.ps1 -Enable VariableRefreshRate
.\Set-GamingOptimizations.ps1 -Restore                  # exact undo
```

- Before the **first** change to any value, it records the original state (present/absent, registry kind, data) in `C:\ProgramData\XboxOS11\gaming-state.json`. Later runs never overwrite that baseline.
- `-Restore` puts each value back exactly, or deletes it if it didn't exist before.
- `DirectXUserGlobalSettings` is shared by several Settings toggles (Auto HDR, VRR, windowed optimizations). Only the specific `Key=Value;` pair is edited and restored; other keys are preserved.
- It's idempotent: values that are already correct report `AlreadySet` and are not re-captured.
- Machine-scope tweaks are skipped with `SkippedRequiresAdministrator` when not elevated. Restart-requiring tweaks are flagged.
- It runs on inbox **Windows PowerShell 5.1** (verified) and PowerShell 7.
- `Setup-Gaming.ps1` is now a compatibility wrapper over this script.

The Builder stages `Set-GamingOptimizations.ps1` and `gaming-tweaks.json` into `sources\$OEM$\$$\Setup\Scripts\XboxOS11`. At first logon, `Invoke-PostInstall.ps1` applies the profile's selection and records one summary line per tweak.

## Verification: `postinstall/Verify-System.ps1`

New read-only checks:

- **Ryzen X3D**: Balanced power plan active, and AMD 3D V-Cache Performance Optimizer present (from the AMD chipset driver).
- **GPU**: flags *Microsoft Basic Display Adapter*, meaning the AMD Adrenalin driver isn't installed yet. Otherwise it reports the driver version.
- **Game Bar** enabled (required for Xbox mode and X3D game detection).

## Xbox mode

Unchanged policy: Xbox mode (Full Screen Experience) is turned on through Settings › Gaming › Xbox mode. `StartupToGamingHome` is offered through the `handheld-xbox-mode` preset with a desktop warning. `Setup-XboxMode.ps1` documents the manual workflow and never replaces the shell.

## Builder integration

- Backend: `setup.postInstall.optimizations` is validated against the catalog. Unknown IDs are errors, and IDs controlled by profile booleans are rejected. The API `catalog` now returns `optimizations` and `neverChange`.
- Presets: balanced/lean → windowed optimizations + background recording off; handheld adds VRR; stock-safe → none.
- App: the *First sign-in gaming setup* card lists the optimizations with their Settings page and restart notes, plus a *Never changed by XboxOS11* panel.

## Tests

- `tests/GamingOptimizations.Tests.ps1` (sandboxed under `HKCU:\Software\XboxOS11Tests`): catalog invariants, apply/restore round trips including a pre-existing value of a different setting, shared DirectX keys, single capture across repeated runs, `-WhatIf`, unknown IDs, restart flags, and first-logon integration.
- Builder tests cover optional-key validation and the overlay payload. .NET contract tests cover catalog optimizations and backend acceptance of client-selected optimizations.

No tweak was applied to this development machine's real registry.
