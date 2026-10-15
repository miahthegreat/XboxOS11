# Milestone 6A — Unresolved Risks

1. **No live disposable mutation** — workspace constraints and snapshots are simulated; WIM create/mount is not executed.
1a. **Skipped Pester note** — historically, “rejects protected Xbox/Gaming Services style selections when plan status is Protected” skipped because the fixture M2 plan has no `status=Protected` operations among removable candidates (protected packages are filtered earlier). 6A.1 replaces that case with an explicit forged Eligible + protected-identity allowlist rejection test.
2. **All Eligible ops remain MissingEvidence** — planning and simulated consent/risk acceptance do not close dependency gaps.
3. **Layer D structurally disabled** — Milestone 6B must introduce a separate lab authorization path; 6A planning approval is not execution authorization.
4. **Test-key cryptography only** — PEM fixtures are not production HSM/signing custody.
5. **Functional validation unexecuted** — catalog exists; no Xbox FSE / Store / controller runtime evidence yet.
6. **Architecture still Unknown** — inherited from M5 source metadata gaps.
7. **Risk-acceptance policy is a stub** — simulated Layer C must not be mistaken for an approved production override.
8. **Host retains prior baselines** — operators must not overwrite M1–M5 reports under `C:\XboxOS\Logs`.
