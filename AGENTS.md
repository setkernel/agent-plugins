# AGENTS.md

What anyone, person or coding agent, needs to know to work in **this** repository.
`CLAUDE.md` only points here. Org-wide rules (tracking work on the board, when to stop and ask,
secrets, branches and commits, the end-of-run report) come from setkernel's central agent setup
(https://github.com/setkernel/hq/blob/main/docs/repo-standard.md); don't repeat them here.

## What this repo is
The centre of setkernel's agent setup: the `setkernel` Claude Code plugin and its marketplace, the
org rules (`rules/org-rules.md`), the source of the server-managed settings, and the merge gate's
policy (`policy/risk.yml`, `policy/autonomy.json`).
Public on purpose so sessions and CI read it without credentials.

## Commands
```sh
# install:  nothing to install; needs POSIX sh, jq, diff (and shellcheck for lint)
# test:     bash tests/run.sh          (SHELL_UNDER_TEST=dash or "busybox sh" to try other shells)
# generate: bin/generate               (rewrites the generated files; commit them with the change)
# policy:   bin/check-policy           (validates policy/risk.yml, autonomy.json and risk-cases.json)
# lint:     bin/generate --check
#           shellcheck -S warning bin/generate plugins/setkernel/hooks/*.sh tests/run.sh
#           for f in .claude-plugin/marketplace.json plugins/setkernel/.claude-plugin/plugin.json plugins/setkernel/hooks/hooks.json managed/*.json policy/*.json policy/risk.yml; do jq empty "$f"; done
# plugin:   claude plugin validate .   (the only expected warning is the missing `version`)
# try it:   a renamed copy (managed seats ignore --plugin-dir ./plugins/setkernel: the plugin is locked)
#           d=$(mktemp -d) && cp -R plugins/setkernel "$d/" && jq '.name = "setkernel-try"' plugins/setkernel/.claude-plugin/plugin.json >"$d/setkernel/.claude-plugin/plugin.json" && claude --plugin-dir "$d/setkernel"
```
CI (`.github/workflows/check.yml`) runs the tests, the drift check, `bin/check-policy`, ShellCheck and
the JSON check on every PR and push to `main`.

## Deploy
No deploy workflow. Merging to `main` is the release: `plugin.json` has no `version`, so every
commit on `main` reaches every seat that has the plugin installed, through plugin auto-update. `managed/settings.json` only takes effect when Raghav pastes it into
the Claude org console. No secrets or Infisical values are involved.

## Layout
- `plugins/setkernel/`: the plugin: `skills/` (`verify`, `review-blockers`, `ship-pr`), `agents/`
  (`explorer`, `reviewer`), `hooks/` (POSIX sh: the `SessionStart` context hook, `git-guard.sh`, the
  `PreToolUse` git guard, `d1-guard.sh`, the always-on `PreToolUse` D1 guard, the opt-in `Stop`
  verify gate, and the opt-in `persona.sh` `SessionStart` hook).
- `.claude-plugin/marketplace.json`: the `setkernel` marketplace; lists the one plugin.
- `rules/org-rules.md`: the one source of the org rules (becomes `claudeMd` in managed settings).
- `managed/settings.base.json`: hand-edited part of the managed settings (`permissions.deny`,
  marketplace, enabled plugin).
- `bin/generate`: builds the generated files below from those sources.
- `bin/dependabot-policy`: writes the version holds into a repo's `dependabot.yml`.
- `policy/versions.json`: the org version holds.
- `policy/risk.yml`: which risk class (R0 to R3) a PR is, per repo, and each class's quorum (hq#210).
  `policy/autonomy.json`: each person's level (L0 to L4) per repo, which caps the class the gate may
  merge. `policy/risk-cases.json`: cases every implementation must pass. hq#210's gate in sk-ctl
  reads all three at a pinned commit of this repo; the comment at the top of each file says what it holds.
- `bin/check-policy`: validates those three files and runs the cases with a reference matcher
  (Python 3 standard library, like `bin/dependabot-policy`).
- `tests/run.sh`: tests for the generator, the session hook, the verify gate, the D1 guard, the
  persona hook, `bin/dependabot-policy` and `bin/check-policy`.

## Traps and don't-touch
- Generated, never edit by hand: `managed/settings.json` and `plugins/setkernel/policy/holds.md`.
  Edit the source, run `bin/generate`, commit both.
- This repo is public: no secrets, personal data or personas, ever. `persona.sh` fetches persona
  text from private hq at session start; its tests use made-up text.
- Hooks and scripts stay POSIX sh: the agent VMs have no Node. `bin/generate` avoids
  `$(cat <<HEREDOC)` because bash 3.2 (macOS `/bin/sh`) mis-parses it when the text holds an
  apostrophe.
- Org-wide denials go in `permissions.deny` in `managed/settings.base.json`. The git guard hook
  covers only git commands a text rule can't match; both are a speed bump, not a boundary (README).
  The other hook exception is `hooks/d1-guard.sh` (#18, Raghav's call): rules match literal case-sensitive text and can't
  see SQL, so remote D1 writes are denied by a `PreToolUse` hook. It has no env switch, so it applies to Bash on
  every seat with the plugin; keep the `d1 migrations apply` and `--file` denials in `permissions.deny` too.
  Denials only the agent VMs need (`gh pr merge`, `gh workflow run`, `tofu apply`/`destroy`, `wrangler secret`)
  go in setkernel/hq's `agents/vm/managed-settings.d/20-vm.json` instead (hq#373): the console binds the Macs too.
- The `PreToolUse` guards carry `"onFailure": "block"`: any exit but 0 (allow) or 2 (block) blocks every Bash
  call, so a guard must exit 0 on input it doesn't care about (`tests/run.sh` checks it).
- `allowManagedHooksOnly` is on: only managed and this plugin's hooks run, so a hook belongs here.
- `forceLoginOrgUUID` in `managed/settings.base.json` is the setkernel Team org ID, which Claude Lead
  committed (agent-plugins#36). An agent never changes it. If it is ever a `REPLACE_WITH_` placeholder,
  `bin/generate` leaves the key out of `managed/settings.json` (pasted, no login would match it) and prints a note.
- A change to `policy/risk.yml` or `policy/autonomy.json` is R3 (hq#210), whatever else the PR holds.
  - `risk.yml` is JSON, which YAML 1.2 also reads, so neither the VMs nor the Worker needs a YAML parser.
    `bin/check-policy` refuses anything `jq` can't parse.
  - `bin/check-policy` holds copies of 0006's floor, hq#205's global deny, never lists and
    required checks (hq `de93ba3`). The policy may add to them, never drop from them.
  - No level goes above L2 until R2 merges are allowed (P4). A test pins that.
  - An autonomy entry above L0 installs nothing: setkernel-merge goes on a repo only by Raghav's step.
- The policy leaves out 0006's E4 and E5 (hq#209 decision 6: setkernel-merge has none of
  Administration, Deployments, Environments or Commit statuses, and hq#343's `/verify?sha=` takes over
  E5's purpose). What that drops:
  - E4 kept out a repo that adds a deploy-on-push workflow. devpause plans one; on 2026-10-27 it has only
    `check.yml`. Now the only stop is that workflow's own PR, which is R3 because `.github/**` is on
    0006's floor.
  - E5 failed keelpost on its three `freeplan-probe` Deployments. They are still there (2026-10-27), and
    nothing checks them now.
- Keep `rules/org-rules.md` to about 40–60 lines: it is loaded into every Claude session.
- Don't add a `version` to `plugin.json`; without it every commit on `main` is a release.
- A change to the plugin hits every seat on merge; test it here first.
