# Recovery and Maintenance

XboxOS11 changes only what your build profile lists, and each change can be undone on the installed PC.

## What every XboxOS11 image carries

Windows Setup copies `sources\$OEM$\$$` from the ISO into `%WINDIR%`. Every Builder image includes `%WINDIR%\Setup\Scripts\XboxOS11\`:

| File | Purpose |
|------|---------|
| `build-record.json` | Exactly what the build changed: removed apps, disabled features, optimizations, launchers, profile hash, toolkit version |
| `Restore-XboxOS11Components.ps1` | Reviews and undoes those changes |
| `Set-GamingOptimizations.ps1` + `gaming-tweaks.json` | Applies/restores gaming settings |
| `Verify-System.ps1` | Read-only health check (Store, Xbox, Gaming Services, Game Bar, GPU driver, X3D power plan) |

When first sign-in setup is enabled, the image also includes `Invoke-PostInstall.ps1`, `Setup-Gaming.ps1`, `Install-Launchers.ps1`, and `postinstall.json`. Logs go to `C:\ProgramData\XboxOS11\` (`postinstall.log`, `postinstall-summary.json`, `gaming-state.json`).

## Undo XboxOS11 changes

Open **Terminal (Admin)**:

```powershell
cd $env:WINDIR\Setup\Scripts\XboxOS11
.\Restore-XboxOS11Components.ps1                       # show what was changed
.\Restore-XboxOS11Components.ps1 -All -WhatIf          # preview everything
.\Restore-XboxOS11Components.ps1 -Features             # re-enable disabled optional features
.\Restore-XboxOS11Components.ps1 -Capabilities         # re-add removed optional capabilities (internet)
.\Restore-XboxOS11Components.ps1 -GamingSettings       # restore original gaming settings
.\Restore-XboxOS11Components.ps1 -Apps -OpenStore      # open Store pages for removed apps
```

- **Features**: payloads are kept (`removePayload: false`), so features re-enable without installation media. Some need a restart.
- **Gaming settings**: each value returns to exactly what it was before XboxOS11 changed it. Values that didn't exist are deleted.
- **Capabilities** (lean builds): re-added from Windows Update with `Add-WindowsCapability`. You can also use Settings › System › Optional features.
- **Defaults for new accounts** (lean builds): sponsored apps, tips, taskbar buttons, and the Edge first-run policy are listed in the summary with the Settings page that controls each one. To get OneDrive: `winget install Microsoft.OneDrive`.
- **Apps**: removed apps are consumer/promotional apps (Clipchamp, News, Weather, …). Reinstall any of them from the Microsoft Store. Nothing is installed silently.

Gaming settings alone: `.\Set-GamingOptimizations.ps1 -Restore`.

## Return to stock Windows

- **Settings › System › Recovery › Reset this PC** reinstalls Windows from the local image. It keeps XboxOS11's app removals, because they're part of the installed image.
- For completely stock Windows, reinstall from official Microsoft media (Media Creation Tool or an official ISO). Keep your original ISO.

## Windows Update and servicing

- Windows Update, Microsoft Defender, the Store, and the Xbox/Gaming Services stack are never removed or disabled, so cumulative and feature updates install normally.
- A feature update (for example a new Windows 11 annual release) may reinstall some removed inbox apps. Rebuild with the latest ISO and the same saved profile, or remove them again from Settings › Apps.
- Rebuilding with an updated ISO: open your saved profile in the Builder, select the new ISO, validate, build. The profile hash in `build-record.json` identifies the configuration.

## Health check after install or updates

```powershell
& "$env:WINDIR\Setup\Scripts\XboxOS11\Verify-System.ps1"
```

Address any `[!!]` lines. Typical ones: install AMD chipset and Adrenalin drivers, let the Store update Gaming Services, keep Game Bar on.

## Troubleshooting the build itself

See [troubleshooting.md](troubleshooting.md). Failed builds never commit changes: the mounted image is discarded and diagnostics stay under `C:\XboxOS\Work\<build-id>\reports` and `C:\XboxOS\Logs`.
