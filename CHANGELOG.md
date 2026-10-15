# Changelog

All notable changes to XboxOS11. Versions follow [Semantic Versioning](https://semver.org/). The single version source is [`VERSION`](VERSION).

## [1.0.0] — 2026-10-15

First production release: a native Windows app and PowerShell toolkit that build a gaming-focused Windows 11 installation ISO from your own official Microsoft ISO.

### Added

- **XboxOS11 Builder app** (WinUI 3, .NET 10, self-contained x64/ARM64). Guided workflow: Source → Preset → Components → Drivers & setup → Validate & build. Includes live phase progress, cancellation, unattend preview, profile open/save/recent, and *Restart as administrator*. ([M8](docs/m8-winui-builder.md))
- **Build profiles and presets** (`xboxos-build-profile-v1`). Four presets (`gaming-balanced`, `gaming-lean`, `handheld-xbox-mode`, `stock-safe`). Strict validation rejects requirement bypasses, security removal, product keys, disk wiping, and protected components. ([M7](docs/m7-builder-backend-contracts.md))
- **Profile-driven builds**: `scripts/Invoke-XboxOSBuild.ps1` with dry run and `XBOXOS-EVENT` progress, and the `scripts/Invoke-XboxOSBuilderApi.ps1` JSON API.
- **Safe autounattend generation**: languages, time zone, EULA, privacy, optional `StartupToGamingHome`, and first-logon setup. No disk, key, account, or bypass settings.
- **Reversible gaming optimizations** (`postinstall/Set-GamingOptimizations.ps1`, `config/gaming-tweaks.json`). Original values are captured and `-Restore` is exact. Power plan, Game Bar, and security are never changed. ([M9](docs/m9-gaming-performance.md))
- **X3D/Radeon-aware verification** in `Verify-System.ps1`.
- **Recovery**: every image carries `build-record.json` and `Restore-XboxOS11Components.ps1` (re-enable features, restore gaming settings, reinstall removed apps from the Store). ([Recovery](docs/recovery.md))
- **Release engineering**: `scripts/New-XboxOSRelease.ps1` (app + toolkit zips, SHA-256 sums, release manifest), a tag-triggered release workflow, and a version-consistency check. ([Release engineering](docs/release-engineering.md))
- **Controlled live read-only host discovery (Gate A)**: durable replay store, independent approval verifier, read-only invoker AST gate. ([M6E](docs/m6e-controlled-live-discovery-contracts.md))

- **Lean image (Tiny11-class)**: the `gaming-tiny` preset, 18 more removable inbox apps, optional capability removal, offline defaults for new accounts (no sponsored apps/ads, clean taskbar, no OneDrive auto-install, Edge first-run skipped), component store cleanup with optional ResetBase, and `install.esd` recompression. Store, Xbox, Edge/WebView2, Defender, Update, and WinRE are always kept. ([M11](docs/m11-lean-image.md))
- **Optional local account** (documented `HideOnlineAccountScreens`) and an **opt-in, warned** unsupported-hardware setting (off by default).

### Changed

- `Setup-Gaming.ps1` is now a wrapper over `Set-GamingOptimizations.ps1`.
- `Install-Launchers.ps1` passes the winget `--source`, so the Microsoft Store Xbox app installs.
- Dry runs no longer require Windows ADK or 40 GB of free space.
- An exact edition picked from the ISO also sets `target.edition`.
- ISO export removes every original `install.wim`/`install.esd`/`install*.swm` before adding the serviced image (retail ISOs ship `install.esd`).

### Security

- Profiles cannot express `BypassNRO`, Defender/SmartScreen/UAC changes, product keys, activation, or disk configuration. Hardware checks can only be skipped through the explicit `allowUnsupportedHardware` opt-in.
- Media overlays may only add `autounattend.xml` and `sources\$OEM$` files. Boot and image files are rejected twice.

## Earlier milestones

M1–M6D (image build foundation, servicing plan engine, execution safety, read-only preflight, dependency evidence, experiment planning, lab infrastructure, and host-discovery contracts) are documented in [docs/milestones.md](docs/milestones.md) and their completion baselines.
