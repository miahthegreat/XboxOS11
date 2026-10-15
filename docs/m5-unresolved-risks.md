# Milestone 5 — Unresolved Risks

1. **Incomplete removal-safety contracts** — Eligible consumer AppX remain `MissingEvidence`; package-name non-membership in protected patterns is insufficient.
2. **Partial dependency graph** — curated edges are explicit and sparse; transitive closures are incomplete by design until evidenced.
3. **Non-observable critical capabilities** — Xbox FSE, controllers, GPU drivers, anti-cheat, Update/servicing stacks cannot be proven from provisioned AppX alone.
4. **Architecture metadata** — current baseline DISM export metadata leaves Architecture null → reports `Unknown`.
5. **No runtime/lab validation yet** — future modification tests are documented only; ControlledTestResult production authorization is out of scope.
6. **Approval auth still test-key grade** — Milestone 5 does not introduce production signing/HSM custody.
7. **No writable servicing** — `VerifiedSafeForConsideration` and any future `ReadyForReview` decision must not set `executionAuthorized` / `servicingAuthorized` / `realDismExecutionEnabled`.
