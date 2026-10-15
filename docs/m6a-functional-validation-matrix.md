# Milestone 6A — Functional Validation Matrix

**Status:** Catalog defined (`functional-validation-v1`). No capability is marked passed; no runtime tests are executed.

Catalog file: `config/functional-validation-matrix.json`

## Capabilities covered

| Area | Test id prefix |
|------|----------------|
| Xbox Full Screen Experience | `fv-xbox-fse-*` |
| Xbox application authentication | `fv-xbox-auth-*` |
| Gaming Services | `fv-gaming-services-*` |
| Microsoft Store and licensing | `fv-store-*` |
| Game installation and launch | `fv-game-launch-*` |
| USB/Bluetooth controllers | `fv-controller-*` |
| XInput and GameInput | `fv-xinput-*`, `fv-gameinput-*` |
| Graphics and DirectX | `fv-graphics-*` |
| Audio and spatial audio | `fv-audio-*` |
| Networking | `fv-network-*` |
| Windows Update | `fv-wufb-*` |
| Anti-cheat compatibility | `fv-anticheat-*` |
| Windows servicing and recovery | `fv-servicing-recovery-*` |

## Per-test contract fields

Each entry defines: `testId`, `capabilityId`, `prerequisites`, `executionEnvironment`, `expectedResult`, `evidenceRequirements`, `failureSeverity`, `abortBehavior`, `recoveryExpectations`.

## Evidence rule

Do **not** claim a capability has passed until actual controlled runtime evidence (`ControlledTestResult`) exists. Milestone 6A only binds required test ids into the experiment plan for future disposable-lab use.
