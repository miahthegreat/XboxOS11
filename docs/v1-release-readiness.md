# XboxOS11 1.0 Release Readiness

What is implemented, what is verified and how, and what still needs a human on real hardware before tagging `v1.0.0`.

## Implemented

| Capability | Where |
|------------|-------|
| Native Builder app (WinUI 3, x64/ARM64, self-contained) | `src/XboxOS11.Builder.App`, [m8](m8-winui-builder.md) |
| Profiles, presets, strict validation, component review, unattend | `modules/XboxOS.Build/BuilderProfile.ps1`, [m7](m7-builder-backend-contracts.md) |
| Profile-driven ISO build with progress events | `scripts/Invoke-XboxOSBuild.ps1` → `scripts/Build-ISO.ps1` |
| Reversible gaming optimizations, X3D-aware verification | `postinstall/`, [m9](m9-gaming-performance.md) |
| Build record + recovery on the installed PC | `Restore-XboxOS11Components.ps1`, [recovery](recovery.md) |
| Release packaging, checksums, manifest, draft-release workflow | `scripts/New-XboxOSRelease.ps1`, [release engineering](release-engineering.md) |

## Verified automatically (CI on every PR)

- **Pester** (300+ tests): manifests and safety, servicing plan/execution simulation, preflight, dependency evidence, lab and host-discovery contracts, builder profiles/validation/unattend/overlay, end-to-end **dry-run** builds with events, sandboxed-registry apply/restore of every gaming optimization, recovery script behavior, version consistency, and toolkit packaging contents.
- **.NET**: 44 xUnit tests, including live contract tests where the real PowerShell backend accepts profiles produced by the app, renders unattend, and completes a dry-run build.
- **Build**: the WinUI 3 app compiles for x64, and PSScriptAnalyzer reports 0 errors.

## Verified manually during development

- The app launched from the repository and from an **extracted release zip** (toolkit discovered beside the exe). It loaded presets, populated the component review, surfaced validation errors, and completed a **dry-run build through the GUI**. Driven via UI Automation, with screenshots reviewed.
- `Set-GamingOptimizations.ps1` apply/restore under **Windows PowerShell 5.1**, in a sandboxed registry key.
- Release packaging produced an ~90 MB x64 zip; the self-contained app starts from it.

## Requires a human before tagging v1.0.0

These are outward-facing or need real hardware and media, so they were deliberately not done automatically:

1. **Real ISO build** on an elevated machine with Windows ADK and an official Windows 11 ISO (`Invoke-XboxOSBuild.ps1` without `-DryRun`, or the app with *Dry run* unchecked). Check the build report and `Inventory-After.json`.
2. **Install test** of that ISO on the reference hardware or a VM:
   - Setup skips the language/EULA/privacy pages as configured, and still asks for disk and account.
   - First sign-in runs post-install. Check `C:\ProgramData\XboxOS11\postinstall-summary.json`.
   - `Verify-System.ps1` passes after installing AMD drivers. Store, Xbox app, Game Pass sign-in, and an anti-cheat title work.
   - Settings › Gaming › Xbox mode works. For `handheld-xbox-mode`, Xbox mode opens at sign-in.
   - `Restore-XboxOS11Components.ps1 -All` re-enables features and restores gaming settings.
3. **Merge** the milestone PR stack (#23 → #24 → #25 → #26 → M10) after review. Repository policy requires human approval for merges.
4. **Tag and publish**: push tag `v1.0.0`, review the draft release created by the workflow, then publish.
5. Optional, separate: M6E **Gate B** (one operator-authorized live read-only host discovery run). It isn't required for the Builder product.

## Known limitations

- Validated against Windows 11 Pro. Other editions are allowed with a warning.
- A Windows feature update can reinstall some removed inbox apps. Rebuild from the newer ISO with the same profile.
- `StartupToGamingHome` is documented by Microsoft for handhelds. Desktop behavior must be confirmed per device.
- The app isn't code-signed. Windows SmartScreen may warn on first launch until signing is added.
