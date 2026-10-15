# Milestone 5 — Future Controlled Modification Test Strategy

This document defines **future** validation requirements for disposable Windows images. It is **not** evidence that these capabilities currently work, and none of these tests are executed in Milestone 5.

## Preconditions

- Disposable WIM export from a verified source ISO (Milestone 4 pattern)
- Read-only baseline inventory and servicing-readiness matrix (`Blocked` until evidence is complete)
- Independently reviewed approval records (future milestone; not test-key only)
- Explicit human authorization for any writable disposable-image experiment
- Source ISO never modified; commits only against disposable working images

## Proposed functional validation matrix

| Area | Proposed validation | Failure handling |
|------|---------------------|------------------|
| Xbox Full Screen Experience startup | Boot disposable image / VM; confirm documented Xbox mode entry points | Discard WIM; preserve logs |
| Xbox app authentication | Sign-in with test account; identity provider present | Discard; do not weaken identity packages |
| Gaming Services | Runtime service/app launch smoke | Discard |
| Microsoft Store downloads | Install a small free test app | Discard |
| Game install/launch | Optional lab title only | Discard |
| Controller input | USB and/or Bluetooth controller enumeration + GameInput/XInput smoke | Discard |
| Audio output | Render test tone / spatial audio toggle where available | Discard |
| Network connectivity | DHCP + TLS reachability to Store/Xbox endpoints | Discard |
| Windows Update | Scan-only or lab WSUS; no production host mutation | Discard |
| Anti-cheat compatibility | Documented checklist only; no security disablement | Abort if security surfaces altered |
| Reversal / recovery | `/Discard` unmount; confirm mount inventory empty; hive unload verified | RecoveryRequired + evidence retention |

## Evidence rules

- Controlled test results may be recorded as `ControlledTestResult` evidence with timestamps, environment, and limitations.
- Controlled tests do **not** automatically authorize production servicing.
- Missing or failed tests keep readiness at `MissingEvidence` / `Blocked`.
- Never treat synthetic fixture data as production dependency evidence.

## Explicit non-goals (Milestone 5)

- No live DISM from automation
- No AppX removal, feature disable, driver/update injection
- No production ISO build
- No host Windows modification
