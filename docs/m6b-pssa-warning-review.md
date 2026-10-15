# Milestone 6B.1 — PSScriptAnalyzer Warning Review

Collected against CI-equivalent settings (Error + Warning; excluding `PSUseShouldProcessForStateChangingFunctions`, `PSAvoidUsingWriteHost`, `PSUseDeclaredVarsMoreThanAssignments`).

## Totals

| Metric | Before 6B.1 fixes | After 6B.1 fixes |
|--------|-------------------|------------------|
| Errors | 0 | 0 |
| Warnings | 89 | **84** |

## Classification

### Actual defects corrected

| Rule | Location | Action |
|------|----------|--------|
| `PSAvoidUsingEmptyCatchBlock` | `IsolatedLab.ps1` path overlap check | Catch now records a fail-closed path-evaluation error |
| `PSAvoidUsingEmptyCatchBlock` | `DisposableExperimentPlan.ps1` workspace/ISO parent check | Same fail-closed error recording |
| `PSAvoidAssignmentToAutomaticVariable` | `DisposableImagePreflight.ps1` (`$args`) | Renamed to `$argumentList` |
| `PSAvoidAssignmentToAutomaticVariable` | `ServicingReadiness.ps1` (`$matches`) | Renamed to `$catalogMatches` |

### Security / correctness — further review (not defects in current sim-only scope)

| Rule | Notes |
|------|-------|
| Remaining empty-catch / ShouldProcess in `Test-DismCompatibility.ps1`, `Setup-Gaming.ps1` | Pre-existing; out of M6B.1 mutation surface. Track for later hardening; no global suppression added. |

### Style / maintainability (justified outstanding)

| Rule | Count (approx.) | Justification |
|------|-----------------|---------------|
| `PSReviewUnusedParameter` | ~51 | Many public API parameters reserved for future gates or symmetry with sibling cmdlets; changing signatures would break contracts. |
| `PSUseSingularNouns` | ~21 | Established `XboxOS` plural nouns (`Invariants`, `Boundaries`, `Constraints`) match domain language; renaming would churn exports. |
| `PSUseBOMForUnicodeEncodedFile` | ~10 | Repo standard is UTF-8 without BOM; adding BOM risks noisy diffs and tool inconsistency. |

### Established false positives

- Plural-noun warnings on intentionally plural safety/boundary cmdlets.
- BOM warnings for UTF-8 module/script files that contain non-ASCII punctuation in comments/strings.

## Policy

No analyzer rules were suppressed globally to reduce counts. Existing CI exclude list unchanged.
