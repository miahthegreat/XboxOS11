# Milestone 6B Completion Baseline

Milestone 6B is **complete as a simulation-only infrastructure and safety-control milestone**. It delivered lab topology, boundary validation, isolation **policy** checks, ownership/snapshot binding, key-policy validation, integrity/recovery simulation, functional-test planning without invented Passed results, and `m6b` evidence custody — including Milestone 6B.1 authoritative evidence-chain hardening.

**Acceptance of Milestone 6B must not be interpreted as permission to provision virtual machines or modify Windows images.** Layer D remains structurally disabled. Real hypervisor provisioning, virtual-switch changes, VHD mutation, DISM writable servicing, and host networking changes were not performed and remain unauthorized.

## Merge and CI

| Item | Value |
|------|-------|
| Pull request | [#12](https://github.com/miahthegreat/XboxOS11/pull/12) |
| Validated PR HEAD (pre-merge) | `53514f8b005afa76e7d6db96892bddb5ccc95aab` |
| Prior reviewed HEAD (6B.1 hardening) | `f00e6c6ab1bbb71fca407fadc6a2976e2f25f9ab` |
| Merge commit on `main` | `ca30aec866711a0c4dab8f60e975f9167034c4fc` |
| Pre-merge Validate CI | [run 38687608027](https://github.com/miahthegreat/XboxOS11/actions/runs/38687608027) — success on `53514f8` |
| Prior 6B.1 CI | [run 38686867450](https://github.com/miahthegreat/XboxOS11/actions/runs/38686867450) — success on `f00e6c6` |
| Post-merge Validate CI (`main`) | [run 38687793360](https://github.com/miahthegreat/XboxOS11/actions/runs/38687793360) — success on `ca30aec` |
| Automated tests at closure | Parser **0** errors (45 files); Pester **197** passed / 0 failed / 0 skipped; PSScriptAnalyzer **0** errors / **84** warnings |

Local `main` and `origin/main` both point at `ca30aec` after fast-forward.

## Pester count reconciliation (197 → 191 → 197)

| Stage | IsolatedLab `It` count | Suite total | Notes |
|-------|------------------------|-------------|-------|
| Initial M6B merge candidate (`d09201c`) | 22 | 197 | Baseline M6B simulation suite |
| After 6B.1 hardening (`f00e6c6`) | 16 | 191 | Consolidation temporarily dropped six regression assertions |
| Closure restore (`53514f8`) | 22 | **197** | Restored junction/reparse, key-policy replay, unreachable transitions, evidence custody, DISM-cleanup fail-closed, EnvironmentLimited specifics |

No important coverage was left removed at merge. The temporary 191 count was a consolidation artifact, not intentional de-scoping.

## Engine and schemas

| Contract | Version / value |
|----------|-----------------|
| Isolated lab engine | `6.1.1-b` |
| Module | `0.6.2` |
| Topology | `lab-topology-v1` |
| Isolation | `lab-isolation-v1.1` |
| Ownership | `lab-ownership-v1.1` |
| Snapshot | `lab-snapshot-v1` |
| Transaction | `lab-transaction-v1` |
| Evidence | `lab-evidence-v1.1` |
| Evidence chain | `lab-evidence-chain-v1` |
| Key policy | `lab-key-policy-v1` |
| Report | `isolated-lab-report-v1.1` / namespace `m6b` |

Supporting docs:

- [m6b-lab-infrastructure-contracts.md](m6b-lab-infrastructure-contracts.md)
- [m6b-vm-isolation-policy.md](m6b-vm-isolation-policy.md)
- [m6b-integrity-recovery.md](m6b-integrity-recovery.md)
- [m6b-evidence-custody.md](m6b-evidence-custody.md)
- [m6b-unresolved-risks.md](m6b-unresolved-risks.md)
- [m6b-pssa-warning-review.md](m6b-pssa-warning-review.md)
- Design parent: [m6b-isolated-disposable-lab-design.md](m6b-isolated-disposable-lab-design.md)

## PSSA warning classification (84)

Documented in [m6b-pssa-warning-review.md](m6b-pssa-warning-review.md):

| Class | Approx. count | Disposition |
|-------|---------------|-------------|
| Actual defects fixed in 6B.1 | 5 (empty catch ×2, auto-var `$args`/`$matches`) | Corrected; warnings reduced 89 → 84 |
| Style / maintainability | ~51 unused parameters, ~21 plural nouns, ~10 UTF-8 BOM | Justified outstanding; no global suppressions |
| Pre-existing residual | 1 empty catch (`Test-DismCompatibility`), 1 ShouldProcess (`Setup-Gaming`) | Outside M6B mutation surface; tracked |

CI continues to fail on PSSA **errors** only; warning classification is preserved, not suppressed.

## Evidence modes

| Mode / label | Behavior |
|--------------|----------|
| **ExternalValidated** / `ExternalValidatedEvidence` | Default CLI. Requires M1/M4 authoritative inventory + validated M5 + validated M6A. Reconstructs M2 plan; recomputes readiness binding digest and M6A canonical content hash. **No silent synthetic fallback.** |
| **InlineSimulation** / `InlineSimulationEvidence` | Only via `-Simulation -AllowInlineSimulationReadiness`. Explicitly labeled; never interchangeable with ExternalValidated. |
| **NotValidated** | Rejected for lab readiness simulation. |

Neither evidence mode activates real provisioning or Layer D.

## Authoritative evidence-chain validation (host-local)

| Field | Value |
|-------|-------|
| M1/M4 inventory | `C:\XboxOS\Logs\DISM-Compatibility-20261014-2.json` |
| M5 readiness | `C:\XboxOS\Logs\XboxOS11-servicing-readiness-m5.json` |
| M6A experiment plan | `C:\XboxOS\Logs\XboxOS11-experiment-plan-m6a-auth.json` |
| M2 plan content hash | `79ACF41CCD2FB47BB582409F073580A056A83AF746A0C894612DCF1FDFA2ABCB` |
| Inventory fingerprint | `ACBAD6D4750FA7980A1E6023AFEEE49FEA8937E2FB4E85F644814D5AC1EE84EA` |
| M5 readiness binding digest | `1154350B559E5E8BE08D604DBF329AACBC6C8B48190BDC0B21D2AF6C31F29FA3` |
| M6A experiment content hash | `1668204AD53F552CC2EACFF9F727C8B26A85EB5E9ECF06DFDD26AE7F566D0003` |
| Source ISO SHA256 | `BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650` |
| Chain validity | **True** (`ExternalValidatedEvidence`) |

Missing or tampered reports fail closed (missing path, altered content hash, contradictory ISO, forged operations, missing git provenance).

## Isolation policy vs actual verification

| Field | Closure result |
|-------|----------------|
| `policyValidationStatus` | `PolicyValidated` |
| `configurationStatus` | `ConfigurationDeclared` |
| `declaredIsolationMode` | `IsolatedSwitch` |
| `hypervisorInspectionStatus` | **`HypervisorNotInspected`** |
| `networkIsolationVerificationStatus` | **`NetworkIsolationNotVerified`** |
| `actualIsolationVerified` | **`False`** |
| `environmentLimitationStatus` | `EnvironmentLimited` |

A valid declared IsolatedSwitch policy is **not** proof that a virtual switch exists or that network isolation was independently verified. Milestone 6B does not query or modify the hypervisor.

## Decision and recovery

| Outcome | Value |
|---------|-------|
| Final decision | **`LabProvisioningBlocked`** |
| Transaction terminal state (happy path) | **`LabProvisioningBlocked`** |
| Injected fail-closed cases | **`RecoveryRequired`** (ISO hash, snapshot mismatch, evidence substitution, cleanup verification, etc.) |
| Global DISM cleanup on failure | **False** |
| Unrelated hive unload | **False** |

## Functional-test status distribution

Bound to `config/functional-validation-matrix.json` (14 tests). Milestone 6B never invents Passed:

| Status | Count (VM environment plan) | Examples |
|--------|-----------------------------|---------|
| `EnvironmentLimited` | 5 | GPU/DX, USB/BT controller, XInput, GameInput, anti-cheat |
| `MissingEvidence` | 9 | Xbox FSE, Xbox auth, Gaming Services, Store, audio, network, WU, servicing/recovery, game launch |
| `Passed` | **0** | — |

## Evidence provenance and custody

- Report namespace: **`m6b`**
- Ownership digests bind lab/VM/workspace IDs to M2 plan hash, M5 readiness digest, M6A experiment hash, inventory fingerprint, and ISO SHA256
- Ownership digests are **integrity checks**, not authorization signatures
- Save path refuses overwrite of M1–M6A baseline stems and OneDrive output roots
- Prior baselines under `C:\XboxOS\Logs` remain untouched

## Hard safety invariants (always False)

| Flag | Value |
|------|-------|
| `realDismExecutionEnabled` | `False` |
| `modifyingCommandsInvoked` | `False` |
| `executionAuthorized` | `False` |
| `servicingAuthorized` | `False` |
| `experimentalMutationEnabled` | `False` |
| `experimentalExecutionAuthorized` | `False` |
| `labRealProvisioningEnabled` | `False` |
| `labHypervisorCommandsInvoked` | `False` |
| `layerDActivated` | `False` |

## Unresolved dependencies and lab limitations

See [m6b-unresolved-risks.md](m6b-unresolved-risks.md):

1. No real hypervisor validation or provisioning.
2. Network isolation not independently verified.
3. GPU / controller / anti-cheat remain EnvironmentLimited.
4. Online Microsoft service tests remain MissingEvidence.
5. Snapshot restore mechanics unimplemented.
6. Guest credential production custody unimplemented.
7. Layer D still disabled pending a separately reviewed execution gate.

## Distinction: infrastructure pass vs provisioning authorization

| Question | Answer |
|----------|--------|
| Did Milestone 6B merge with green CI and documented contracts? | **Yes** |
| May the host provision VMs, switches, or VHDs based on this pass? | **No** |
| Does `PolicyValidated` prove network isolation? | **No** |
| Does evidence-chain validation enable Layer D or writable DISM? | **No** |
| Does simulation success authorize image mutation? | **No** |

Proposed next phase (documentation only): [m6c-real-host-lab-discovery-design.md](m6c-real-host-lab-discovery-design.md).
