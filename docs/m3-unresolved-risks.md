# Milestone 3 — Unresolved Risks and Limitations

## Intentional non-goals

- Real writable DISM remains unavailable (`realDismExecutionEnabled` always `false`).
- Simulated `Completed` does not mutate images, WIMs, or the source ISO.
- `simulatedAuthorizationResult` is never real execution permission.

## Open risks for a future execution milestone

1. **Dependency evidence is still synthetic** — production dependency graphs for AppX/feature interactions are not fully enumerated. Milestone 2 Eligible ops remain `Unverified` until evidence is supplied.
2. **Mock backend fidelity** — failure injection covers control-flow safety, not every DISM edge case.
3. **Approval storage** — records are local JSON without a trusted signing/attestationservice; operators must protect integrity out of band.
4. **No disposable-image integration yet** — workspace preparation is simulated; a future milestone must export a disposable WIM and prove source ISO immutability with hashes.
5. **Human review still required** — CI and Pester prove contracts; they do not authorize host or image mutation.

## Carry-forward from Milestone 2

- Eligible ≠ approved
- PendingOperatorApproval ≠ approval record
- Unknown / MissingEvidence dependencies fail closed and cannot be overridden by approval
