# Milestone 8 — Native WinUI 3 XboxOS11 Builder

A Windows App SDK (WinUI 3) desktop app over the Milestone 7 backend. It covers the whole user workflow: select an ISO → choose a preset or Custom → review components → drivers and setup → validate → build → save/reuse the profile.

| Item | Value |
|------|-------|
| App | `src/XboxOS11.Builder.App` (`XboxOS11.Builder.exe`, unpackaged, self-contained, x64/ARM64) |
| Core library | `src/XboxOS11.Builder.Core` (`net10.0`, no UI dependencies) |
| Tests | `tests/dotnet/XboxOS11.Builder.Core.Tests` (xUnit, including live PowerShell contract tests) |
| Solution | `XboxOS11.slnx` |
| Version | `0.8.0` (`src/Directory.Build.props`) |
| Frameworks | .NET 10, Windows App SDK 2.4, CommunityToolkit.Mvvm 8.4 |

## Architecture

```
XboxOS11.Builder.exe (WinUI 3, MVVM)
  └─ MainViewModel ── ProfileEditor (rules) ── BuildProfile (schema mirror)
        └─ BuilderBackend ── IProcessRunner ── pwsh.exe / powershell.exe
              ├─ scripts/Invoke-XboxOSBuilderApi.ps1  → one XBOXOS-RESULT JSON line
              └─ scripts/Invoke-XboxOSBuild.ps1       → XBOXOS-EVENT progress lines
```

- The app holds no build logic. Validation, protection rules, unattend generation, and servicing all stay in the PowerShell toolkit, so the CLI and GUI cannot drift apart.
- `BuildProfile` mirrors `xboxos-build-profile-v1` exactly. Every key is serialized, including `imageIndex: null`, because the backend rejects missing or unknown keys.
- `ProfileEditor` enforces UI-side rules: protected components can't be selected, turning off unattend also turns off post-install and StartupToGamingHome, preset application keeps the ISO/name/output, and any edit switches the preset to `custom`.
- Each API call writes the current profile to a private scratch file (`%TEMP%\XboxOS11.Builder`) and deletes it afterwards. No profile JSON goes on a command line.
- Process arguments are fixed (`-NoProfile -NonInteractive -ExecutionPolicy Bypass -File <toolkit script> …`). There is no shell string concatenation.

### Toolkit and PowerShell discovery

`ToolkitLocator` searches, in order:

1. a saved override, then the `XBOXOS11_TOOLKIT` environment variable
2. a `toolkit` folder next to the executable (release layout)
3. each ancestor folder of the executable (development layout inside the repository)

PowerShell 7 (`pwsh.exe` on PATH or in `%ProgramFiles%\PowerShell\7`) is preferred. Inbox Windows PowerShell 5.1 is the fallback, and the toolkit loads under both.

## Elevation

The app runs **as invoker**. You can configure, validate, preview the unattend file, save profiles, and run a dry run without administrator rights. **Read editions** (read-only ISO mount) and a **real build** (DISM) need elevation, and the app offers *Restart as administrator*. Windows App SDK pickers (`Microsoft.Windows.Storage.Pickers`) work both elevated and non-elevated.

## Build progress and cancellation

`BuilderBackend.RunBuildAsync` streams stdout and stderr. `XBOXOS-EVENT` lines become phase updates (started/succeeded/failed), and everything else goes to the build log (capped at 3,000 lines). **Cancel** kills the PowerShell process tree. `Build-ISO.ps1` never commits on failure, and the next build's mount cleanup discards any leftover mount. Closing the window during a build cancels it.

## Profiles and settings

- **Save profile…** validates through the backend (`save-profile`) before writing JSON.
- **Open profile…** loads any `xboxos-build-profile-v1` file and re-runs the component review.
- Recent profiles (max 8) and preferences live in `%LOCALAPPDATA%\XboxOS11\settings.json`. Nothing secret is stored.

## Building from source

```powershell
dotnet test tests/dotnet/XboxOS11.Builder.Core.Tests -c Release
dotnet build src/XboxOS11.Builder.App -c Release -p:Platform=x64
.\src\XboxOS11.Builder.App\bin\x64\Release\net10.0-windows10.0.22621.0\win-x64\XboxOS11.Builder.exe
```

Running from the build output finds the toolkit by walking up to the repository root.

## Verification at milestone close

- .NET: 44 tests pass, including live contract tests where the real PowerShell backend accepts profiles produced by the .NET client, flags protected components, generates unattend XML, and completes a dry-run build with phase events.
- GUI: launched and exercised via UI Automation. The toolkit loaded, the preset/component review was populated from the backend, validation surfaced the missing ISO, and a full dry-run build completed with every phase reported.
- CI: a new `builder` job runs the .NET tests and builds the WinUI app on `windows-latest`.
- No real ISO build, DISM servicing, or elevated operation was performed during development.
