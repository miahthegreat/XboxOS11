# Milestone 6D — Unresolved Risks

1. **No live host validation** — RealHostCommandProvider is inactive; production host behavior unproven.
2. **Elevation** — Some read-only queries may require administrator rights; elevation must remain human-driven and never automated.
3. **Sensitive identifiers** — Redaction covers common cases; operators must still review destinations before any future live run.
4. **False confidence** — Successful mocked authorized simulation still ends `HostDiscoveryBlocked` for live inspection; operators may misread this as host clearance.
5. **Isolation incompleteness** — Firewall and guest connectivity often remain Unverified; switch presence must not be treated as full isolation.
6. **Signing key custody** — Trusted lab-discovery keys are out of band; test keys in-repo must never be promoted to live trust.
7. **Partial inventories** — Unavailable tools yield Unavailable/Unknown; incomplete evidence must not be presented as complete.

Provisioning, writable DISM, networking mutation, and Layer D remain unauthorized.
