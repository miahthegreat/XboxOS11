# Troubleshooting

## Prerequisite failures

### Oscdimg / ADK not found

Install Windows ADK and select **Deployment Tools**:
https://learn.microsoft.com/windows-hardware/get-started/adk-install

XboxOS11 searches registry `KitsRoot10` and well-known `Windows Kits\10\Assessment and Deployment Kit` paths.

### DISM not found

Expected at `%SystemRoot%\System32\dism.exe`. If missing, repair Windows system components.

### Not running as Administrator

Re-open PowerShell with **Run as administrator**. Offline image servicing requires elevation.

### Insufficient disk space

A full customize+ISO flow commonly needs tens of GB. Default minimum is configured in `config/build.json` (`workspace.minimumFreeGb`).

## Import / edition errors

### Requested edition unavailable

Run DISM manually to list indexes:

```powershell
dism /Get-ImageInfo /ImageFile:D:\sources\install.wim
```

Update `target.edition` / `target.imageNamePattern` in `config/build.json`.

### ISO mount failed

Ensure the ISO is not already mounted, not corrupt, and accessible locally (not a broken OneDrive placeholder). Official Microsoft ISOs only.

## Removal / feature errors

### Ambiguous package match

Patterns must resolve to a single package when `rejectAmbiguousPackageMatches` is true. Narrow the pattern in `remove-apps.json` after reviewing `Inventory-Before.json`.

### Protected package skipped

Expected. Store/Xbox/framework packages in `compatibility.json` cannot be removed through the normal pipeline.

### Feature absent

Optional features vary by edition/image. Absent features are logged and skipped.

## Driver / update errors

### Driver rejected

Executables and Adrenalin installers are rejected. Use extracted INF packages only.

### Update failed

Confirm package architecture/build family. Apply SSU before LCU. Inspect DISM log under `%WINDIR%\Logs\DISM\dism.log` and the XboxOS11 build log.

## ISO export

### oscdimg exit non-zero

Verify `boot\etfsboot.com` and `efi\microsoft\boot\efisys.bin` exist in the copied source tree. Paths with spaces are supported when the script builds boot data correctly; check `ExportIso.json`.

### WIM too large for FAT32 USB

XboxOS11 splits to `.swm` automatically above the configured threshold. Use a tool that understands split WIMs when creating USB media, or keep the ISO and flash with a tool that preserves UDF.

## Interrupted builds

`Build-ISO.ps1` uses `try/finally` to discard mounted images after failures and to dismount source ISOs. If a mount is stuck:

```powershell
dism /Cleanup-Mountpoints
dism /Get-MountedImageInfo
```

Then remove the orphaned `artifacts/workspace/<buildId>/mount` folder if empty/unlocked.

## Xbox mode not appearing after install

1. Confirm build ≥ 24H2
2. Update Xbox app + Game Bar from Store
3. Use Settings → Gaming → Xbox mode
4. Try `Win+F11`
5. Do not expect handheld-only startup policies to apply automatically on desktop

## Builder app

### "The XboxOS11 toolkit could not be loaded"

The app looks for `toolkit\` next to `XboxOS11.Builder.exe`, then the `XBOXOS11_TOOLKIT` environment variable, then parent folders (when run from the repository). Re-extract the release zip so `toolkit\` sits beside the exe.

### "PowerShell was not found"

Install PowerShell 7 (`winget install Microsoft.PowerShell`), or make sure Windows PowerShell (`%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`) hasn't been removed.

### "Read editions" or "Start" is disabled

Both need administrator rights for a real build. Use **Restart as administrator** in the banner. Dry runs work without elevation.

### App and toolkit versions differ

The status bar shows both. Use the `toolkit\` folder that came in the same release zip as the app.

### SmartScreen warning on first launch

Release builds aren't code-signed yet. Check the download against `SHA256SUMS.txt`, then choose **More info › Run anyway**.

### Validation errors

Each error names the profile setting to fix (for example `output.directory must not be in a cloud-synchronized folder`). Protected components can't be selected, and unsupported settings (TPM/Secure Boot bypasses, Defender changes, product keys) can't be expressed. That's by design.

## After installation

- **First sign-in setup didn't run**: check `C:\ProgramData\XboxOS11\postinstall.log`. Run `%WINDIR%\Setup\Scripts\XboxOS11\Invoke-PostInstall.ps1` manually if needed.
- **Launchers didn't install**: winget (App Installer) can take a few minutes to register after first sign-in. Run `Install-Launchers.ps1` from the same folder later.
- **Undo changes**: see [recovery.md](recovery.md).
