# Milestone 6B — Unresolved Risks

## Residual risks (fail closed today)

1. **No real hypervisor validation** — Topology and isolation are simulation-tested only. Hyper-V (or other) provisioning paths remain unimplemented and unauthorized.
2. **Layer D still disabled** — Lab key policy validates future requirements but cannot authorize writable image mutation.
3. **GPU / controller / anti-cheat evidence** — Marked `EnvironmentLimited`; physical or passthrough environments are not established.
4. **Online Microsoft service tests** — Store, Xbox auth, and Windows Update remain `MissingEvidence` until a reviewed online connectivity profile exists.
5. **Guest credential custody** — Policy requires ephemeral lab-only credentials; production secret-management integration is not implemented.
6. **Snapshot restore mechanics** — Snapshot records are bound and validated; actual VM snapshot create/restore is not implemented.
7. **Host path existence** — Default `C:\XboxOS\Lab\*` roots may not exist on a given host; planning does not create them.
8. **Approval cryptography reuse** — Lab key policy is structural; it does not introduce production trust roots or HSMs.

## Explicit non-goals (must remain unauthorized)

- Writable DISM / WIM export-mount-modify
- Real VM, VHD, or switch provisioning
- Enabling Hyper-V or changing host networking
- Activating Layer D
- Beginning Milestone 6C

## Exit criteria for later milestones

A future milestone may narrow these risks only with separate operator authorization, real lab gates, and evidence — never by reusing M6B simulation success as execution authorization.
