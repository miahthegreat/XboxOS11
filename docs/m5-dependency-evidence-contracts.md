# Milestone 5 — Dependency Evidence and Servicing Readiness Contracts

Milestone 5 is **analysis and validation only**. It does not authorize or execute writable Windows image servicing.

Schema versions:

| Contract | Version |
|----------|---------|
| Servicing readiness engine | `5.1.0` |
| Dependency evidence schema | `dependency-evidence-v1` |
| Capability requirements schema | `capability-requirements-v1` |
| Servicing readiness report | `servicing-readiness-v1` |
| Evidence quality schema | `evidence-quality-v1` |

## Hard safety invariants

| Flag | Milestone 5 value |
|------|-------------------|
| `realDismExecutionEnabled` | `False` |
| `modifyingCommandsInvoked` | `False` |
| `executionAuthorized` | `False` |
| `servicingAuthorized` | `False` (new report field; always false) |

`VerifiedSafeForConsideration` never means approved for execution.

## Component identity

Components are identified by stable IDs:

- AppX: `appx:{PackageFullName}` (exact inventory identity)
- Feature: `feature:{FeatureName}`
- Package: `package:{PackageIdentity}`
- Capability: `capability:{CapabilityId}`
- Abstract/runtime: `runtime:{CapabilityId}` when not visible in provisioned inventory

Identity resolution for plan operations must use the plan `targetIdentity` / `operationId`, not substring guessing.

## Relationship kinds

| Kind | Meaning |
|------|---------|
| `Requires` | Consumer needs provider |
| `Provides` | Component supplies a capability or API surface |
| `ConflictsWith` | Components must not coexist under the proposed change |
| `OptionalDependency` | Improves function when present; absence alone is not failure |
| `SharedDependency` | Multiple consumers depend on the same provider |
| `UnknownRelationship` | Link suspected but evidence insufficient |

Each relationship carries `phase` (`Runtime`, `InstallationTime`, or `Both`) and one or more evidence IDs.

## Evidence provenance and quality

| `sourceType` | Trust posture |
|--------------|---------------|
| `AuthoritativeDocumentation` | Microsoft/docs contracts with citation |
| `DirectlyObserved` | Parsed from authoritative inventory/transcripts |
| `ControlledTestResult` | Lab/fixture results (never production authorization) |
| `ManifestDeclared` | Repo protection/capability manifests |
| `Assumption` | Explicit hypothesis — **cannot** elevate readiness to `VerifiedSafeForConsideration` |

Quality classifications: `High`, `Medium`, `Low`, `Insufficient`.

Evidence records include source reference, component identity, related operation IDs, Windows build/edition applicability, collection/verification timestamps, staleness policy, limitations, and supporting/contradicting findings.

Synthetic test data (`ControlledTestResult` with fixture provenance) must not be treated as production dependency evidence for overall authorization.

## Operation readiness classifications

| Classification | Meaning |
|----------------|---------|
| `VerifiedSafeForConsideration` | Curated non-assumption evidence supports considering the change; **not** execution approval |
| `KnownUnsafe` | Evidence shows protected-capability harm or conflict |
| `MissingEvidence` | Required dependency/capability evidence absent |
| `ConflictingEvidence` | Supporting and contradicting findings unresolved |
| `Unsupported` | Change class not supported by the engine |
| `NotApplicable` | Operation not Eligible / not in scope |

Fail closed: unresolved critical evidence ⇒ overall decision `Blocked`.

## Capability requirements

Protected gaming/platform capabilities are declared in `config/capability-requirements.json`. Presence of related AppX patterns is **inventory observation only** and does not prove runtime readiness.

Capabilities that depend on components outside provisioned AppX inventory must be marked `NotObservableInProvisionedInventory` / `MissingEvidence`, never silently `Absent` or broken.

## Report traceability

Every servicing-readiness report must include:

- Engine and schema versions
- Plan `contentHash`
- Inventory fingerprint and source image identity
- Architecture (`Unknown` when not established from trustworthy metadata)
- Git commit SHA, dirty-tree flag, or `Unknown` with warning
- Per-Eligible-operation assessments
- Overall decision and blockers

Default analysis uses previously captured Milestone 1/4 inventory evidence. Live DISM requires separate operator authorization and is out of scope for Milestone 5 automation.

## Overall decision

| Decision | When |
|----------|------|
| `Blocked` | Any required Eligible operation is `MissingEvidence`, `ConflictingEvidence`, `KnownUnsafe`, or `Unsupported` |
| `ReadyForReview` | All Eligible ops are `VerifiedSafeForConsideration` or `NotApplicable`, and no critical capability evidence is missing |
| `Failed` | Engine/input validation failure |

`ReadyForReview` still leaves `executionAuthorized=false`.
