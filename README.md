# XboxOS11

Open-source, reproducible **Windows 11 image customization framework** that builds a stripped-down, gaming-focused installation ISO optimized for **Xbox Full Screen Experience** (Xbox mode).

XboxOS11 is tooling and manifests only. It does **not** redistribute Microsoft Windows binaries, bypass activation, patch undocumented system binaries, or silently install untrusted software.

## Purpose

Produce a deterministic Windows 11 Pro installation image (release label taken only from verified image metadata — never assumed from ISO filenames such as `26300.9457`) that:

- Removes selected consumer/promotional AppX packages
- Disables a small set of optional legacy features (payloads retained by default)
- Optionally injects INF drivers and Microsoft update packages
- Preserves Store, Xbox, Gaming Services, Defender, Update, DirectX, and related gaming dependencies
- Emits a UEFI-bootable ISO via Microsoft Oscdimg

Target reference hardware: **AMD Ryzen 7 7800X3D** + **AMD Radeon RX 9070 XT** (x64, UEFI/GPT).

## Supported operating systems

| Role | Support |
|------|---------|
| Build host | Windows 10/11 x64 |
| Orchestration | PowerShell 7 recommended; Windows PowerShell 5.1 supported |
| Target image | Windows 11 (configurable; Pro 25H2 initially) |
| Boot | UEFI + GPT |

## Required tools

- Administrator PowerShell
- DISM (inbox)
- [Windows ADK](https://learn.microsoft.com/windows-hardware/get-started/adk-install) **Deployment Tools** (`oscdimg.exe`)
- Official Windows 11 ISO from Microsoft
- Optional: Pester 5+ for tests, PSScriptAnalyzer for static analysis

Install ADK yourself. Scripts never install dependencies without permission.

## Installation

```powershell
git clone https://github.com/miahthegreat/XboxOS11.git
cd XboxOS11
```

Install ADK Deployment Tools, then:

```powershell
.\scripts\Test-Prerequisites.ps1 -SourceISO 'C:\ISOs\Win11_25H2_English_x64.iso'
```

## Configuration examples

Edition / architecture (`config/build.json`):

```json
"target": {
  "windowsVersion": "11",
  "release": "25H2",
  "edition": "Windows 11 Pro",
  "architecture": "amd64",
  "imageNamePattern": "*Pro*"
}
```

App removal candidates live in `config/remove-apps.json`. Protected identities live in `config/compatibility.json` and cannot be removed through normal configuration.

## Build commands

Dry-run (no source/WIM/mount/system mutation):

```powershell
.\scripts\Build-ISO.ps1 `
  -SourceISO 'C:\ISOs\Win11_25H2_English_x64.iso' `
  -Configuration '.\config\build.json' `
  -OutputDirectory 'C:\XboxOS\Output' `
  -DryRun
```

Real ISO build:

```powershell
.\scripts\Build-ISO.ps1 `
  -SourceISO 'C:\ISOs\Win11_25H2_English_x64.iso' `
  -Configuration '.\config\build.json' `
  -OutputDirectory 'C:\XboxOS\Output'
```

## Safety considerations

- Builds use an isolated external workspace under `C:\XboxOS\Work` (not the Git repo, not OneDrive).
- Logs go to `C:\XboxOS\Logs`; ISO output to `C:\XboxOS\Output`.
- Failed modification phases **discard** mounted image changes (no commit-on-failure).
- Dry-run does not fabricate empty inventories; inventory-dependent actions are `NotEvaluated` until a real mount exists.
- Ambiguous AppX matches are rejected and fail the phase.
- Store / Xbox / gaming / security dependencies are protected.
- TPM, Secure Boot, Defender, and VBS are not disabled for benchmarks.
- A smaller ISO does **not** mean better gaming performance.
- AMD Adrenalin must be installed after Windows Setup; it is not injected as a full offline installer.

## Why components are protected

See [docs/compatibility.md](docs/compatibility.md). In short: Store, Xbox identity, Gaming Services, Game Bar, Update, Defender, DirectX, Media Foundation, WebView2, and servicing/crypto/networking pieces are required for a working Xbox-mode-capable gaming PC and for anti-cheat compatibility.

## Testing

```powershell
Import-Module Pester -MinimumVersion 5.5.0
Invoke-Pester -Path .\tests
```

GitHub Actions (`.github/workflows/validate.yml`) validates JSON, repository structure, PSScriptAnalyzer, and unit tests. CI never downloads or publishes Windows ISOs.

## Post-install scripts (Milestone 1 stubs)

| Script | Purpose |
|--------|---------|
| `postinstall/Setup-Gaming.ps1` | Idempotent Game Mode helpers |
| `postinstall/Setup-XboxMode.ps1` | Conservative Xbox mode docs + optional unattend snippet |
| `postinstall/Install-Launchers.ps1` | Opt-in winget launcher installs |
| `postinstall/Verify-System.ps1` | Dependency presence report |

These are **not** executed automatically during Windows Setup in M1.

## Restoring stock Windows

XboxOS11 customization applies to the ISO you build/install. To return to stock Windows, install from an official Microsoft ISO or use Windows Recovery/Reset with Microsoft media. Keep your original ISO.

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md).

## Known limitations

- A real ISO has only been attempted if you run a non-dry-run build with ADK + Microsoft media on your machine.
- Xbox mode automatic startup on **desktop** PCs is not claimed; use Settings / Game Bar until validated (see compatibility docs).
- `StartupToGamingHome` unattend support is documented by Microsoft but treated as opt-in OEM configuration pending hardware validation.
- Service tuning and unattended Setup are deferred to later milestones.
- This development environment may lack Windows ADK; unit tests still cover manifests, safety, dry-run, and helpers.

## Documentation

- [Architecture](docs/architecture.md)
- [Build guide](docs/build-guide.md)
- [Compatibility](docs/compatibility.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Milestones](docs/milestones.md)

## Roadmap

**M1** Image build foundation → **M2** Unattended install → **M3** Xbox mode integration → **M4** Gaming performance → **M5** Recovery → **M6** Release engineering.

## License

MIT for XboxOS11 original code. Windows remains Microsoft proprietary; bring your own licensed ISO.
