# Milestone 4 — Unresolved Risks

1. **Live read-only preflight not yet operator-authorized** — code path exists behind gates; must not run until explicit approval after review.
2. **Dependency completeness** — category evidence reduces Unknowns but does not prove full AppX/feature graphs.
3. **Approval auth** — RSA test-key verification proves the design; production HSM/key custody not implemented.
4. **Host mount contention** — live runs must still detect unrelated mounts and fail closed.
5. **No writable servicing** — Milestone 5+ must not treat M4 simulation or live read-only success as mutation permission.
