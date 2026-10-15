# Milestone 6D — Operator Authorization

**Status:** Implemented for validation contracts. **No live inspection is authorized by this milestone.** Test keys may be used only with explicit simulation-only switches and never satisfy trusted lab-discovery identity requirements.

## Approval layer

Distinct layer: **`HostDiscoveryReal`** / schema `host-discovery-real-approval-v1`.

M6C `HostDiscovery` / `host-discovery-approval-v1` records are **never** valid for real-host discovery.

## Binding fields

| Field | Requirement |
|-------|-------------|
| Operator identity | Required |
| Actual host identity key | Must match host under inspection |
| Tooling Git SHA | Exact match |
| Approved categories | Must be subset of scope |
| Expiry | Fail closed when expired |
| Unique nonce | Non-replayable |
| Single-run identity | Non-replayable |
| Read-only acknowledgment | Required |
| Public key fingerprint | Bound into hash |
| Signature | RSA SHA256 over signing payload |

Scope must set `realHostAllowed=true`. DISM mount metadata requires `dismMountApproved`.

## Fail-closed rules

1. Approval absent by default → `HostDiscoveryBlocked`
2. M6C mock approvals rejected
3. Repository fixture test keys cannot authorize real inspection (`AllowTestKeyForSimulationOnly` is simulation-only)
4. Changed scope or Git SHA invalidates approval
5. Expired or replayed nonce/run identity fails closed
6. Dirty or unverified tooling state blocks live-equivalent gates
7. Approval revalidated immediately before each permitted discovery operation
8. No unattended elevation
9. No provisioning or Layer D grants

## Manual future activation (not performed in this milestone)

See [m6d-operational-runbook.md](m6d-operational-runbook.md). Implementation success ≠ operational validation.
