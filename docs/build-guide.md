# Build Guide

## Required software

1. Windows 10/11 host (x64), Administrator PowerShell
2. PowerShell 7 recommended ([install](https://aka.ms/powershell)); Windows PowerShell 5.1 supported
3. DISM (`C:\Windows\System32\dism.exe`)
4. [Windows ADK](https://learn.microsoft.com/windows-hardware/get-started/adk-install) with **Deployment Tools** (provides `oscdimg.exe`)
5. Official Windows 11 ISO from Microsoft (Pro 25H2 recommended)
6. Optional: extracted INF driver packages in `./drivers`
7. Optional: SSU/LCU `.cab`/`.msu` packages in `./updates`

XboxOS11 never downloads or redistributes Microsoft Windows binaries.

## Quick start

```powershell
# From an elevated PowerShell session
cd 'C:\path\to\XboxOS11'

# Validate tools (does not install anything)
.\scripts\Test-Prerequisites.ps1 -SourceISO 'C:\ISOs\Win11_25H2_English_x64.iso'

# Non-destructive rehearsal
.\scripts\Build-ISO.ps1 `
  -SourceISO 'C:\ISOs\Win11_25H2_English_x64.iso' `
  -Configuration '.\config\build.json' `
  -OutputDirectory 'C:\XboxOS\Output' `
  -DryRun

# Real build
.\scripts\Build-ISO.ps1 `
  -SourceISO 'C:\ISOs\Win11_25H2_English_x64.iso' `
  -Configuration '.\config\build.json' `
  -OutputDirectory 'C:\XboxOS\Output'
```

## Configuration

Edit `config/build.json` for edition, architecture, workspace paths, and phase toggles.

| Manifest | Purpose |
|----------|---------|
| `remove-apps.json` | Provisioned AppX removal candidates |
| `disable-features.json` | Optional feature disable list |
| `drivers.json` | INF driver discovery rules |
| `services.json` | Protected service policy (not applied in M1) |
| `compatibility.json` | Protected packages and Xbox mode notes |

## Update package ordering

Place updates in `./updates`. XboxOS11 orders them as:

1. Servicing Stack Update (SSU)
2. SafeOS / WinRE packages
3. Latest Cumulative Update (LCU)
4. .NET cumulative packages
5. Other supported CAB/MSU packages

Do not apply random packages out of vendor order. Packages must match the image architecture and build family.

## Drivers

Only INF-based packages are integrated offline. Reject full AMD Adrenalin / setup executables. Install chipset and Radeon Adrenalin software normally after Windows Setup.

## Split WIM

If `install.wim` exceeds 4,294,967,295 bytes, `Export-ISO.ps1` splits it into `.swm` parts so the media remains usable on FAT32 USB workflows.

## Logs and reports

Each build writes:

- `artifacts/logs/XboxOS11-<buildId>.log` (structured JSON lines)
- `artifacts/workspace/<buildId>/reports/` inventories, phase reports, validation
- `artifacts/output/BuildReport-<buildId>.json`

On failure, the working WIM is discarded (not committed) and diagnostics remain under the workspace folder.

## Restoring stock Windows

XboxOS11 does not modify your currently running Windows installation during a normal ISO build. To return to stock:

1. Install from an official Microsoft Windows 11 ISO, or
2. Keep a stock ISO and rebuild without the XboxOS11 customization manifests, or
3. Use Windows Recovery / Reset if you installed from an XboxOS11 ISO and want a clean Microsoft image.

## Testing

```powershell
Import-Module Pester -MinimumVersion 5.5.0
Invoke-Pester -Path .\tests
```

Unit tests use mocks/fixtures and do not mount a real Windows image. Full ISO integration tests are opt-in and require ADK + a Microsoft ISO.
