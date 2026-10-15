# Milestone 4 — Unresolved Risks

1. **Live read-only still requires a human operator** — the real adapter and gated CLI path are implemented and harness-tested; a host run must not start from CI or unattended automation.
2. **Dependency completeness** — category evidence reduces Unknowns but does not prove full AppX/feature graphs.
3. **Approval auth** — RSA test-key verification proves the design; production HSM/key custody not implemented. Test keys must never be treated as production-trusted.
4. **Host mount contention** — live runs must still detect unrelated mounts and fail closed; cleanup failure leaves RecoveryRequired state with preserved workspace/logs.
5. **No writable servicing** — Milestone 5+ must not treat M4 simulation or live read-only success as mutation permission (`realDismExecutionEnabled` / `modifyingCommandsInvoked` / `executionAuthorized` remain false).
