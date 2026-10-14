# Milestone Roadmap

## M1: Image build foundation (current)

Reproducible Windows ISO customization pipeline.

- Prerequisite validation
- Source ISO import and edition export
- Inventory-before/after
- Manifest-driven AppX removal and optional feature disable
- Optional INF drivers and CAB/MSU updates
- Validation reports and oscdimg ISO export
- Pester unit tests and GitHub Actions validation
- Conservative Xbox mode documentation/post-install stubs

## M2: Unattended installation

Windows Setup automation, edition selection, user configuration, and privacy settings without hardcoded credentials.

## M3: Xbox mode integration

Supported Xbox FSE configuration, controller-first startup, and launcher integration—only after validating Microsoft-supported mechanisms on desktop hardware.

## M4: Gaming performance

Benchmark-driven service and startup optimization for Ryzen 7 7800X3D and Radeon RX 9070 XT, without disabling security for synthetic gains.

## M5: Recovery and maintenance

Windows Update validation, recovery options, rollback mechanisms, and compatibility testing.

## M6: Release engineering

Versioned build manifests, release documentation, automated validation, and reproducible local builds.
