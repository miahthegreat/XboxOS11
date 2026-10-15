# Claude Code + OpenAI agent-loop smoke test

This documentation page describes the expected behavior of the GitHub Actions agent review and fix loop for XboxOS11.

## Automated review and correction

1. GitHub runs the Validate workflow for an opted-in pull request.
2. OpenAI reviews the PR changes and requests corrections when needed.
3. Claude Code applies permitted corrections to existing ordinary documentation or source files.
4. GitHub repeats validation and review as necessary.
5. After an APPROVED_FOR_HUMAN_REVIEW decision, the automation must NOT merge the pull request. It stops and waits for a human reviewer or maintainer to approve and merge. If human approval is not granted, nothing is merged.

## Boundaries

No DISM, WIM/ISO mutation, live host inspection, VM provisioning, or network reconfiguration is authorized by this smoke test. The agent must not edit GitHub workflow or safety-control files. This PR changes documentation only, and only this file.

If validation, review, or fix steps fail, the automation stops and reports the failure; it must not bypass any safety gate.

## Test outcome

A successful review identifies and corrects any inaccurate description of the workflow, commits only a scoped documentation patch, and leaves this PR available for final human approval.

<!-- Trigger: rerun Validate after operator enabled the Claude smoke-test loop. -->
