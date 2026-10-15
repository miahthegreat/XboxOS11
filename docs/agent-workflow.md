# Claude Code ↔ OpenAI GitHub Actions loop

**Status: migration PR, disabled by default with a NEW variable gate.** Existing XboxOS11 validation is preserved.

## Activation after security review and merge
1. In GitHub Actions secrets configure `OPENAI_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN`. Generate the token with `claude setup-token` (eligible Claude Pro/Max accounts). The values are never committed. Do not reuse or post tokens in chat.
2. **Do not create or enable `CLAUDE_LOOP_ENABLED` until migration security review and tests are completed.** The previous `AGENT_LOOP_ENABLED` variable no longer controls these workflows.
3. Create the `agent-loop` PR label and apply it only to a same-repository, non-protected feature PR.
4. Set `CLAUDE_LOOP_ENABLED=true` only for the smoke test; remove the label or turn it off to pause.

## Architecture and exact trust boundary
1. Existing `Validate` completes successfully on an opted-in PR.
2. `agent-review.yml`, operating solely from the **protected default branch**, reads the untrusted PR diff as data and posts a structured OpenAI review. It never checks out or executes PR code.
3. For `CHANGES_REQUESTED`, it dispatches `agent-fix.yml`. Maximum five cycles.
4. `generate-patch` has only `contents:read`, installs Claude Code CLI, and generates an inert unified-diff artifact. There is **no GitHub write token in Claude Code's environment**, no persisted checkout credentials, no git push.
5. `publish-scoped-patch` is a **separate job and runner** holding `contents:write`. It checks out protected automation and the exact reviewed commit, validates the candidate via deterministic Git checks and a denylist, then commits/pushes allowed tracked regular-file modifications. **No generated PR code is executed** in this privileged job.
6. Because commits created by `GITHUB_TOKEN` do not trigger normal PR/push workflows, the publisher explicitly dispatches `Validate` against the feature branch. A successful dispatch gets a fresh review.
7. The loop stops on `APPROVED_FOR_HUMAN_REVIEW`, `NEEDS_HUMAN_REVIEW`, CI failures, missing credentials, policy violations, or cycle limit. No automatic merges.

## Safeguards and limitations
- No live DISM, image mutation, ISO generation, Hyper-V provisioning, read-only host inspection, VM/VHD/switch/network modifications, or Layer D activation.
- Automated candidate changes are limited to **modifying existing regular text files** in permitted docs/modules/scripts/tests/config paths, with protected authorization and policy files excluded. New files, symlinks, renames, chmod, and protected edits require a human-driven PR.
- Claude Code itself is a remotely connected coding agent with `CLAUDE_CODE_OAUTH_TOKEN` in its job: model or dependency compromise can still expose that key. GitHub write secrets are isolated by job, but **this is not a hardened network sandbox**. Use a dedicated/rotatable Claude Code token and consider egress controls for stronger isolation.
- An OpenAI review is not an independent third-party security certification, nor an approval to merge or operate on a Windows host.
- PR comments, patches, CI outputs, and source files are untrusted. Approval decisions fail closed if they cannot be verified.
- A full two-agent end-to-end smoke test has **not yet been performed**. Secret-free tests cannot prove API key validity, Claude Code write behavior, model compatibility, or live dispatch.
- GitHub branch protection and required human review should be configured separately.

## Troubleshooting
- Validate CI failed: fix manually, no review/fix starts.
- Reviewer did not trigger: check `CLAUDE_LOOP_ENABLED`, PR label, head SHA, runner logs, secret validity.
- Claude Code returned no edits: review remains open; handle manually.
- Publisher rejected patch: inspect safe gate output and perform protected changes in a manually reviewed PR.
- Disable immediately by setting `CLAUDE_LOOP_ENABLED=false`; this prevents new review/fix jobs (does not cancel ones already started).

## Migration from Cursor

The old Cursor CLI installer, `CURSOR_API_KEY` secret reference, old `run_cursor_fix.py`, and `.cursor/rules/automation.mdc` are removed. `CLAUDE.md` defines the Claude Code project rules; `automation/run_claude_fix.py` invokes the official Claude Code CLI in patch-generation only. Do not enable `CLAUDE_LOOP_ENABLED` until an explicit human-approved smoke test. Current OAuth token credential support is documented by Anthropic but authentication has not yet been tested in this repository. Never print or commit the token. If the OAuth token fails for unattended Actions, stop; do not silently fall back to a different credential.
