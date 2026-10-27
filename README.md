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
| `plugins/setkernel/` | The org plugin: skills `verify`, `review-blockers`, `ship-pr`; subagents `explorer`, `reviewer`; POSIX-shell hooks: `SessionStart` session context, the opt-in `SessionStart` persona hook, the git guard (`PreToolUse` on Bash, see below), a `PreToolUse` guard that denies remote D1 writes (always on: it has no env switch) and the opt-in `Stop` verify gate. `plugin.json` has no `version`, so every commit on `main` is a release. |
| `rules/org-rules.md` | **The one source of the org rules.** It is also the public page every repo's `AGENTS.md` links to. |
| `managed/settings.base.json` | Hand-edited part of the server-managed settings: the org `permissions.deny` list, the marketplace, the enabled plugin, org-only hooks (`allowManagedHooksOnly`), merging with the VMs' policy file (`managedSourcesBehavior: "merge"`), login, update and retention policy, and the Claude Code telemetry `env` (OTLP to sk-obs01, content redacted; setkernel/hq#90). |
| `managed/settings.json` | Generated. The draft JSON Raghav pastes into the Claude org console (server-managed settings). |
| `bin/generate` | The generator (POSIX sh + `jq`). |
| `policy/versions.json` | **The one source of the org version holds** (Node, TypeScript, PHPCS, …). |
| `plugins/setkernel/policy/holds.md` | Generated. The holds as text; the plugin's SessionStart hook prints it into every Claude session. |
| `bin/dependabot-policy` | Writes the holds into a repo's `.github/dependabot.yml` (`--check` for drift; `crosses` tells whether a version crosses a hold). Python 3, standard library only. |
| `policy/risk.yml` | The merge gate's risk classes (hq#210): which class, R0 to R3, a PR is in each repo, and what each class needs to merge. JSON, which YAML 1.2 also reads. |
| `policy/autonomy.json` | Each person's level, L0 to L4, per repo: the highest class the gate may merge for them there. Anyone or anything not listed is L0. |
| `policy/risk-cases.json` | Cases every implementation of the two files must pass, here and in sk-ctl's gate. |
| `bin/check-policy` | Validates the three files and runs the cases (`tests/run.sh` and CI run it). Python 3, standard library only. |
| `tests/run.sh` | Tests for the generator, the session hook, the verify gate, the D1 guard, the persona hook, `bin/dependabot-policy` and `bin/check-policy`. |

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
git guard covers only the git commands a text rule can't pin down. The other hook, `hooks/d1-guard.sh`, denies remote `wrangler d1 execute` statements that write or change the schema, which permission rules can't match (SQL keywords are case-insensitive and spacing varies). Remote `--file` runs are denied in both places; `d1 migrations apply` is denied only by `permissions.deny`, which matches the `wrangler` and `npx wrangler` prefixes. Unlike the verify gate, the D1 guard has no env switch: once merged it applies to Bash on every seat with the plugin.

## Guardrails, and their limits

- **`permissions.deny`** in the managed settings: force-push, deploy and remote-D1 commands in the
  forms people type (any runner: `npx`, `pnpm`, `yarn`, `bunx`), secret files at any depth with the
  example files left open, home-directory credentials, and edits to shell startup files.
- **The git guard** (`plugins/setkernel/hooks/git-guard.sh`, `PreToolUse` on Bash) splits the
  command line and blocks a force push, a push to the default branch, deleting a remote branch,
  `git reset --hard` and `git clean -f`, however they are spelled (`git -C dir`, `sh -c`, aliases).
  With `SETKERNEL_GUARD_NO_PUSH=1` in the environment (sk-agent's runs) it blocks every push, in
  the spellings hq's `sk-push-guard` blocks too (`git send-pack`, `git subtree push`, an alias set
  in the same command line, a `git` word after any wrapper), and reads quotes and heredocs the way
  the shell does: a commit message, heredoc body or search pattern that only mentions a push
  passes, while `sh -c`, `eval`, `$(…)` and backticks are still read as commands (#43). The
  text that `bash <<<`, `eval`, `sh -c` and `env -S` run is read with its quotes and escapes
  decoded. Like `sk-push-guard`, it doesn't read a push inside another program's code
  (`python3 -c`, `perl -e`, `node -e`).
- **Guards fail closed**: the git guard and the D1 guard carry `"onFailure": "block"` in `hooks.json`
  (Claude Code 2.1.295 or later), so a guard that can't start, crashes, exits other than 0 or 2, or
  times out blocks the Bash call instead of letting it through (setkernel/hq#214, hq#332). A guard
  must therefore exit 0 on input it doesn't care about. The field has no effect on `Stop` hooks, so
  the verify gate doesn't carry it, and the `SessionStart` hooks can't block anything.
- **`allowManagedHooksOnly`**: only hooks from the managed settings and this plugin run, so the
  guard can't be switched off by a repo or user hook, and a repo's own hooks don't run.
  Side effects: it also blocks `/goal`, hooks in agent frontmatter and in a project's settings, and
  narrows `statusLine` to the managed settings. This plugin's hooks still run; a hook from a
  GitHub-sourced mod does not, nor does a user-scope hook such as the VMs' old persona hook (its
  replacement is the plugin's opt-in persona hook, below).
- **Version pin**: `requiredMinimumVersion` 2.1.295 stops an older Claude Code from starting
  (`minimumVersion` only limits updates). `autoUpdatesChannel` is `latest`, because `stable` still
  resolved to 2.1.292, below the minimum. A seat below 2.1.295 has to update by hand once. The
  Homebrew `claude-code` cask tracks stable and ignores `autoUpdatesChannel`, so it can't reach
  2.1.295 until stable does, and a Mac on it stops starting: before pasting the settings, switch
  those Macs to the `claude-code@latest` cask (`brew uninstall --cask claude-code && brew install
  --cask claude-code@latest`). There is no `requiredMaximumVersion` yet: no Claude Code hold
  exists, so Raghav sets one if he wants it.
- **`gh pr merge`, `gh workflow run`, `tofu apply`, `tofu destroy` and `wrangler secret`** are not
  denied here: the console settings bind the humans' Macs and Claude Lead too, and those keep merge
  and dispatch (Raghav, 2026-10-21, hq#332). The denies are VM-only and live in setkernel/hq's
  `agents/vm/managed-settings.d/20-vm.json` (hq#373), which applies alongside these settings because
  of `managedSourcesBehavior: "merge"`.
- **`pnpm deploy*`** is denied, which also blocks pnpm's built-in `pnpm deploy` (copying a workspace
  package, used in Docker builds).
- **To verify that policy reached a seat**, `OTEL_LOG_MANAGED_SETTINGS=1` (set in `env`) makes Claude
  Code log the managed settings it loaded; check that log. A denied command run in a session is the
  second check. This is the way to verify delivery on a VM (hq#314).
- The git guard splits command lines on newlines too, so a multi-line commit message, PR body or
  heredoc with a line that starts `git reset --hard` or `git clean -f` is blocked: reword the line.

### Locks that belong in the VM policy file, not here
The console can't target groups, so anything placed there also binds the humans' Macs. These go in
the VM-only policy file (setkernel/hq#186); `managedSourcesBehavior: "merge"` in these settings makes
both apply (hq#333):
`strictPluginOnlyCustomization: ["hooks","mcp"]`, `crossSessionInbound: "refuse"`, model pinning
(`availableModels`, `availableModelsMatch: "exact"`, `deniedModels`, `maxEffortLevel`), unattended
mode as `--permission-mode auto --permission-prompts none` in place of
`--dangerously-skip-permissions`, and `autoMode.environment` plus a deny on pushing to `main`
(auto mode otherwise allows a push to any branch of the working repo).

### What this guards on a push to `main`, and what it can't
Platform probes (setkernel/hq#220, 2026-10-16 and 10-17; decision 0007's amendment, hq#259) show
that managed deny rules do not guard pushes to `main`, and that Claude's cloud sessions (Anthropic-
hosted and the self-hosted runner) push to `main` as the GitHub user `claude` through the platform's
git proxy, with the creator's access and no branch restriction. So:
- **Guarded here:** a push to the default branch from a local session or agent VM where this plugin's
  hook runs (the git guard) and `permissions.deny` applies. Both are speed bumps (below).
- **Not guarded here:** cloud sessions, and anything that doesn't run this plugin's `PreToolUse`
  hook. Keeping `main` safe there takes GitHub branch protection or rulesets on `main`, which don't
  depend on the client, not this repo. agent-plugins#23 therefore promises no main-branch guard
  beyond the local one.

### Do these settings reach the agent VMs?
Unconfirmed. On 2026-10-20 the VMs' `~/.claude/remote-settings.json` was 0 bytes (2 on one VM) and
none has `/etc/claude-code/managed-settings.json` (setkernel/hq#314). Until that issue shows a
managed deny rule blocking on a VM, assume `managed/settings.json` (deny rules, `allowManagedHooksOnly`,
the version pin) does **not** reach them, and that a VM gets this plugin's hooks only if it installs
the plugin itself. If the cache turns out to be empty, the fix is hq#314's: a login type that
receives managed settings, or installing `managed/settings.json` as
`/etc/claude-code/managed-settings.json`.

These are a speed bump against mistakes, not the security boundary. Bash rules and the guard match
command text, so a script, `/usr/bin/git`, a variable or `python -c` still gets past them, and
`Read` rules don't stop a program that opens the file itself
([Bash rule limits](https://code.claude.com/docs/en/permissions#bash-rule-limits)). The boundary
is the OS sandbox and keeping credentials out of the agent's reach: setkernel/hq#186.

## Merge gate policy

hq#210's gate, in sk-ctl, reads `policy/risk.yml` and `policy/autonomy.json` at a pinned commit of
this repo. A PR's class is the highest any rule in `risk.yml` gives it: R0 for docs and tests, R1 for
a small fix to existing code, R2 for anything bigger, and R3 for every path 0006 and hq#205 keep with
Raghav, plus `policy/**` and every path in agent-plugins, merge-gate, sk-ctl and the estate repos.
The author's level in that repo caps what the gate may merge:

| Level | The gate may merge |
|---|---|
| L0 | nothing; every PR goes to Raghav (anyone or any repo not listed, bots, and Raghav as an author) |
| L1 | R0 |
| L2 | R0 and R1 |
| L3 | R0 to R2 (no repo is above L2 until R2 merges are allowed) |
| L4 | R0 to R3, with R3's approval step |

A change to either file is R3. Edit it, run `bin/check-policy` and `tests/run.sh`, and add a case to
`policy/risk-cases.json` for any rule you change.

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

## The verify gate (Stop hook)

`hooks/verify-gate.sh` keeps a run from finishing while the repo's check fails (setkernel/agent-plugins#31).
It is off unless `SETKERNEL_VERIFY_GATE=1` is set in the session's environment, so it can be
canaried on one VM before it reaches every seat.

- On Stop it runs `make check` (or `SETKERNEL_VERIFY_CMD`) and, while it fails, blocks with the
  failing steps and their last output lines as the reason. No `check` target: nothing to gate.
- It blocks at most `SETKERNEL_VERIFY_GATE_MAX` times (3) in a row, then lets the run stop and
  shows the failure; a green check resets the count.
- It skips read-only runs: plan mode, the `explorer`, `reviewer`, `Explore` and `Plan` agents, and a
  session whose tree (untracked files included) is unchanged since SessionStart. A tree that
  already passed is not checked again.
- State (baseline, last green tree, block count, last log) lives in `CLAUDE_PLUGIN_DATA`.

## The persona hook (SessionStart)

`hooks/persona.sh` loads a seat's persona into the session (setkernel/agent-plugins#37). It is a
port of setkernel/hq's `agents/vm/sk-persona.sh`, a user-scope hook that `allowManagedHooksOnly`
stops once the managed settings are pasted (setkernel/hq#332).
It is off unless `SETKERNEL_PERSONA=1` is set in the session's environment, so a machine that still
runs its own persona hook doesn't load it twice.

- It keys on the git email: only `<name>@setkernel.com`, with a name of lowercase letters, digits
  and `-`. It fetches `agents/personas/<name>.md` from private setkernel/hq with the machine's own
  `gh` login and prints it as `SessionStart` `additionalContext`. Needs `gh` and `jq`.
- **The persona text never enters this repo** (decision 0001): the hook, its tests and this README
  hold none. It is cached owner-only (dir 700, file 600) in `CLAUDE_PLUGIN_DATA/persona`, else
  `${XDG_CACHE_HOME:-~/.cache}/setkernel/persona`, and reused for `SETKERNEL_PERSONA_TTL` minutes
  (360; 0 forces a fetch).
- Anything missing (no opt-in, another domain, no `gh` or `jq`, no access, no such persona, the
  network down with no fresh cache) means no persona: it prints nothing and exits 0.

## Try the plugin locally

```sh
claude --plugin-dir ./plugins/setkernel
```

On a seat with the managed settings, that copy is ignored (`--plugin-dir copy of "setkernel" ignored:
plugin is locked by managed settings` in the debug log) and the published plugin loads instead. Load a
renamed copy:

```sh
d=$(mktemp -d) && cp -R plugins/setkernel "$d/"
jq '.name = "setkernel-try"' plugins/setkernel/.claude-plugin/plugin.json >"$d/setkernel/.claude-plugin/plugin.json"
claude --plugin-dir "$d/setkernel"
```

Or install it from the marketplace: `/plugin marketplace add setkernel/agent-plugins`, then
`/plugin install setkernel@setkernel`. Interactive org seats get it from the server-managed settings.
Headless runs (the dev-VM agents' `claude -p`) don't install it from there: `sk-agent` installs it
itself (setkernel/hq#95). Check a machine with `claude plugin list`.
