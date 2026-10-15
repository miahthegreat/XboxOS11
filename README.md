# XboxOS11

Build a clean, **gaming-focused Windows 11 installation ISO** from your own official Microsoft ISO, ready for **Xbox mode** (Xbox Full Screen Experience). It removes promotional apps and legacy features, integrates drivers, answers Setup's questions, and applies reversible gaming optimizations at first sign-in, without touching anything games, the Store, Xbox, anti-cheat, or Windows security depend on.

XboxOS11 is tooling only. It does **not** redistribute Windows, bypass activation, patch system binaries, or silently install untrusted software. Hardware-requirement checks are only skipped if you explicitly opt in for an unsupported PC.

## Quick start

1. **Download** `XboxOS11-<version>-win-x64.zip` from [Releases](https://github.com/miahthegreat/XboxOS11/releases) and check it against `SHA256SUMS.txt`.
2. **Install** [Windows ADK Deployment Tools](https://learn.microsoft.com/windows-hardware/get-started/adk-install) (for `oscdimg.exe`), and get an official Windows 11 ISO from Microsoft.
3. **Extract** the zip and run `XboxOS11.Builder.exe`.
4. Follow the five steps: **Source** → **Preset** → **Components** → **Drivers & setup** → **Validate & build**. Try a dry run first. A real build needs *Restart as administrator*, about 40 GB free, and 20–60 minutes.
5. Write the ISO to a USB drive (for example with the Media Creation Tool's USB option or Rufus) and install.

Save your profile and reuse it whenever Microsoft ships a new ISO.

## What it changes

| Area | Default (`gaming-balanced` preset) | Never touched |
|------|-------------------------------------|---------------|
| Apps | Removes Clipchamp, consumer Copilot, consumer Teams, News, Weather, Solitaire, consumer Outlook | Store, Xbox app/identity, Gaming Services, Game Bar, Edge/WebView2, Defender UI |
| Features | Disables XPS Viewer/Services, SMB 1.0, Work Folders (payloads kept) | Hyper-V/WSL/VM Platform, .NET, media playback |
| Setup | Language, time zone, EULA, minimal privacy choices; optional local account | Disk selection, product keys; TPM/Secure Boot checks unless you explicitly opt in for unsupported hardware |
| First sign-in | Game Mode, optimizations for windowed games, background recording off, Steam | Power plan (X3D needs Balanced), Game Bar, VBS/memory integrity, Defender, Windows Update |

Other presets: `gaming-lean`, **`gaming-tiny`** (Tiny11-class: removes every non-gaming inbox app and optional capability, blocks sponsored apps and ads, skips OneDrive for new accounts, and shrinks the image to `install.esd`, while keeping Store, Xbox, Edge/WebView2, Defender, Windows Update, and recovery), `handheld-xbox-mode` (opens Xbox mode at startup), and `stock-safe` (minimal changes). Everything is adjustable on the **Components** and **Drivers & setup** pages. See [how Tiny compares with Tiny11](docs/m11-lean-image.md).

Every change is recorded on the installed PC and can be undone. See [Recovery](docs/recovery.md).

## Requirements

| Role | Support |
|------|---------|
| Build PC | Windows 10 (19041+) or 11, x64 or ARM64, administrator rights for real builds |
| Tools | Windows ADK Deployment Tools, DISM (inbox), PowerShell 7 recommended (Windows PowerShell 5.1 works) |
| Source | Official Windows 11 ISO (validated with Windows 11 Pro, 24H2+) |
| Target | UEFI + GPT. Reference hardware: Ryzen 7 7800X3D + Radeon RX 9070 XT |

Install AMD chipset and Radeon Adrenalin drivers after Windows Setup. Driver suites are never injected into the image.

## Command line

The app is a front end over the PowerShell toolkit, which you can also use directly:

```powershell
Import-Module .\modules\XboxOS.Build\XboxOS.Build.psd1
$p = New-XboxOSBuildProfile -Name 'My Rig' -PresetId gaming-balanced -SourceIso 'C:\ISOs\Win11_x64.iso'
Export-XboxOSBuildProfile -BuildProfile $p -Path 'C:\XboxOS\Profiles\my-rig.json'

.\scripts\Invoke-XboxOSBuild.ps1 -ProfilePath 'C:\XboxOS\Profiles\my-rig.json' -DryRun   # validate + plan
.\scripts\Invoke-XboxOSBuild.ps1 -ProfilePath 'C:\XboxOS\Profiles\my-rig.json'           # real build (elevated)
```

Lower-level entry points: `scripts/Build-ISO.ps1` (manifest-driven build), `scripts/Test-Prerequisites.ps1`, and `scripts/Invoke-XboxOSBuilderApi.ps1` (JSON API used by the app).

## Safety

- Builds work on a copy in `C:\XboxOS\Work`, never in the repository or OneDrive. Logs go to `C:\XboxOS\Logs`.
- A failed build **discards** the mounted image. Nothing is committed on failure.
- Removal candidates must match the image inventory exactly. Ambiguous matches fail the build.
- Profiles are strictly validated. They cannot express security changes, product keys, disk wiping, or removal of Store/Xbox/Update/recovery components. The only requirement bypass is the explicit, warned `allowUnsupportedHardware` opt-in.
- Media overlays may only add `autounattend.xml` and `sources\$OEM$` files. Boot and image files are rejected.
- A smaller ISO doesn't mean better gaming performance. XboxOS11 changes only documented, measurable settings.

Background: [compatibility](docs/compatibility.md) and [M7 builder contracts](docs/m7-builder-backend-contracts.md).

## Development

```powershell
Invoke-Pester -Path .\tests                                             # PowerShell (Pester 5+)
dotnet test tests\dotnet\XboxOS11.Builder.Core.Tests -c Release          # .NET (includes backend contract tests)
dotnet build src\XboxOS11.Builder.App -c Release -p:Platform=x64        # WinUI 3 app (runs from the repo)
.\scripts\New-XboxOSRelease.ps1 -OutputDirectory C:\XboxOS\Releases     # release packages
```

CI (`.github/workflows/validate.yml`) runs JSON/structure checks, PSScriptAnalyzer, Pester, the .NET tests, and the app build. Tagged releases are packaged as **draft** GitHub Releases by `.github/workflows/release.yml`. CI never downloads or publishes Windows media. See [release engineering](docs/release-engineering.md).

## Documentation

**Using XboxOS11:** [Recovery and maintenance](docs/recovery.md) · [Troubleshooting](docs/troubleshooting.md) · [Gaming performance and Xbox mode](docs/m9-gaming-performance.md) · [Compatibility](docs/compatibility.md) · [Build guide](docs/build-guide.md) · [Changelog](CHANGELOG.md)

**Architecture and contracts:** [Architecture](docs/architecture.md) · [Lean image / Tiny11 comparison](docs/m11-lean-image.md) · [Builder app](docs/m8-winui-builder.md) · [Builder backend](docs/m7-builder-backend-contracts.md) · [Release engineering](docs/release-engineering.md) · [1.0 release readiness](docs/v1-release-readiness.md) · [Milestones](docs/milestones.md)

**Engineering history (M1–M6E):** servicing plan ([M2](docs/m2-completion-baseline.md)), execution safety ([M3](docs/m3-completion-baseline.md)), read-only preflight ([M4](docs/m4-completion-baseline.md)), dependency evidence ([M5](docs/m5-completion-baseline.md)), experiment planning ([M6A](docs/m6a-completion-baseline.md)), lab infrastructure ([M6B](docs/m6b-completion-baseline.md)), host discovery ([M6C](docs/m6c-completion-baseline.md), [M6D](docs/m6d-completion-baseline.md), [M6E](docs/m6e-controlled-live-discovery-contracts.md)), and the [26300.9457 compatibility matrix](docs/XboxOS11-compatibility-matrix-26300.9457.md).

## License

MIT for XboxOS11 code. Windows is Microsoft proprietary software; bring your own licensed ISO.
