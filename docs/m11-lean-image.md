# Milestone 11 — Lean Image (Tiny11-class, serviceable)

The `gaming-tiny` preset and the lean-image options produce a Tiny11-class image: far fewer inbox apps, no optional extras, no sponsored content, and a much smaller `install.esd`. Unlike Tiny11, the result stays **serviceable, secure, and recoverable**, and it keeps everything a gaming PC needs.

> **Evidence status.** These phases are implemented and unit-tested with fakes (no real DISM, no real registry hive). A real lean build and install test have **not** been run yet. See [v1 release readiness](v1-release-readiness.md). Image sizes below are expectations, not measurements.

## XboxOS11 Tiny vs Tiny11

| | Tiny11 | XboxOS11 `gaming-tiny` |
|---|--------|------------------------|
| Removes non-gaming inbox apps | Yes | Yes (27 candidates, each opt-in) |
| Removes Xbox app / Game Bar / Gaming Services | Yes | **No.** Protected, required for Xbox mode and Game Pass |
| Removes Microsoft Store | Some variants | **No.** Protected |
| Removes Edge | Yes | **No.** WebView2 is needed by the Xbox app and launchers. Only first-run pages are skipped |
| OneDrive | Removed | Not installed for new accounts (reinstall: `winget install Microsoft.OneDrive`) |
| Sponsored apps / ads / tips | Disabled | Disabled for new accounts (documented settings) |
| Optional capabilities (Steps Recorder, IE mode, Math Input, …) | Removed | Removed (8 candidates, protected list respected) |
| Component store cleanup + ResetBase | Yes | Yes (opt-in, warned) |
| ESD recompression | Yes | Yes (`install.esd`, `/Compress:recovery`) |
| Windows Update / Defender / WinRE | Kept in tiny11, **removed in tiny11 core** | **Always kept** |
| Hardware requirement bypass | Always on | **Opt-in only, off by default**, with warnings |
| Local account | BypassNRO | Documented `HideOnlineAccountScreens` |
| Undo / recovery | Reinstall | `build-record.json` + `Restore-XboxOS11Components.ps1` |
| Reproducible, saved profiles, GUI, validation | No | Yes |

## Profile schema additions (optional; older v1 profiles stay valid)

```json
"capabilities": { "remove": ["StepsRecorder", "MathRecognizer", "InternetExplorerMode", "PowerShellISE", "WordPad", "FaxScan", "QuickAssistLegacy", "ExtendedWallpapers"] },
"image": {
  "componentCleanup": true,
  "resetBase": true,
  "compression": "Recovery",
  "tweaks": ["NoSponsoredApps", "NoTipsAndSuggestions", "CleanTaskbar", "NoOneDriveForNewAccounts", "EdgeNoFirstRun"]
},
"setup": { "...": "...", "localAccount": false, "allowUnsupportedHardware": false }
```

Validation:

- Capability IDs must exist in `config/remove-capabilities.json` and must not match `compatibility.json` `protectedCapabilities` (Windows Media Player, text-to-speech, …).
- `image.compression` must be one of `Default | Max | Recovery`. `resetBase` requires `componentCleanup`. Unknown image-setting IDs and unknown keys in either section are errors.
- `localAccount` and `allowUnsupportedHardware` require `setup.unattend`. Both produce warnings.

## Pipeline

```
ImportSource → MountImage → InventoryBefore → RemoveApps → DisableFeatures → RemoveCapabilities*
→ AddDrivers → AddUpdates → ImageTweaks* → ComponentCleanup* → InventoryAfter → DismountCommit
→ Recompress* → Validate → ExportIso                                        (* = new, optional)
```

| Phase | Script | What it does |
|-------|--------|--------------|
| RemoveCapabilities | `scripts/Remove-Capabilities.ps1` | `DISM /Get-Capabilities` inventory, then `/Remove-Capability` for enabled candidates that match exactly one installed capability. Protected capabilities are skipped |
| ImageTweaks | `scripts/Set-ImageTweaks.ps1` | Loads `Users\Default\NTUSER.DAT` / `config\SOFTWARE` under run-owned `HKLM\XboxOSImage-*` keys, writes only via `reg.exe`, and always unloads in `finally`. An unload failure throws `RecoveryRequired`, so the mount is discarded and never committed |
| ComponentCleanup | `scripts/Optimize-ImageSize.ps1` | `DISM /Cleanup-Image /StartComponentCleanup [/ResetBase]` on the mounted image |
| Recompress | `scripts/Compress-Image.ps1` | `DISM /Export-Image /Compress:max` (→ `install.wim`) or `/Compress:recovery` (→ `install.esd`) with `/CheckIntegrity` |

`Export-ISO.ps1` now removes **every** original `install.wim`/`install.esd`/`install*.swm` from the copied ISO tree before copying the serviced image in. This also fixes an older latent issue: retail ISOs ship `install.esd`, so the previous export could leave two install images. ESD files are never split; an oversized ESD produces a warning about FAT32 USB writers.

## Catalogs

- `config/remove-apps.json`: 18 new candidates (Bing search, Power Automate, To Do, Dev Home, Clock, Feedback Hub, Sound Recorder, Phone Link, Media Player, Movies & TV, Quick Assist, Mail & Calendar, Maps, People, Cortana, Family, Widgets). All are disabled by default, so the base config and existing presets are unchanged.
- `config/remove-capabilities.json`: 8 candidates, all disabled by default.
- `config/image-tweaks.json` (`xboxos-image-tweaks-v1`): `NoSponsoredApps`, `NoTipsAndSuggestions`, `CleanTaskbar`, `NoOneDriveForNewAccounts`, `EdgeNoFirstRun`. Each names the Settings page that controls it. Plus a never-change list (Update, Defender, SmartScreen, firewall, telemetry below the Pro minimum, Store/Xbox, WinRE).

## Opt-in hardware bypass

With `setup.allowUnsupportedHardware: true`, the generated `autounattend.xml` adds `RunSynchronous` commands in the windowsPE pass. They set `HKLM\SYSTEM\Setup\LabConfig` `BypassTPMCheck`, `BypassSecureBootCheck`, `BypassRAMCheck`, and `BypassCPUCheck` for that Setup session only. `boot.wim` is not modified. It's off in every preset, flagged in the app with an error-level banner, and recorded in the build record.

## Recovery

`build-record.json` now lists removed capabilities, image settings (with their Settings pages), compression, ResetBase, and the opt-ins. `Restore-XboxOS11Components.ps1 -Capabilities` re-adds removed capabilities with `Add-WindowsCapability` (administrator, internet). Image settings are per-account defaults; change them in the listed Settings pages.

## Builder app

- Components page: a new *Optional Windows capabilities* section, with protected items locked.
- Drivers & setup page: a local-account toggle, an unsupported-hardware toggle with an error banner, and an *Image size and defaults* card (component cleanup, ResetBase, compression, defaults for new accounts).
- The summary shows the capability count, compression, and an explicit `UNSUPPORTED HARDWARE ALLOWED` marker.
