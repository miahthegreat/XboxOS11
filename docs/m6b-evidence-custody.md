# Milestone 6B — Evidence Custody

**Status:** Implemented under report namespace `m6b` (schema `lab-evidence-v1.1`). Prior M1–M6A baselines must not be modified or deleted by this tooling. Reports are labeled `ExternalValidatedEvidence`, `InlineSimulationEvidence`, or `NotValidated`.

## Manifest (`lab-evidence-v1`)

`New-XboxOSLabEvidenceManifest` records:

- Git commit SHA (when available)
- Source ISO SHA-256
- Experiment plan hash
- Readiness binding digest
- Lab / VM identity
- Environment configuration digest
- Artifact hashes
- Simulation status (transaction state)
- Test coverage rows
- Missing evidence list
- Cleanup status
- Recovery requirements
- Boundary / isolation validity
- Safety flags (`realProvisioningEnabled`, `layerDActivated` always false)

## Namespace separation

| Namespace | Milestone |
|-----------|-----------|
| (legacy stems) | M1–M5 reports under `C:\XboxOS\Logs` |
| experiment-plan / m6a stems | Milestone 6A |
| **`m6b`** | Milestone 6B lab evidence |

`Save-XboxOSIsolatedLabReport` refuses stems that would overwrite retained M1–M6A report names and refuses OneDrive output paths.

## Functional coverage representation

Linked to `config/functional-validation-matrix.json`. Planned statuses are only `NotExecuted`, `EnvironmentLimited`, or `MissingEvidence`. Milestone 6B never marks tests `Passed`.

## Binding to M5 / M6A

CLI prefers validated ExternalValidated M6A experiment + M5 readiness bindings. Inline simulation fixtures require explicit `-Simulation -AllowInlineSimulationReadiness`.
