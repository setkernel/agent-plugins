# setkernel agent-plugins

The org-wide layer for setkernel's AI agents. Public on purpose, so sessions and CI can read it
without credentials. **Never put secrets, personal data or personas here.**

Plan and decisions: [setkernel/hq PR #41](https://github.com/setkernel/hq/pull/41) (discussion
setkernel/hq#40); its "Amendments accepted by Raghav" section overrides the rest. Releases ship
from `main`; every merge needs Raghav's code-owner approval.

## What is here

| Path | What it is |
| --- | --- |
| `.claude-plugin/marketplace.json` | The `setkernel` marketplace. It lists one plugin. |
| `plugins/setkernel/` | The org plugin: skills `verify`, `review-blockers`, `ship-pr`; subagents `explorer`, `reviewer`; POSIX-shell hooks: `SessionStart` (session context) and the git guard (`PreToolUse` on Bash, see below). `plugin.json` has no `version`, so every commit on `main` is a release. |
| `rules/org-rules.md` | **The one source of the org rules.** It is also the public page every repo's `AGENTS.md` links to. |
| `managed/settings.base.json` | Hand-edited part of the server-managed settings: the org `permissions.deny` list, the marketplace and the only marketplace source allowed (`strictKnownMarketplaces`), the enabled plugin, org-only hooks (`allowManagedHooksOnly`), login, update and retention policy, and the Claude Code telemetry `env` (OTLP to sk-obs01, content redacted; setkernel/hq#90). |
| `managed/settings.json` | Generated. The draft JSON Raghav pastes into the Claude org console (server-managed settings). |
| `bin/generate` | The generator (POSIX sh + `jq`). |
| `policy/versions.json` | **The one source of the org version holds** (Node, TypeScript, PHPCS, …). |
| `plugins/setkernel/policy/holds.md` | Generated. The holds as text; the plugin's SessionStart hook prints it into every Claude session. |
| `bin/dependabot-policy` | Writes the holds into a repo's `.github/dependabot.yml` (`--check` for drift; `crosses` tells whether a version crosses a hold). Python 3, standard library only. |
| `tests/run.sh` | Tests for the generator, the session hook and `bin/dependabot-policy`. |

In Claude Code the plugin's components are namespaced: `/setkernel:verify`, `setkernel:reviewer`.

## Change the org rules, the deny list or the plugin

1. Edit `rules/org-rules.md` (keep it about 40–60 lines: it is loaded into every Claude session),
   `managed/settings.base.json`, or the files under `plugins/setkernel/`.
2. Run `bin/generate`, then `tests/run.sh`. Commit the generated files with the change;
   `bin/generate --check` must print "generated files are current".
3. Validate the plugin: `claude plugin validate .` (the only expected warning is the missing
   `version`, which is deliberate).
4. After merge, plugin changes reach every seat through auto-update. A change to
   `managed/settings.json` only takes effect when Raghav pastes it into the org console.

Hooks stay POSIX shell: the agent VMs have no Node. Org-wide denials go in `permissions.deny`; the
git guard covers only the git commands a text rule can't pin down.

## Guardrails, and their limits

- **`permissions.deny`** in the managed settings: force-push, deploy and remote-D1 commands in the
  forms people type (any runner: `npx`, `pnpm`, `yarn`, `bunx`), secret files at any depth with the
  example files left open, home-directory credentials, and edits to shell startup files.
- **The git guard** (`plugins/setkernel/hooks/git-guard.sh`, `PreToolUse` on Bash) splits the
  command line and blocks a force push, a push to the default branch, deleting a remote branch,
  `git reset --hard` and `git clean -f`, however they are spelled (`git -C dir`, `sh -c`, aliases).
  With `SETKERNEL_GUARD_NO_PUSH=1` in the environment (sk-agent's runs) it blocks every push.
- **`allowManagedHooksOnly`**: only hooks from the managed settings and this plugin run, so the
  guard can't be switched off by a repo or user hook, and a repo's own hooks don't run.

These are a speed bump against mistakes, not the security boundary. Bash rules and the guard match
command text, so a script, `/usr/bin/git`, a variable or `python -c` still gets past them, and
`Read` rules don't stop a program that opens the file itself
([Bash rule limits](https://code.claude.com/docs/en/permissions#bash-rule-limits)). The boundary
is the OS sandbox and keeping credentials out of the agent's reach: setkernel/hq#186.

## Version holds

Some versions are held back org-wide until Raghav has tested the next one: Node and `@types/node`
stay on 24 until Node 26 is LTS, TypeScript stays on 6.0.x while Svelte, Astro and typescript-eslint
reject 7, PHPCS stays on 3.x for WPCS. Each hold in `policy/versions.json` says what is held, why
(with evidence), what lifts it, and the Dependabot `ignore` entries per ecosystem. Repo-specific pins
(for example an Expo-pinned set) stay in that repo's own config. Plan: setkernel/hq#87.

How a hold reaches everyone:
- **Agents**: `bin/generate` renders `plugins/setkernel/policy/holds.md`, which the SessionStart
  hook prints into every session. The plugin auto-updates from `main`, so a merged change shows up
  in the next session with nothing to paste. The org rules carry a short "Version holds" section.
- **Dependabot**, which can't read a shared file: `bin/dependabot-policy` writes a marked block at
  the top of each `updates` entry's `ignore:` list, keeping the repo's own entries below it. hq's
  `version-policy` workflow finds repos whose block is missing or stale and opens an `agent-ready`
  issue in each, listing open Dependabot PRs that cross a hold so the agent closes them.

Add, change or lift a hold:
1. Raghav tests the new version (or the reason for a new hold is verified).
2. Edit `policy/versions.json`, run `bin/generate` and `tests/run.sh`, open a PR; Raghav merges.
3. Sessions show the new holds; the next `version-policy` run opens issues to update every
   `dependabot.yml`. After a lift, Dependabot opens the upgrade PRs and agents make them pass.

Apply to a repository by hand:

```sh
python3 bin/dependabot-policy --check /path/to/repo   # exit 1 and a diff when stale
python3 bin/dependabot-policy /path/to/repo           # write it
python3 bin/dependabot-policy crosses npm typescript 7.0.2   # prints typescript-6.0, exit 0
```

## Try the plugin locally

```sh
claude --plugin-dir ./plugins/setkernel
```

Or install it from the marketplace: `/plugin marketplace add setkernel/agent-plugins`, then
`/plugin install setkernel@setkernel`. Interactive org seats get it from the server-managed settings.
Headless runs (the dev-VM agents' `claude -p`) don't install it from there: `sk-agent` installs it
itself (setkernel/hq#95). Check a machine with `claude plugin list`.
