# setkernel agent-plugins

The org-wide layer for setkernel's AI agents. Public on purpose, so cloud sessions and every
repo's CI can read it without credentials. **Never put secrets, personal data or personas here.**

- `.claude-plugin/marketplace.json` + `plugins/setkernel/`: the org plugin (shared skills, subagents,
  shell-only hooks), enabled for every Claude Team seat through server-managed settings.
- The org rules: one source that generates both the `claudeMd` server setting and the short pointer
  block at the top of every repo's `AGENTS.md` (for Codex, Antigravity, Copilot, Cursor).
- A small checker that each repo's CI fetches to confirm it follows the standard.

Plan and decisions: [setkernel/hq PR #41](https://github.com/setkernel/hq/pull/41) (discussion
setkernel/hq#40). Releases ship from `main`; every merge needs Raghav's code-owner approval.
