# AGENTS.md

What anyone, person or coding agent, needs to know to work in **this** repository.
`CLAUDE.md` only points here. Org-wide rules (tracking work on the board, when to stop and ask,
secrets, branches and commits, the end-of-run report) come from setkernel's central agent setup
(https://github.com/setkernel/hq/blob/main/docs/repo-standard.md); don't repeat them here.

## What this repo is
The centre of setkernel's agent setup: the `setkernel` Claude Code plugin and its marketplace, the
org rules (`rules/org-rules.md`), and the source of the server-managed settings.
Public on purpose so sessions and CI read it without credentials.

## Commands
```sh
# install:  nothing to install; needs POSIX sh, jq, diff (and shellcheck for lint)
# test:     bash tests/run.sh          (SHELL_UNDER_TEST=dash or "busybox sh" to try other shells)
# generate: bin/generate               (rewrites the generated files; commit them with the change)
# lint:     bin/generate --check
#           shellcheck -S warning bin/generate plugins/setkernel/hooks/*.sh tests/run.sh
#           for f in .claude-plugin/marketplace.json plugins/setkernel/.claude-plugin/plugin.json plugins/setkernel/hooks/hooks.json managed/*.json; do jq empty "$f"; done
# plugin:   claude plugin validate .   (the only expected warning is the missing `version`)
# try it:   claude --plugin-dir ./plugins/setkernel
```
CI (`.github/workflows/check.yml`) runs the tests, the drift check, ShellCheck and the JSON check
on every PR and push to `main`.

## Deploy
No deploy workflow. Merging to `main` is the release: `plugin.json` has no `version`, so every
commit on `main` reaches every seat that has the plugin installed, through plugin auto-update. `managed/settings.json` only takes effect when Raghav pastes it into
the Claude org console. No secrets or Infisical values are involved.

## Layout
- `plugins/setkernel/`: the plugin: `skills/` (`verify`, `review-blockers`, `ship-pr`), `agents/`
  (`explorer`, `reviewer`), `hooks/` (POSIX sh: the `SessionStart` context hook, the opt-in `Stop` verify gate and the
  always-on `PreToolUse` D1 guard).
- `.claude-plugin/marketplace.json`: the `setkernel` marketplace; lists the one plugin.
- `rules/org-rules.md`: the one source of the org rules (becomes `claudeMd` in managed settings).
- `managed/settings.base.json`: hand-edited part of the managed settings (`permissions.deny`,
  marketplace, enabled plugin).
- `bin/generate`: builds the generated files below from those sources.
- `bin/dependabot-policy`: writes the version holds into a repo's `dependabot.yml`.
- `tests/run.sh`: tests for the generator, the session hook, the verify gate, the D1 guard and `bin/dependabot-policy`.

## Traps and don't-touch
- Generated, never edit by hand: `managed/settings.json` and `plugins/setkernel/policy/holds.md`.
  Edit the source, run `bin/generate`, commit both.
- This repo is public: no secrets, personal data or personas, ever.
- Hooks and scripts stay POSIX sh: the agent VMs have no Node. `bin/generate` avoids
  `$(cat <<HEREDOC)` because bash 3.2 (macOS `/bin/sh`) mis-parses it when the text holds an
  apostrophe.
- Org-wide denials go in `permissions.deny` in `managed/settings.base.json`, not in hooks. The one exception is
  `hooks/d1-guard.sh` (#18, Raghav's call): rules match literal case-sensitive text and can't see SQL, so remote
  D1 writes are denied by a `PreToolUse` hook. It runs only where the plugin is installed; keep the `d1 migrations
  apply` and `--file` denials in `permissions.deny` too.
- Keep `rules/org-rules.md` to about 40–60 lines: it is loaded into every Claude session.
- Don't add a `version` to `plugin.json`; without it every commit on `main` is a release.
- A change to the plugin hits every seat on merge; test it here first.
