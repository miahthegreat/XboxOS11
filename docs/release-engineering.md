# Release Engineering

## Versioning

- [`VERSION`](../VERSION) is the single source of truth (`MAJOR.MINOR.PATCH`, Semantic Versioning).
- Must match: `modules/XboxOS.Build/XboxOS.Build.psd1` (`ModuleVersion`), `src/Directory.Build.props` and `tests/dotnet/Directory.Build.props` (`<Version>`), and `src/XboxOS11.Builder.App/app.manifest` (`<version>.0`).
- `Test-XboxOSReleaseVersionConsistency` checks them; Pester and the release workflow fail on drift.
- Record user-visible changes in [CHANGELOG.md](../CHANGELOG.md).

## Packaging

```powershell
.\scripts\New-XboxOSRelease.ps1 -OutputDirectory C:\XboxOS\Releases                 # x64 app + toolkit
.\scripts\New-XboxOSRelease.ps1 -Runtime win-x64, win-arm64                          # both architectures
.\scripts\New-XboxOSRelease.ps1 -SkipAppBuild                                        # toolkit only
```

Output in `<OutputDirectory>\<version>\`:

| Artifact | Contents |
|----------|----------|
| `XboxOS11-<version>-win-x64.zip` | `XboxOS11.Builder.exe` (self-contained .NET 10 + Windows App SDK) and `toolkit\` |
| `XboxOS11-<version>-win-arm64.zip` | Same for ARM64 (when requested) |
| `XboxOS11-Toolkit-<version>.zip` | `modules/ scripts/ config/ postinstall/ docs/ README.md LICENSE CHANGELOG.md VERSION` |
| `SHA256SUMS.txt` | `sha256sum -c` compatible |
| `release-manifest.json` | Version, git commit, dirty flag, artifact sizes and hashes |

Guarantees:

- Output must be outside the repository.
- The working tree must be clean (`-AllowDirtyTree` is for local test packages only, and is recorded in the manifest).
- Packaging refuses `.iso .wim .esd .swm .msu .cab .pem .pfx` files. Tests, CI files, automation, fixtures, and build outputs are never included.
- Debug symbols (`.pdb`) are stripped from app packages.

The app finds the toolkit in its `toolkit\` folder (see [m8-winui-builder.md](m8-winui-builder.md)).

## Release workflow

`.github/workflows/release.yml` runs on a pushed tag `vX.Y.Z` (or manual dispatch):

1. Checks the tag matches `VERSION` and all version sources agree.
2. Runs Pester and the .NET tests.
3. Packages x64 and ARM64 with `New-XboxOSRelease.ps1`.
4. Creates a **draft** GitHub Release with the zips, `SHA256SUMS.txt`, and `release-manifest.json`, using the matching CHANGELOG section as notes.

A maintainer reviews and publishes the draft. Nothing is published automatically.

### Cutting a release

```powershell
# 1. Bump VERSION and the mirrored version fields, update CHANGELOG.md, merge to main.
# 2. Tag the merge commit:
git tag v1.0.0
git push origin v1.0.0
# 3. Review the draft release on GitHub, then publish.
```

## Verifying a download

```powershell
Get-FileHash .\XboxOS11-1.0.0-win-x64.zip -Algorithm SHA256
# compare with SHA256SUMS.txt from the same release
```

Release archives contain no Microsoft Windows binaries. Users bring their own official Windows 11 ISO.
