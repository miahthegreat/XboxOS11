# Milestone 7 — Builder Backend Contracts

The Builder backend turns a saved, user-editable **build profile** into a validated, reproducible ISO build. It is the contract surface consumed by the native WinUI 3 XboxOS11 Builder (Milestone 8) and is usable directly from PowerShell.

| Contract | Value |
|----------|-------|
| Builder engine | `7.0.0` |
| Module | `0.7.0` |
| Profile schema | `xboxos-build-profile-v1` |
| Preset schema | `xboxos-builder-preset-v1` (`config/presets/*.json`) |
| Post-install options | `xboxos-postinstall-options-v1` |
| Frontend API | `xboxos-builder-api-v1` (`scripts/Invoke-XboxOSBuilderApi.ps1`) |
| Progress events | `XBOXOS-EVENT <json>` lines |

Module file: `modules/XboxOS.Build/BuilderProfile.ps1`. Tests: `tests/BuilderProfile.Tests.ps1`.

## User workflow → backend

| Builder step | Backend |
|--------------|---------|
| 1. Select a Windows 11 ISO | `source.isoPath`; `image-info` API lists editions (elevated, read-only mount) |
| 2. Choose a preset or Custom | `Get-XboxOSBuilderPreset`, `New-XboxOSBuildProfile -PresetId` |
| 3. Review dependency-aware changes | `Get-XboxOSBuildProfileReview` (protected components non-selectable) |
| 4. Drivers and installation options | `drivers`, `updates`, `setup` sections; `New-XboxOSUnattendXml` |
| 5. Validate | `Test-XboxOSBuildProfile [-ForBuild]` |
| 6. Produce the ISO | `scripts/Invoke-XboxOSBuild.ps1 -ProfilePath … [-DryRun] [-EmitEvents]` |
| 7. Save and reuse | `Export-XboxOSBuildProfile` / `Import-XboxOSBuildProfile` (JSON, stable SHA-256 profile hash) |

## Profile schema (`xboxos-build-profile-v1`)

```json
{
  "schemaVersion": "xboxos-build-profile-v1",
  "name": "My Rig",
  "description": "…",
  "presetId": "gaming-balanced",
  "source":   { "isoPath": "C:\\ISOs\\Win11.iso", "editionPattern": "*Pro*", "imageIndex": null },
  "apps":     { "remove": ["Clipchamp", "News"] },
  "features": { "disable": ["Smb1"] },
  "drivers":  { "enabled": false, "directory": "C:\\XboxOS\\Drivers" },
  "updates":  { "enabled": false, "directory": "C:\\XboxOS\\Updates" },
  "setup": {
    "unattend": true, "uiLanguage": "en-US", "inputLocale": "en-US", "systemLocale": "en-US", "userLocale": "en-US",
    "timeZone": "Pacific Standard Time", "hideEula": true, "privacy": "Minimal", "startupToGamingHome": false,
    "postInstall": { "enabled": true, "gameMode": true, "hardwareAcceleratedGpuScheduling": false, "launchers": ["Steam"] }
  },
  "output": { "directory": "C:\\XboxOS\\Output", "isoLabel": "XboxOS11" }
}
```

Validation is strict:

- Every section and key is required; **unknown keys are rejected**. Keys resembling TPM/Secure Boot/RAM/CPU check bypasses, `BypassNRO`/`LabConfig`, Defender/SmartScreen/UAC, product keys, activation, or disk configuration produce an explicit *unsupported setting* error. The schema has no way to express them.
- `apps.remove` / `features.disable` must reference manifest candidate IDs. Candidates that match `compatibility.json` protected patterns or `neverDisable` features are rejected.
- Locales must be canonical culture names. `timeZone` must be a Windows time zone ID. Launchers must come from the catalog (`Xbox, Steam, BattleNet, EA, Ubisoft, Epic`).
- `startupToGamingHome` and `postInstall` require `unattend`.
- Output must be outside the repository and outside cloud-synchronized folders. `isoLabel` is 1–32 `[A-Za-z0-9_]`.
- `-ForBuild` also requires the ISO and any enabled driver/update directory to exist, and warns about `.exe`/`.msi` installers in the driver folder.

## Presets

| ID | Summary |
|----|---------|
| `gaming-balanced` (recommended) | Removes 7 promotional consumer apps, disables XPS/SMB1/Work Folders, minimal privacy, Game Mode, Steam |
| `gaming-lean` | Balanced + Get Help, Tips, fax client |
| `handheld-xbox-mode` | Balanced + `StartupToGamingHome` (documented for handhelds; desktop warning) |
| `stock-safe` | No app removal, SMB1 only, no unattend |

## Generated unattend

`New-XboxOSUnattendXml` uses only documented components:

- `windowsPE`: `Microsoft-Windows-International-Core-WinPE` (languages), `Microsoft-Windows-Setup/UserData/AcceptEula` when `hideEula`
- `specialize`: `Microsoft-Windows-Gaming-Configuration/StartupToGamingHome` only when selected
- `oobeSystem`: `Microsoft-Windows-International-Core`, `Microsoft-Windows-Shell-Setup` (`TimeZone`, `HideEULAPage`, `ProtectYourPC` 3 = Minimal / 1 = Recommended, `FirstLogonCommands` when post-install is enabled)

It never contains disk configuration, product keys, accounts, passwords, auto-logon, or requirement bypasses. The output is parsed as XML before it is returned.

## Effective configuration and media overlay

`New-XboxOSBuilderEffectiveConfiguration` writes to `C:\XboxOS\Work\profiles\<name>-<hash12>\`, never the repo:

- `build.json`: repo build config with the profile's edition pattern, output, ISO label, and phase toggles, plus a `builderProfile` provenance block (name, preset, profile hash, engine)
- `remove-apps.json`, `disable-features.json`, `drivers.json`: copies with `enabled` set from the profile. `compatibility.json` always points to the repository's protected list.
- `media-overlay\autounattend.xml` and `media-overlay\sources\$OEM$\$$\Setup\Scripts\XboxOS11\` (post-install scripts + `postinstall.json`)
- `profile.json`: the exact profile used

`Test-XboxOSMediaOverlay` permits only `autounattend.xml` at the root and files under `sources\$OEM$`. Boot/image files (`.wim .esd .swm .efi .sdi`) are rejected. `Build-ISO.ps1 -MediaOverlayDirectory` validates the overlay up front, and `Export-ISO.ps1` validates again before copying it onto the ISO tree.

## Post-install (first logon)

Windows Setup copies `$OEM$\$$` to `%WINDIR%`. `FirstLogonCommands` runs `Invoke-PostInstall.ps1` (Windows PowerShell 5.1), which:

1. Applies Game Mode / optional HAGS (`Setup-Gaming.ps1`)
2. Waits up to 10 minutes for winget, then installs the selected launchers from their declared source (`Install-Launchers.ps1`)
3. Runs `Verify-System.ps1`
4. Writes `C:\ProgramData\XboxOS11\postinstall.log` and `postinstall-summary.json`

Every step is failure-tolerant and never disables security, Update, Store, or Xbox components.

## Frontend protocol

**API** — `Invoke-XboxOSBuilderApi.ps1 -Command <catalog|new-profile|validate|review|unattend|save-profile|image-info>` prints exactly one `XBOXOS-RESULT {"ok":…,"command":…,"apiVersion":"xboxos-builder-api-v1","data"|"error":…}` line.

**Build events** — `Invoke-XboxOSBuild.ps1 -EmitEvents` and `Build-ISO.ps1 -EmitEvents` print `XBOXOS-EVENT {"type":…,"utc":…}` lines:

| type | fields |
|------|--------|
| `started` | `profilePath`, `dryRun`, `engineVersion` |
| `validation` | `valid`, `errors[]`, `warnings[]` |
| `log` | `message`, plus context |
| `phase` | `name`, `status` (`started`/`succeeded`/`failed`), `seconds` or `message` |
| `completed` | `dryRun`, `outputDirectory`, `isoPath`, `profileHash` |
| `failed` | `stage`, `message` |

Exit codes for `Invoke-XboxOSBuild.ps1`: `0` success, `1` build failure, `4` invalid profile.
