# Milestone 4 — Unresolved Risks

1. **Dependency completeness** — live preflight `preflight-20261015034144569` completed cleanup successfully but decision remained `Blocked` with `MissingEvidence` / `Unknown` categories. Absence from protected patterns alone never proves removal safety.
2. **Architecture metadata gap** — live `sourceImage.architecture` was empty; edition/build identity still verified.
3. **Git commit not embedded in live reports** — operator confirmed SHA `94a3021…`; report schema should carry commit/engine provenance in Milestone 5.
4. **Approval auth** — RSA test-key verification proves the design; production HSM/key custody not implemented. Test keys must never be treated as production-trusted.
5. **Host evidence retention** — disposable WIM under `C:\XboxOS\Work\preflight-20261015034156442\` is retained outside Git; do not commit media artifacts.
6. **No writable servicing** — Milestone 5+ must not treat M4 simulation or live read-only lifecycle success as mutation permission (`realDismExecutionEnabled` / `modifyingCommandsInvoked` / `executionAuthorized` remain false).
