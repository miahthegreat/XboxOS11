# Milestone 4 — Implementation Notes

## Layout

| Path | Role |
|------|------|
| `modules/XboxOS.Build/DisposableImagePreflight.ps1` | Read-only adapter, workspace, preflight, approval-auth helpers |
| `scripts/Test-DisposableImagePreflight.ps1` | Default simulation CLI |
| `tests/DisposableImagePreflight.Tests.ps1` | Pester (mocks/fixtures only) |
| `tests/Fixtures/approval-auth/` | Test RSA keys for signature verification |
| `docs/m4-disposable-image-preflight-contracts.md` | Contracts |

## Design choices

1. **No DISM passthrough** — operations are named allowlist entries that build fixed argument templates.
2. **Mock adapter is CI default** — never requires admin or live mounts.
3. **Live read-only gate** — `-Mode LiveReadOnly` requires `-ConfirmLiveReadOnlyPreflight` and `-AllowLiveReadOnlyPreflight`; the latter remains off until post-review operator approval.
4. **Export/mount are classified as disposable preparation** — they create temporary host state and need separate live authorization even though they do not mutate the source ISO.
5. **Cleanup is ownership-scoped** — refuse unrelated mount discard.

## Limitations

- Live ISO hash / export / mount path is implemented behind a hard authorization gate and is not exercised in this milestone.
- Dependency evidence uses structured category checks plus protected-pattern provenance; full Microsoft dependency graphs are not claimed complete.
- Approval signatures use test keys; production key management is out of scope.
