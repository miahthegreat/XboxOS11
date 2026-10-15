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
| Builder app | Windows 10 19041+ / Windows 11, x64 or ARM64 (self-contained .NET 10 + Windows App SDK) |
| Target image | Windows 11 Pro (release from verified metadata; baseline capture 26H2 / 26300.9457) |
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

## XboxOS11 Builder app

`XboxOS11.Builder.exe` is a native WinUI 3 app for the whole workflow: pick an ISO, choose a preset, review components, set drivers and setup options, validate, and build, with live progress. It runs as a normal user for configuring and dry runs, and offers *Restart as administrator* for reading ISO editions and real builds.

```powershell
dotnet build src/XboxOS11.Builder.App -c Release -p:Platform=x64
.\src\XboxOS11.Builder.App\bin\x64\Release\net10.0-windows10.0.22621.0\win-x64\XboxOS11.Builder.exe
```

See [docs/m8-winui-builder.md](docs/m8-winui-builder.md).

## Builder profiles (recommended)

Create a reusable profile from a preset, then build from it:

```powershell
Import-Module .\modules\XboxOS.Build\XboxOS.Build.psd1
$p = New-XboxOSBuildProfile -Name 'My Rig' -PresetId gaming-balanced -SourceIso 'C:\ISOs\Win11_x64.iso'
Export-XboxOSBuildProfile -BuildProfile $p -Path 'C:\XboxOS\Profiles\my-rig.json'

.\scripts\Invoke-XboxOSBuild.ps1 -ProfilePath 'C:\XboxOS\Profiles\my-rig.json' -DryRun   # validate + plan
.\scripts\Invoke-XboxOSBuild.ps1 -ProfilePath 'C:\XboxOS\Profiles\my-rig.json'           # real build (elevated)
```

Presets: `gaming-balanced` (recommended), `gaming-lean`, `handheld-xbox-mode`, `stock-safe`. Profiles cannot express TPM/Secure Boot/network-requirement bypasses, security feature removal, product keys, or automatic disk wiping. See [docs/m7-builder-backend-contracts.md](docs/m7-builder-backend-contracts.md).

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

## Post-install scripts

| Script | Purpose |
|--------|---------|
| `postinstall/Set-GamingOptimizations.ps1` | Reversible gaming optimizations (`-List`, `-UseDefaults`, `-Restore`) |
| `postinstall/Setup-Gaming.ps1` | Game Mode / HAGS compatibility wrapper |
| `postinstall/Invoke-PostInstall.ps1` | First-logon entrypoint staged by the Builder |
| `postinstall/Setup-XboxMode.ps1` | Conservative Xbox mode docs + optional unattend snippet |
| `postinstall/Install-Launchers.ps1` | Opt-in winget launcher installs |
| `postinstall/Verify-System.ps1` | Dependency presence report |

When a Builder profile enables first sign-in setup, the Builder stages these scripts on the ISO and `Invoke-PostInstall.ps1` runs once at first logon. Otherwise run them manually. Gaming optimizations record original values; undo with `Set-GamingOptimizations.ps1 -Restore`.

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
- [M1 read-only compatibility baseline](docs/m1-compatibility-baseline.md)
- [Compatibility matrix (26300.9457 / 26H2)](docs/XboxOS11-compatibility-matrix-26300.9457.md)
- [M2 servicing plan contracts](docs/m2-servicing-plan-contracts.md)
- [M2 canonical plan hash](docs/m2-canonical-plan-hash.md)
- [M2 operation ordering and recovery](docs/m2-operation-ordering-and-recovery.md)
- [M2 completion baseline](docs/m2-completion-baseline.md)
- [M3 execution safety contracts](docs/m3-execution-safety-contracts.md)
- [M3 transaction state machine](docs/m3-transaction-state-machine.md)
- [M3 unresolved risks](docs/m3-unresolved-risks.md)
- [M3 completion baseline](docs/m3-completion-baseline.md)
- [M4 disposable-image preflight contracts](docs/m4-disposable-image-preflight-contracts.md)
- [M4 unresolved risks](docs/m4-unresolved-risks.md)
- [M4 completion baseline](docs/m4-completion-baseline.md)
- [M5 dependency evidence contracts](docs/m5-dependency-evidence-contracts.md)
- [M5 future modification test strategy](docs/m5-future-modification-test-strategy.md)
- [M5 unresolved risks](docs/m5-unresolved-risks.md)
- [M5 completion baseline](docs/m5-completion-baseline.md)
- [M6 disposable-image experiment design](docs/m6-disposable-image-experiment-design.md)
- [M6A experiment planning contracts](docs/m6a-experiment-planning-contracts.md)
- [M6A authorization boundaries](docs/m6a-authorization-boundaries.md)
- [M6A functional validation matrix](docs/m6a-functional-validation-matrix.md)
- [M6A unresolved risks](docs/m6a-unresolved-risks.md)
- [M6B lab infrastructure contracts](docs/m6b-lab-infrastructure-contracts.md)
- [M6B completion baseline](docs/m6b-completion-baseline.md)
- [M6C real-host lab discovery design](docs/m6c-real-host-lab-discovery-design.md)
- [M6C host discovery contracts](docs/m6c-host-discovery-contracts.md)
- [M6C completion baseline](docs/m6c-completion-baseline.md)
- [M6D authorized read-only host inspection design](docs/m6d-authorized-readonly-host-inspection-design.md)
- [M6D read-only host adapter](docs/m6d-readonly-host-adapter.md)
- [M6D operator authorization](docs/m6d-operator-authorization.md)
- [M6D isolation evidence](docs/m6d-isolation-evidence.md)
- [M6D operational runbook](docs/m6d-operational-runbook.md)
- [M6D unresolved risks](docs/m6d-unresolved-risks.md)
- [M6D completion baseline](docs/m6d-completion-baseline.md)
- [M6E controlled live discovery design](docs/m6e-controlled-live-discovery-design.md)
- [M6E controlled live discovery contracts](docs/m6e-controlled-live-discovery-contracts.md)
- [M7 builder backend contracts](docs/m7-builder-backend-contracts.md)
- [M8 WinUI 3 Builder](docs/m8-winui-builder.md)
- [M9 gaming performance and Xbox mode](docs/m9-gaming-performance.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Milestones](docs/milestones.md)

## Roadmap

**M1** Image build foundation → **M2** Servicing plan engine → **M3** Execution safety (simulation) → **M4** Disposable read-only preflight → **M5** Dependency evidence and servicing readiness → **M6A** Experiment planning / authorization simulation → **M6B** Isolated lab infrastructure (simulation) → **M6C** mocked host discovery → **M6D** authorized host-discovery contracts (live inactive) → **M6E** controlled live read-only discovery (Gate A) → **M7** Builder backend → **M8** native WinUI 3 Builder → **M9** gaming performance / Xbox mode → **M10** recovery and release engineering.

**Product:** the native WinUI 3 XboxOS11 Builder (M8) drives the M7 backend: select a supported Windows 11 ISO → choose a gaming preset or Custom → review dependency-aware component changes → configure drivers and installation options → validate the proposed build → produce a customized bootable ISO → save and reuse the build configuration. User-facing builder contracts stay separate from internal lab authorization.

M6D acceptance is **not** permission to inspect a production host, provision VMs, or modify Windows images.

## License

MIT for XboxOS11 original code. Windows remains Microsoft proprietary; bring your own licensed ISO.
