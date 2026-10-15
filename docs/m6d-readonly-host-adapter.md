# Milestone 6D — Read-Only Host Adapter

**Status:** Implemented as typed, allowlisted contracts. **Live host execution is structurally inactive** (`Get-XboxOSAuthorizedHostDiscoveryLiveActivationEnabled` = False). CI and default CLI use `MockCommandProvider` only.

## Modes

| Mode | Provider | CI / default CLI |
|------|----------|------------------|
| `AuthorizedMockReadOnly` | `MockCommandProvider` | Used |
| `RealHostReadOnly` | `RealHostCommandProvider` | Constructible for interface tests; **execution throws** while live activation is False |

## Typed operations

Catalog: `config/host-discovery-allowlist.json` (`host-discovery-allowlist-v1`, catalog `6.3.0-d`).

Each operation records: operation ID, command provider (`TypedDiscoveryOperation`), allowed parameters (none free-form), required permissions, expected output schema, timeout, read-only classification, failure behavior, evidence rules.

Covered categories: OS info, CPU virtualization, Hyper-V management presence, VM/switch inventory, adapters, VHD metadata, host resources, workspace boundaries, lab credential prerequisites, optional DISM mount metadata (separate scope approval).

## Prohibitions

No `Invoke-Expression`, unrestricted process runner, or arbitrary shell arguments. Denied patterns include New/Start/Stop/Remove VM, switch mutation, VHD mount/create, WindowsOptionalFeature enable/disable, Mount/Dismount/Cleanup-WindowsImage, netsh, firewall mutation.

Unavailable Hyper-V tools → `Unavailable` / Unknown inventories (never invented empty hosts).

## Module entry points

- `New-XboxOSAuthorizedHostDiscoveryAdapter`
- `Invoke-XboxOSAuthorizedHostDiscoveryAdapterOperation`
- `New-XboxOSMockHostDiscoveryCommandProvider` / `New-XboxOSRealHostDiscoveryCommandProvider`
- `Invoke-XboxOSAuthorizedHostDiscoverySimulate` (mocks only)
- Engine: `6.3.0-d` (`Get-XboxOSAuthorizedHostDiscoveryEngineVersion`)
