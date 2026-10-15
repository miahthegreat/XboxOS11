# Cursor ↔ OpenAI GitHub Actions loop

**Status: draft, disabled by default.** Existing XboxOS11 validation is preserved.

## Activation after security review and merge
1. In GitHub Actions secrets configure `OPENAI_API_KEY` and `CURSOR_API_KEY`. The values are never committed.
2. Keep Actions variable `AGENT_LOOP_ENABLED=false` until a harmless, operator-approved smoke test.
3. Create the `agent-loop` PR label and apply it only to a same-repository, non-protected feature PR.
4. Set `AGENT_LOOP_ENABLED=true` only for the smoke test; remove the label or turn it off to pause.

## Architecture and exact trust boundary
1. Existing `Validate` completes successfully on an opted-in PR.
2. `agent-review.yml`, operating solely from the **protected default branch**, reads the untrusted PR diff as data and posts a structured OpenAI review. It never checks out or executes PR code.
3. For `CHANGES_REQUESTED`, it dispatches `agent-fix.yml`. Maximum five cycles.
4. `generate-patch` has only `contents:read`, installs Cursor CLI, and generates an inert unified-diff artifact. There is **no GitHub write token in Cursor's environment**, no persisted checkout credentials, no git push.
5. `publish-scoped-patch` is a **separate job and runner** holding `contents:write`. It checks out protected automation and the exact reviewed commit, validates the candidate via deterministic Git checks and a denylist, then commits/pushes allowed tracked regular-file modifications. **No generated PR code is executed** in this privileged job.
6. Because commits created by `GITHUB_TOKEN` do not trigger normal PR/push workflows, the publisher explicitly dispatches `Validate` against the feature branch. A successful dispatch gets a fresh review.
7. The loop stops on `APPROVED_FOR_HUMAN_REVIEW`, `NEEDS_HUMAN_REVIEW`, CI failures, missing credentials, policy violations, or cycle limit. No automatic merges.

## Safeguards and limitations
- No live DISM, image mutation, ISO generation, Hyper-V provisioning, read-only host inspection, VM/VHD/switch/network modifications, or Layer D activation.
- Automated candidate changes are limited to **modifying existing regular text files** in permitted docs/modules/scripts/tests/config paths, with protected authorization and policy files excluded. New files, symlinks, renames, chmod, and protected edits require a human-driven PR.
- Cursor itself is a remotely connected coding agent with `CURSOR_API_KEY` in its job: model or dependency compromise can still expose that key. GitHub write secrets are isolated by job, but **this is not a hardened network sandbox**. Use a dedicated limited Cursor key and consider egress controls for stronger isolation.
- An OpenAI review is not an independent third-party security certification, nor an approval to merge or operate on a Windows host.
- PR comments, patches, CI outputs, and source files are untrusted. Approval decisions fail closed if they cannot be verified.
- A full two-agent end-to-end smoke test has **not yet been performed**. Secret-free tests cannot prove API key validity, Cursor write behavior, model compatibility, or live dispatch.
- GitHub branch protection and required human review should be configured separately.

## Troubleshooting
- Validate CI failed: fix manually, no review/fix starts.
- Reviewer did not trigger: check `AGENT_LOOP_ENABLED`, PR label, head SHA, runner logs, secret validity.
- Cursor returned no edits: review remains open; handle manually.
- Publisher rejected patch: inspect safe gate output and perform protected changes in a manually reviewed PR.
- Disable immediately by setting `AGENT_LOOP_ENABLED=false`; this prevents new review/fix jobs (does not cancel ones already started).
