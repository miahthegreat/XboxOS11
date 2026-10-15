# Milestone 6D — Operational Runbook (Future Manual Inspection)

**Do not perform these steps during Milestone 6D implementation or CI.**

This runbook documents the **future** manual procedure for one bounded, operator-authorized, read-only inspection. Implementation acceptance (mocked tests green) is **not** operational validation.

## Preconditions

1. Operator has reviewed report destination paths (outside OneDrive).
2. Tooling Git working tree is clean and SHA matches the approved revision.
3. A **non-test** lab-discovery signing key pair is available (fixture test keys are rejected for live use).
4. Named host identity, scope categories, expiry, nonce, and single-run identity are prepared.
5. Live activation remains a separate human decision (not automated; not available in current CI builds).

## Proposed future steps (manual)

1. Confirm `Get-XboxOSAuthorizedHostDiscoveryLiveActivationEnabled` is the intended operator gate for that host run (today always False in shipped implementation/CI).
2. Create a `HostDiscoveryReal` approval binding the actual host identity, Git SHA, categories, run identity, nonce, expiry, and read-only acknowledgment; sign with the trusted lab key.
3. Re-validate the approval immediately before each allowlisted operation.
4. Execute only typed allowlisted read-only operations; abort on unexpected side effects.
5. Emit evidence under namespace **`m6d`** with redaction applied; do not overwrite M1–M6C stems.
6. Independently review isolation limitations; leave unverified isolation as unverified.
7. Confirm no VM/switch/network/VHD/ISO/image changes and that provisioning/Layer D remain blocked.

## Explicit non-goals

- No DISM writable servicing
- No Hyper-V install/enable as part of discovery
- No VM create/start/stop/delete
- No switch or host networking changes
- No Layer D activation
- No unattended elevation

## Distinction

| Gate | Meaning |
|------|---------|
| Implementation acceptance | Adapter, auth, mocks, CI green — **this milestone** |
| Operational acceptance | Later explicit operator decision on a named host — **not performed here** |
