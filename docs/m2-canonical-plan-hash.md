# Milestone 2 — Canonical plan hash (plan-hash-v1)

## Versions

| Field | Value |
|-------|-------|
| `hashSchemaVersion` | `plan-hash-v1` |
| `engineVersion` | Matches `Get-XboxOSServicingPlanEngineVersion` (currently `2.1.0`) |
| Algorithm | UTF-8 bytes → SHA256 → uppercase hex (no separators) |

Changing `hashSchemaVersion` or `engineVersion` intentionally invalidates prior hashes.

## Included (safety-relevant)

Deterministic ordered document containing:

1. `hashSchemaVersion`, `engineVersion`
2. Source-image identity (`editionName`, `sourceIndex`, `buildNumber`, `displayVersion`, `isoSha256` when known)
3. Inventory fingerprint (sorted AppX identities + feature name/state pairs) and verification status
4. Manifest content fingerprints (`remove-apps`, `disable-features`, `compatibility`) as SHA256 of canonical JSON
5. Every operation’s: `operationId`, `operationType`, `targetKind`, `targetIdentity`, `manifestSource`, `manifestRuleId`, `matchPattern`, `currentState`, `proposedAction`, `status`, `risk`, `protectionEvaluation`, sorted `dependencies`, `executionOrder`, `expectedOutcome`, `skipOrRejectionReason`, `approvalRequired`, `dependencyCompleteness`
6. Sorted blocking `errors`
7. Sorted execution-relevant `warnings` (Eligible / dependency / protection warnings)
8. `approvalGate`, hard-coded `executionAuthorized=false`, `modifyingCommandsInvoked=false`

## Excluded (volatile / non-binding)

- `planId`, `generatedUtc`
- Absolute report output paths
- Host-specific transcript paths
- Any future operator approval tokens or wall-clock stamps

## Compatibility rules

- Producers MUST emit `plan-hash-v1` documents with stable property order (`[ordered]` / sorted arrays).
- Consumers MUST reject plans whose `hashSchemaVersion` they do not implement.
- A future executor MUST recompute the hash from live inputs and refuse to proceed on mismatch (state drift).
- Approval metadata MUST NOT be part of the hash input that an executor treats as permission; executors re-verify image identity, inventory, manifests, protection, and hash immediately before any mutation.

## Stability

Identical engine version + identical inventory fingerprint + identical manifest fingerprints + identical operation set ⇒ identical `contentHash`.
