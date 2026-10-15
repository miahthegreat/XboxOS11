# Milestone 4 — Implementation Notes

## Layout

| Path | Role |
|------|------|
| `modules/XboxOS.Build/DisposableImagePreflight.ps1` | Read-only allowlist, mock + real adapters, workspace, live lifecycle |
| `scripts/Test-DisposableImagePreflight.ps1` | Default simulation CLI; gated live entry point |
| `tests/DisposableImagePreflight.Tests.ps1` | Pester (mocks / recording native runner only) |
| `tests/Fixtures/approval-auth/` | Test RSA keys for signature verification |
| `docs/m4-disposable-image-preflight-contracts.md` | Contracts |

## Design choices

1. **No DISM passthrough** — named allowlist operations build fixed argument templates; native invoke requires an exact template match.
2. **Mock adapter is CI default** — never requires admin or live mounts.
3. **Real adapter** — `New-XboxOSRealReadOnlyDismAdapter` with injectable `NativeRunner` for tests; production path shells `dism.exe` only with allowlisted argument arrays.
4. **Live read-only gate** — `-Mode LiveReadOnly` requires `-ConfirmLiveReadOnlyPreflight`, `-AllowLiveReadOnlyPreflight`, and `-IUnderstandTemporaryHostState`. CI (`GITHUB_ACTIONS` / `CI` / `TF_BUILD`) always refuses.
5. **ISO → install.wim/esd → export** — live path mounts the ISO, enumerates indexes, exports the exact Windows 11 Pro index to a disposable WIM, then dismounts the ISO before read-only WIM mount.
6. **Observed metadata** — build/UBR/DisplayVersion/edition come from mounted-image hive + DISM image info; expected identity is stored separately and compared fail-closed.
7. **Owned registry hive mounts** — unique `HKLM\XboxOSPreflight-<run>-<nonce>` keys with ownership tokens; unload requires exit code 0 and independent absence checks; WIM cleanup cannot succeed while a hive may remain loaded.
8. **Verified cleanup** — after `/Unmount-Image /Discard`, `/Get-MountedImageInfo` must confirm the owned mount is absent; Failed cleanup status is sticky.
9. **Hard flags stay false** — `realDismExecutionEnabled`, `modifyingCommandsInvoked`, and `executionAuthorized` remain false (writable servicing). Separate activity flags record real inspection / export / read-only mount.
10. **Live reports use a separate namespace** — `m4-live-readonly` so Milestone 1 evidence is never overwritten.

## Operator live command (do not run from automation)

See `docs/m4-disposable-image-preflight-contracts.md` for the exact elevated PowerShell command. This milestone implements the path; operators must review and run it manually outside CI.

## Limitations

- Live ISO path is implemented and unit-tested via harnesses; a real host run still requires an elevated operator on a machine with the expected ISO.
- Dependency evidence uses structured category checks plus protected-pattern provenance; full Microsoft dependency graphs are not claimed complete.
- Approval signatures use test keys; production key management is out of scope.
