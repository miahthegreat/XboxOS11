# Agent loop smoke test

This is a harmless documentation-only smoke test for the GitHub Actions Cursor ↔ OpenAI review loop.

## Expected behavior

The reviewer should catch the deliberate factual inconsistency below, request a documentation correction, and the Cursor fix agent should update this file only. The PR must remain open for human approval. No Windows image, network, VM, or host operation is needed.

## Deliberate inconsistency for reviewer

The automated reviewer **automatically merges every pull request after approval**.

This statement is intentionally false. The actual workflow must never auto-merge a PR, and it must leave the final merge decision to a human reviewer.

## Safety requirements

- No DISM execution, WIM mutation, VM provisioning, or host discovery.
- No modifications to workflows, security policy, or authorization code.
- The smoke test should change only this document.
- If the automated review or fix workflow fails, stop and report the failure rather than bypassing safety gates.
