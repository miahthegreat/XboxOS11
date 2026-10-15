# Milestone 6D — Isolation Evidence

Independent assessment of directly observed (or mocked) host facts, separate from declared M6B topology.

## Recorded states

| Observation | Meaning |
|-------------|---------|
| Hypervisor available / unavailable | Management tools/feature signals |
| Named virtual switch observed / absent | Existence only |
| Actual switch type | Private / Internal / External / unknown |
| External network adapter binding | Production uplink indicators |
| Production bridge indicators | Unsafe when observed |
| Existing VM membership | Shared production tagging |
| Host firewall evidence | Often Unavailable → Unverified |
| Unknown guest connectivity | Guest isolation untested |
| Missing independent observations | Evidence incomplete |

## Critical rule

**Host switch inventory alone must not establish complete guest network isolation.**

A switch named `IsolatedSwitch`, or typed Private/Internal, is necessary-but-not-sufficient. Mock/fixture observations cannot set `ActualIsolationVerified=True`.

Status enum when incomplete: **`NetworkIsolationNotVerified`**.

## Evaluation API

`Test-XboxOSHostDiscoveryIsolationObservations` (shared with M6C) with:

- `ObservationSource MockFixture` — always `actualIsolationVerified=false`
- `ObservationSource IndependentHostObservation` — only when all mandatory criteria are `Verified` (not used by CI mocks)

Mandatory criterion IDs: `switch-exists`, `switch-type`, `production-bridge`, `host-admin-shares`, `firewall-evidence`, `production-vm-sharing`.
