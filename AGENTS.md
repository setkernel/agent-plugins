# AGENTS.md

What anyone, person or coding agent, needs to know to work in **this** repository.
`CLAUDE.md` only points here. Org-wide rules (tracking work on the board, when to stop and ask,
secrets, branches and commits, the end-of-run report) come from setkernel's central agent setup
(https://github.com/setkernel/hq/blob/main/docs/repo-standard.md); don't repeat them here.

## What this repo is
The centre of setkernel's agent setup: the `setkernel` Claude Code plugin and its marketplace, the
org rules (`rules/org-rules.md`), the source of the server-managed settings, and the repo checker
other repos' CI fetches. Public on purpose so sessions and CI read it without credentials.

## Commands
```sh
# install:  nothing to install; needs POSIX sh, jq, diff (and shellcheck for lint)
# test:     bash tests/run.sh          (SHELL_UNDER_TEST=dash or "busybox sh" to try other shells)
# generate: bin/generate               (rewrites the generated files; commit them with the change)
# lint:     bin/generate --check
#           shellcheck -S warning bin/generate check/check.sh plugins/setkernel/hooks/*.sh tests/run.sh
#           for f in .claude-plugin/marketplace.json plugins/setkernel/.claude-plugin/plugin.json plugins/setkernel/hooks/hooks.json managed/*.json; do jq empty "$f"; done
# plugin:   claude plugin validate .   (the only expected warning is the missing `version`)
# try it:   claude --plugin-dir ./plugins/setkernel
```
CI (`.github/workflows/check.yml`) runs the tests, the drift check, ShellCheck and the JSON check
on every PR and push to `main`.

## Deploy
No deploy workflow. Merging to `main` is the release: `plugin.json` has no `version`, so every
commit on `main` reaches every seat through plugin auto-update, and every repo's CI fetches
`check/check.sh` from `main`. `managed/settings.json` only takes effect when Raghav pastes it into
the Claude org console. No secrets or Infisical values are involved.

## Layout
- `plugins/setkernel/`: the plugin: `skills/` (`verify`, `review-blockers`, `ship-pr`), `agents/`
  (`explorer`, `reviewer`), `hooks/` (the POSIX-sh `SessionStart` hook).
- `.claude-plugin/marketplace.json`: the `setkernel` marketplace; lists the one plugin.
- `rules/org-rules.md`: the one source of the org rules (becomes `claudeMd` in managed settings).
- `managed/settings.base.json`: hand-edited part of the managed settings (`permissions.deny`,
  marketplace, enabled plugin).
- `bin/generate`: builds the generated files below from those sources.
- `check/check.sh`: the repo checker; `tests/run.sh`: tests for it and the generator.

## Traps and don't-touch
- Generated, never edit by hand: `managed/settings.json`, `rules/agents-pointer.md`, and the
  region of `check/check.sh` between the `>>> generated` / `<<< generated` markers. Edit the
  source, run `bin/generate`, commit both.
- This repo is public: no secrets, personal data or personas, ever.
- Hooks and scripts stay POSIX sh: the agent VMs have no Node. `bin/generate` avoids
  `$(cat <<HEREDOC)` because bash 3.2 (macOS `/bin/sh`) mis-parses it when the text holds an
  apostrophe.
- Org-wide denials go in `permissions.deny` in `managed/settings.base.json`, not in hooks.
- Keep `rules/org-rules.md` to about 40–60 lines: it is loaded into every Claude session.
- Don't add a `version` to `plugin.json`; without it every commit on `main` is a release.
- A change to `check/check.sh` or the plugin hits every repo and seat on merge; test it here first.
