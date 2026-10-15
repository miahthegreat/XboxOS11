# GitHub-based Cursor ↔ OpenAI review loop

**Status: opt-in; not active until explicitly configured and merged.** Existing Validate CI is unchanged.

## Setup

1. Review and merge the automation PR after reviewing workflow security.
2. In GitHub repository **Settings → Secrets and variables → Actions → Secrets**, add `OPENAI_API_KEY` and `CURSOR_API_KEY`. Never paste credentials into a PR or chat.
3. Under **Variables**, set `AGENT_LOOP_ENABLED` to `true`. Set `AGENT_REVIEW_MODEL` if needed (default `gpt-5.2`).
4. Apply the `agent-loop` label to a **same-repository feature PR** only when you want autonomous fixes. Create that label in Issues → Labels if absent.
5. Open a normal PR; wait for existing Validate CI. A successful PR Validate triggers Agent Review, which posts machine-readable findings. If CHANGES_REQUESTED, a workflow dispatch starts Agent Fix. Cursor pushes a scoped correction, triggering Validate again.

## Boundaries

- Only same-repository PRs with the explicit `agent-loop` label qualify.
- Fork PRs are rejected. Workflows and reviewer code are checked out from the protected default branch, never from untrusted PR code with secrets.
- Reviews use the GitHub API to read diff and CI provenance; no PR code is executed in reviewer.
- Fixes run on ephemeral GitHub-hosted Linux, not your Windows computer. Agent instructions alone are not trusted; a deterministic diff gate rejects edits to workflow/automation/policy/safety files.
- At most five CHANGES_REQUESTED cycles per PR. The bot never merges, provisions VMs, runs DISM, authorizes host inspection, or modifies Windows images.
- Approval is **APPROVED_FOR_HUMAN_REVIEW**, never a substitute for your merge decision.
- API failures result in no approval or fix dispatch.
- Disable immediately by setting `AGENT_LOOP_ENABLED=false` or removing the PR label.
- OpenAI and Cursor API usage can incur independent charges; monitor limits with both providers.

## Limitations and follow-up review

This GitHub workflow uses an OpenAI API reviewer, not the interactive ChatGPT session. Cursor CLI availability, permissions configuration, and workflow GitHub token permissions must be validated in an opt-in smoke test before relying on automation. Sensitive security/authorization files require manual work outside auto-fix scope. Platform branch-protection policies and required human approval should be set in GitHub settings; this connector cannot edit repository secrets or enforce rulesets.
