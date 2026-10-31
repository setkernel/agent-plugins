#!/bin/sh
# Tests for bin/generate, the session hook, the verify gate, the D1 guard, the persona hook and bin/dependabot-policy. POSIX sh; needs jq for the generator tests.
# Usage: tests/run.sh            (set SHELL_UNDER_TEST=dash or "busybox sh" to try other shells)
set -eu

# sk-agent runs export SETKERNEL_GUARD_NO_PUSH=1; the guard tests must not inherit it (hook_on sets it where wanted).
unset SETKERNEL_GUARD_NO_PUSH

root=$(cd "$(dirname "$0")/.." && pwd)
sh_cmd=${SHELL_UNDER_TEST:-sh}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
failures=0
n=0

# expect <exit-code> <output-pattern> <description> -- <command...>
expect() {
  want=$1 pattern=$2 desc=$3
  shift 4
  n=$((n + 1))
  set +e
  out=$("$@" 2>&1)
  got=$?
  set -e
  if [ "$got" -ne "$want" ] || ! printf '%s\n' "$out" | grep -q -- "$pattern"; then
    echo "not ok $n - $desc (exit $got, want $want; output must match: $pattern)"
    printf '%s\n' "$out" | sed 's/^/    /'
    failures=$((failures + 1))
  else
    echo "ok $n - $desc"
  fi
}

run_sh() {
  # shellcheck disable=SC2086 # sh_cmd may be "busybox sh"
  $sh_cmd "$@"
}
# The generator: the committed files are current, and drift is detected.
expect 0 "generated files are current" "committed generated files are current" -- run_sh "$root/bin/generate" --check
cp -R "$root" "$tmp/copy"
rm -rf "$tmp/copy/.git"
printf '\nOne more rule.\n' >>"$tmp/copy/rules/org-rules.md"
expect 1 "stale: managed/settings.json" "a rules edit without regenerating is drift" -- run_sh "$tmp/copy/bin/generate" --check
expect 0 "wrote managed/settings.json" "regenerating writes the settings" -- run_sh "$tmp/copy/bin/generate"
expect 0 "generated files are current" "after regenerating there is no drift" -- run_sh "$tmp/copy/bin/generate" --check
expect 0 "One more rule.\"" "claudeMd carries the new rule" -- jq .claudeMd "$tmp/copy/managed/settings.json"
# A forceLoginOrgUUID placeholder never reaches the pasted file; a filled-in UUID does.
expect 1 "" "managed/settings.json holds no REPLACE_WITH_ placeholder" -- grep -q REPLACE_WITH_ "$root/managed/settings.json"
jq '.forceLoginOrgUUID = "00000000-0000-0000-0000-000000000000"' "$root/managed/settings.base.json" >"$tmp/copy/managed/settings.base.json"
expect 0 "wrote managed/settings.json" "a filled-in org UUID regenerates the settings" -- run_sh "$tmp/copy/bin/generate"
expect 0 "00000000-0000-0000-0000-000000000000" "the filled-in org UUID is in the settings" -- jq -r .forceLoginOrgUUID "$tmp/copy/managed/settings.json"

# The committed org rules give each Claude environment its branch prefix and signature (#16).
for marker in '`raghav-dev/<topic>`, `— raghav-dev`' '`claude/<topic>`, `— Claude Cloud`' '`lead/<topic>`, `— Claude Lead`' '`agent/<issue>-<slug>`'; do
  expect 0 "$marker" "claudeMd's Who did it names $marker" -- jq -r .claudeMd "$root/managed/settings.json"
done

# The committed org rules carry the self-hosted Google Fonts rule (#20).
for marker in '## Fonts' 'self-hosted' '`fonts.googleapis.com`' '`FONTCONFIG_FILE`' 'Arimo for Arial'; do
  expect 0 "$marker" "claudeMd's Fonts names $marker" -- jq -r .claudeMd "$root/managed/settings.json"
done

# Native Apple apps are exempt from the Fonts rule.
expect 0 "setkernel/CardinalApp" "claudeMd exempts CardinalApp from the Fonts rule" -- jq -r .claudeMd "$root/managed/settings.json"

# The version pin and console locks from the #23 research amendments.
settings_key() { jq -e "$1" "$root/managed/settings.json"; }
expect 0 '"2.1.295"' "requiredMinimumVersion pins 2.1.295" -- settings_key .requiredMinimumVersion
expect 1 "" "the update-only minimumVersion is gone" -- settings_key 'has("minimumVersion")'
expect 0 '"latest"' "the update channel can reach the required minimum" -- settings_key .autoUpdatesChannel
expect 0 "true" "claude.ai skills do not sync" -- settings_key ".syncClaudeAiSkills == false"
expect 0 "true" "claude.ai plugins do not sync" -- settings_key ".syncClaudeAiPlugins == false"
expect 1 "" "allowManagedModsOnly is left out for now (hq#212)" -- settings_key '[.. | objects | has("allowManagedModsOnly")] | any'
expect 0 '"1"' "managed settings are logged to OTEL" -- settings_key .env.OTEL_LOG_MANAGED_SETTINGS
# The merge, dispatch, tofu and wrangler secret denies are VM-only: they live in hq's
# agents/vm/managed-settings.d/20-vm.json (hq#373), so the console settings leave every form of them out.
for c in "gh pr merge" "tofu apply" "tofu destroy" "gh workflow run" "wrangler secret"; do
  re=$(printf '%s' "$c" | sed 's/ /.*/g')
  expect 0 "true" "$c is not denied here (VM-only)" -- settings_key "[.permissions.deny[] | select(test(\"$re\"))] == []"
done
# The console settings merge with the VMs' policy file (hq#333), and leave strictKnownMarketplaces out (hq#332);
# the marketplace and the enabled plugin stay.
expect 0 '"merge"' "managedSourcesBehavior is merge" -- settings_key .managedSourcesBehavior
expect 1 "" "strictKnownMarketplaces is left out" -- settings_key 'has("strictKnownMarketplaces")'
expect 0 "true" "the setkernel marketplace and plugin stay" -- \
  settings_key '.extraKnownMarketplaces.setkernel.source.repo == "setkernel/agent-plugins" and .enabledPlugins["setkernel@setkernel"] == true'

# The org rules load into every session: keep them to the README's 40–60 lines (#23).
expect 0 "" "the org rules stay within 60 lines" -- test "$(wc -l <"$root/rules/org-rules.md")" -le 60
# The committed org rules carry the v4 merge quorum in place of "every PR needs Raghav's review" (#25).
for marker in "in force as each repo's gate is qualified" 'R0: one non-author' 'R1: two non-author approvals' \
  'R2: two approvals and a visual diff' 'R3 (secrets, auth, money, DNS and tofu' 'R2 plus Raghav'"'"'s `/approve <sha>`' \
  'never merge your$' 'only the merge App merges' 'never counts as a Claude reviewer' 'decision 0007'; do
  expect 0 "$marker" "claudeMd's Changes names $marker" -- jq -r .claudeMd "$root/managed/settings.json"
done
expect 1 '^0$' "claudeMd drops the old review-before-merge rule" -- \
  sh -c "jq -r .claudeMd '$root/managed/settings.json' | grep -c 'review before merge'"
# Decision 0008, the allow-test-changes rule and the account rules (#36), and its no-ticking exception (#52).
for marker in 'Every secret lives in Infisical' 'named with its reason (decision 0008)' 'No paid App is ever installed' \
  'A revert is a new forward commit' "made only on Raghav's word" '`allow-test-changes: <reason>`' \
  'Only Raghav$' 'never add, edit or remove it' '(vega-, rigel-, lyra-, orion-setkernel) is a real person' \
  'only they and their own agent use it' "acts on Raghav's login, so it never posts \`/approve <sha>\` or an APPROVE review" \
  'only comment progress: any body edit, a tick too, voids it' \
  'Claude Lead may merge a PR an agent seat (vega-, rigel-, lyra-, orion-setkernel) authored' \
  "no review requests changes, Raghav hasn't objected" "decision 0007's \"Still Raghav's\" list" \
  'new or raised dependencies and version holds' 'a PR needing an allow-test-changes line' 'anything you'"'"'re unsure of'; do
  expect 0 "$marker" "claudeMd names $marker" -- jq -r .claudeMd "$root/managed/settings.json"
done
expect 1 '^0$' "claudeMd drops Cloudflare or the vault as the home of secrets" -- \
  sh -c "jq -r .claudeMd '$root/managed/settings.json' | grep -c 'Cloudflare or the vault'"

expect 1 "stale: plugins/setkernel/policy/holds.md" "a policy edit without regenerating is drift" -- \
  sh -c "jq '.holds[0].summary = \"changed\"' '$tmp/copy/policy/versions.json' >'$tmp/v.json' && mv '$tmp/v.json' '$tmp/copy/policy/versions.json' && sh '$tmp/copy/bin/generate' --check"

# The managed deny list: a secret closed to Read is closed to Edit too, a wrangler denial covers
# `npx wrangler` as well, and the example files stay open (a `!` rule carves only from rules before it).
deny_jq() { jq -er "(.permissions.deny) as \$d | $1" "$root/managed/settings.json"; }
missing='if . == [] then "none missing" else ("missing: " + join(", ")), false end'
expect 0 "none missing" "every Read denial has an Edit twin" -- \
  deny_jq "[\$d[] | select(startswith(\"Read(\")) | \"Edit(\" + .[5:]] - \$d | $missing"
expect 0 "none missing" "remote D1 migrations and remote --file runs are denied" -- \
  deny_jq "[\"Bash(wrangler d1 migrations apply:*)\", \"Bash(wrangler d1 execute *--remote*--file*)\", \"Bash(wrangler d1 execute *--file*--remote*)\"] - \$d | $missing"
expect 0 "none missing" "force-push is denied in every spelling, with the flag first or after the remote, and as +refspec" -- \
  deny_jq "[\"Bash(git push --force*)\", \"Bash(git push * --force*)\", \"Bash(git push -f*)\", \"Bash(git push * -f*)\", \"Bash(git push -uf*)\", \"Bash(git push * -uf*)\", \"Bash(git push * +*)\"] - \$d | $missing"
expect 0 "^0$" "the old force-push rules (blind to --force-with-lease) are gone" -- \
  deny_jq "[\$d[] | select(. == \"Bash(git push --force:*)\" or . == \"Bash(git push -f:*)\")] | length"
expect 0 "none missing" "git reset --hard and git clean are denied" -- \
  deny_jq "[\"Bash(git reset --hard*)\", \"Bash(git reset * --hard*)\", \"Bash(git clean:*)\"] - \$d | $missing"
expect 0 "none missing" "forced branch deletes are denied in every spelling" -- \
  deny_jq "[\"Bash(git branch -D:*)\", \"Bash(git branch * -D*)\", \"Bash(git branch --delete*--force*)\", \"Bash(git branch --force*--delete*)\", \"Bash(git branch -d -f*)\", \"Bash(git branch -f -d*)\", \"Bash(git branch -fd*)\", \"Bash(git branch -df*)\"] - \$d | $missing"
expect 0 "^0$" "the safe git branch -d stays open" -- \
  deny_jq "[\$d[] | select(startswith(\"Bash(git branch -d\") and (startswith(\"Bash(git branch -d -f\") or startswith(\"Bash(git branch -df\") | not))] | length"
expect 0 "none missing" "npm publish and gh release create are denied" -- \
  deny_jq "[\"Bash(npm publish:*)\", \"Bash(gh release create:*)\"] - \$d | $missing"
expect 0 "none missing" "every wrangler denial covers any runner (npx, pnpm, yarn, bunx) too" -- \
  deny_jq "[\$d[] | select(startswith(\"Bash(wrangler \") and endswith(\":*)\")) | .[5:-1] | sub(\":\\\\*\$\"; \"\") | \"Bash(* \" + . + \")\", \"Bash(* \" + . + \" *)\"] - \$d | $missing"
expect 0 "none missing" ".dev.vars.* is denied and the example files are carved out" -- \
  deny_jq "[\"Read(**/.dev.vars.*)\", \"Read(!.env.example)\", \"Read(!.dev.vars.example)\"] - \$d | $missing"
expect 0 "none missing" "home-directory credentials are denied, and shell startup files closed to edits" -- \
  deny_jq "[\"~/.ssh/**\", \"~/.config/sk-agent/**\", \"~/.claude/.credentials.json\", \"~/.git-credentials\", \"~/.npmrc\", \"~/.docker/config.json\"]
    | map(\"Read(\" + . + \")\") + [\"Edit(~/.bashrc)\", \"Edit(~/.zshrc)\", \"Edit(~/.profile)\"] - \$d | $missing"

# Bash deny rules, matched the way Claude Code reads them (permissions doc, "Wildcard patterns"):
# `*` is any text, `:*` at the end is ` *`, and a trailing ` *` as the only `*` also matches the
# bare command. bash_denied <command> prints the rule that denies it, or "allowed" and exits 1.
bash_rules=$(jq -r '.permissions.deny[] | select(startswith("Bash(")) | .[5:-1]' "$root/managed/settings.json")
bash_denied() {
  set -f
  old_ifs=$IFS
  IFS='
'
  for rule in $bash_rules; do
    pat=$rule
    case $pat in *:\*) pat="${pat%:\*} *" ;; esac
    bare=
    case $pat in *" *") case ${pat% \*} in *\**) ;; *) bare=${pat% \*} ;; esac ;; esac
    # shellcheck disable=SC2254 # the rule is the pattern
    case $1 in $pat) IFS=$old_ifs; set +f; echo "denied by $rule"; return 0 ;; esac
    if [ -n "$bare" ] && [ "$1" = "$bare" ]; then IFS=$old_ifs; set +f; echo "denied by $rule"; return 0; fi
  done
  IFS=$old_ifs
  set +f
  echo allowed
  return 1
}
while IFS= read -r c; do
  expect 0 "denied by" "deny: $c" -- bash_denied "$c"
done <<'EOF'
git push --force origin feat
git push -f
git push --force-with-lease
git push --force-with-lease=feat:abc123 origin feat
git push origin main --force
git push origin feat -f
git push origin +main
git -C /srv/repo push -f
git -C . push origin feat --force-with-lease
git -c push.default=current push +HEAD
wrangler deploy
npx wrangler deploy
npx --yes wrangler deploy --env production
pnpm wrangler deploy
pnpm exec wrangler deploy
yarn wrangler deploy
bunx wrangler deploy
wrangler versions deploy
npx wrangler versions deploy --yes
wrangler pages deploy dist
pnpm dlx wrangler pages deploy ./dist
npm run deploy
npm run deploy:prod
pnpm deploy
pnpm run deploy
yarn deploy
bun run deploy
wrangler d1 migrations apply DB --remote
pnpm wrangler d1 migrations apply DB
npx wrangler d1 execute DB --remote --file seed.sql
pnpm wrangler d1 execute DB --file=seed.sql --remote
EOF
while IFS= read -r c; do
  expect 1 "allowed" "allow: $c" -- bash_denied "$c"
done <<'EOF'
git push
git push origin feat
git push -u origin agent/23-harden-fix
git push origin my-feature-fix --follow-tags
git status
git commit -m "fix: force the lease"
tofu plan
tofu -chdir=infra plan
tofu apply
tofu -chdir=infra apply
tofu -chdir=infra destroy -auto-approve
gh workflow list
gh workflow run x.yml
gh -R o/r workflow run x.yml
gh pr merge 36 --squash
npx wrangler secret put X
wrangler dev
wrangler deployments list
npx wrangler d1 execute DB --local --file seed.sql
npm run build
pnpm install
EOF

# Read and Edit rules use gitignore syntax (permissions doc, "Read and Edit"), so git check-ignore
# stands in for the matcher: project rules depth-independent with the example files open, home
# rules matched from the home directory with ~/.config/gh left open for the agents.
gi=$tmp/gitignore
mkdir -p "$gi/project" "$gi/home" && git -C "$gi/project" init -q && git -C "$gi/home" init -q
jq -r '.permissions.deny[] | select(startswith("Read(")) | .[5:-1] | select(startswith("~/") or startswith("//") | not) | sub("^\\./"; "")' \
  "$root/managed/settings.json" >"$gi/project/.gitignore"
jq -r '.permissions.deny[] | select(startswith("Read(~/")) | .[7:-1]' "$root/managed/settings.json" >"$gi/home/.gitignore"
for p in .env apps/api/.env .env.production apps/web/.env.local .dev.vars workers/x/.dev.vars.staging certs/site.pem keys/AuthKey.p8 deep/id_ed25519; do
  expect 0 "" "Read denies $p" -- git -C "$gi/project" check-ignore -q --no-index "$p"
done
for p in .env.example apps/api/.env.example .dev.vars.example workers/x/.dev.vars.example src/env.ts README.md; do
  expect 1 "" "Read allows $p" -- git -C "$gi/project" check-ignore -q --no-index "$p"
done
for p in .ssh/id_ed25519 .ssh/config .config/sk-agent/env .claude/.credentials.json .git-credentials .npmrc .docker/config.json; do
  expect 0 "" "Read denies ~/$p" -- git -C "$gi/home" check-ignore -q --no-index "$p"
done
for p in .config/gh/hosts.yml .claude/settings.json .bashrc .gitconfig; do
  expect 1 "" "Read allows ~/$p" -- git -C "$gi/home" check-ignore -q --no-index "$p"
done
expect 0 "none missing" "keys and certificates are denied at any depth" -- \
  deny_jq "[\"*.pem\", \"*.key\", \"*.p8\", \"*.p12\", \"*.jks\", \"*.keystore\", \"*.mobileprovision\", \"id_rsa\", \"id_ed25519\"] | map(\"Read(**/\" + . + \")\") - \$d | $missing"
expect 0 "carve-outs last" "each carve-out follows the denials it opens" -- \
  deny_jq '[$d | to_entries[] | select(.value | test("^(Read|Edit)\\(")) | {key, carve: (.value | test("^(Read|Edit)\\(!"))}]
    | ([.[] | select(.carve) | .key] | min) as $first | ([.[] | select(.carve | not) | .key] | max) as $last
    | if $first > $last then "carve-outs last" else "a carve-out at \($first) comes before a denial at \($last)", false end'

# The reviewer blocks PR bodies that ask the owner to hand-create tokens or paste secrets (#27).
# A static check: the prompt names the triggers and pointers, the bad fixture hits a trigger, the good one hits none.
reviewer=$root/plugins/setkernel/agents/reviewer.md
for marker in 'create an API token' 'paste a value into Infisical' 'dashboard → API Tokens' 'Credentials for a repo' \
  'scripts/infisical-repo-projects.py' 'scripts/infisical-put.py' 'stacks/services/api_tokens.tf' 'gh pr view'; do
  expect 0 "$marker" "the reviewer prompt names $marker" -- cat "$reviewer"
done
expect 0 "gh pr view" "review-blockers passes the PR body to the reviewer" -- cat "$root/plugins/setkernel/skills/review-blockers/SKILL.md"
ask='create an? (Cloudflare )?API token|paste.* into Infisical|dashboard → API Tokens'
expect 0 "API Tokens" "the bad fixture asks the owner to create and paste a token" -- grep -E "$ask" "$root/tests/fixtures/pr-bad.md"
expect 1 "" "the good fixture (token as code, piped by script) triggers nothing" -- grep -E "$ask" "$root/tests/fixtures/pr-good.md"

# The session hook prints the git state and the version holds.
hookrepo=$tmp/hookrepo
mkdir -p "$hookrepo" && git -C "$hookrepo" init -q
expect 0 "Version holds (setkernel org policy)" "the session hook prints the holds" -- \
  env CLAUDE_PROJECT_DIR="$hookrepo" sh "$root/plugins/setkernel/hooks/session-context.sh"
expect 0 "typescript-6.0" "the printed holds name each hold" -- \
  env CLAUDE_PROJECT_DIR="$hookrepo" sh "$root/plugins/setkernel/hooks/session-context.sh"

# The git guard (PreToolUse on Bash): blocks the forms a deny rule misses, lets ordinary work through.
hooks=$root/plugins/setkernel/hooks
expect 0 "git-guard.sh" "the plugin registers the git guard on Bash" -- \
  jq -er '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command' "$hooks/hooks.json"
# The guards fail closed (#36): a guard that can't start, crashes or times out blocks the call. Claude Code
# counts any exit but 0 and 2 as a failure there, so a guard must exit 0 on input it doesn't care about.
for g in git-guard d1-guard; do
  expect 0 '^block$' "hooks.json blocks the call when $g.sh fails" -- \
    jq -er ".hooks.PreToolUse[].hooks[] | select(.command | contains(\"hooks/$g.sh\")) | .onFailure" "$hooks/hooks.json"
  for inp in '' 'not json' '{}' '{"tool_name":"Read","tool_input":{"file_path":"x"}}'; do
    expect 0 "" "$g.sh exits 0 on input: ${inp:-empty}" -- sh -c 'printf "%s" "$1" | '"$sh_cmd"' "$2"' _ "$inp" "$hooks/$g.sh"
  done
done
expect 0 '^\[\]$' "every PreToolUse hook fails closed" -- jq -c '[.hooks.PreToolUse[].hooks[] | select(.onFailure != "block")]' "$hooks/hooks.json"
grepo=$tmp/guardrepo
mkdir -p "$grepo" && git -C "$grepo" init -q -b feat && git -C "$grepo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C "$grepo" config alias.yolo 'push --force'
git -C "$grepo" config alias.nuke '!git reset --hard'
git -C "$grepo" config alias.st status
mrepo=$tmp/mainrepo
mkdir -p "$mrepo" && git -C "$mrepo" init -q -b main
# guard <dir> <command>: run the hook on a Bash call as Claude Code sends it.
guard() {
  jq -n --arg c "$2" --arg d "$1" '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' |
    run_sh "$hooks/git-guard.sh"
}
while IFS= read -r c; do
  expect 2 "setkernel git guard: blocked" "guard blocks: $c" -- guard "$grepo" "$c"
done <<'EOF'
git push --force-with-lease
git push origin feat --force
git push -uf origin feat
git push origin +feat
git -C . push -f origin feat
git -c push.default=current --no-pager push --force
env GIT_TRACE=0 git push --force
sh -c "git push -f origin feat"
sudo -u root git push -f origin feat
env -u VAR git push -f origin feat
sudo -u root git push origin main
nice -n 5 git reset --hard
timeout -s KILL 5 git push --force
cd sub && git push origin feat -f
echo "$(git push --mirror)"
git push origin main
git push origin HEAD:refs/heads/main
git push origin feat:master
git push --all origin
git push origin --delete old-branch
git push origin -d old-branch
git push origin :old-branch
git push --prune origin
git reset --hard
git reset --hard origin/feat
git -C /srv/repo reset --hard HEAD~1
git clean -f
git clean -fdx
git clean -d --force
timeout 30 git clean -xdf
git -c alias.up=push up -f
git -c "alias.x=!git push -f" x
git yolo
git nuke
git st; git st; git st; git yolo
git push --force-w origin feat
git push --force-with=feat:abc origin feat
git push --forc origin feat
git push --mirr
git push --mi origin
git push --del origin feat
git push origin --de feat
git push --prun origin
git push --pru origin
git push --al origin
git push --br origin
git reset --har HEAD
git reset --ha
git clean --forc
git clean -d --fo
EOF
while IFS= read -r c; do
  expect 0 "" "guard allows: $c" -- guard "$grepo" "$c"
done <<'EOF'
git push
git push origin feat
git push -u origin agent/23-harden
git push origin HEAD
git push --follow-tags origin feat
git push --foll origin feat
git push -o
git push --no-force-with-lease origin feat
git push --dry-run --porcelain origin feat
git push --repo origin feat
git push --push-o ci.skip origin feat
git status
git reset --soft HEAD~1
git reset --so HEAD~1
git clean --dry-run -d
git reset HEAD file.txt
git clean -n
git clean -nd
git stash push -m wip
git commit -m "docs: explain the push guard"
grep -rn "git push" docs
git -c alias.st=status st
echo done
EOF
expect 2 "default branch (main)" "on main, a bare git push is a push to the default branch" -- guard "$mrepo" "git push"
expect 2 "default branch (main)" "on main, git push origin HEAD is too" -- guard "$mrepo" "git push origin HEAD"
# A redirect's file descriptor number (the 2 in 2>&1) is not a branch name.
expect 2 "default branch (main)" "on main, git push origin 2>&1" -- guard "$mrepo" "git push origin 2>&1"
expect 2 "default branch (main)" "on main, git push -u origin 2>/dev/null" -- guard "$mrepo" "git push -u origin 2>/dev/null"
expect 2 "default branch (main)" "on main, git push origin 2>>log" -- guard "$mrepo" "git push origin 2>>log"
expect 0 "" "on main, git push origin feature 2>&1 names a branch" -- guard "$mrepo" "git push origin feature 2>&1"
# A cd earlier in the command line moves the repo the guard reads the branch from.
expect 2 "default branch (main)" "cd into a repo on main, then a bare git push" -- guard "$tmp" "cd mainrepo && git push"
expect 2 "default branch (main)" "cd into a repo on main, then git push origin HEAD" -- guard "$tmp" "cd $mrepo; git push origin HEAD"
expect 0 "" "cd from main into a feature checkout, then a bare git push" -- guard "$mrepo" "cd ../guardrepo && git push"
# An alias run with -C is expanded and checked in that repository, not the session's cwd.
git -C "$mrepo" config alias.pub 'push origin HEAD'
git -C "$grepo" config alias.pub 'push origin HEAD'
expect 2 "default branch (main)" "git -C <repo on main> pub, an alias for push origin HEAD" -- guard "$grepo" "git -C $mrepo pub"
expect 0 "" "git -C <feature checkout> pub from a repo on main" -- guard "$mrepo" "git -C $grepo pub"
expect 2 "git reset --hard" "git -C <repo> nuke, an alias only that repo has" -- guard "$tmp" "git -C guardrepo nuke"
# The hook sees the session's environment: sk-agent's runs set SETKERNEL_GUARD_NO_PUSH=1.
jq -n --arg d "$grepo" '{tool_input: {command: "git push origin feat"}, cwd: $d}' >"$tmp/feat.json"
jq -n --arg d "$grepo" '{tool_input: {command: "git -C . push \"--force\"", description: "a \"quoted\" push"}, cwd: $d}' >"$tmp/force.json"
echo '{}' >"$tmp/nocmd.json"
# hook_on <input-file> [VAR=value…]: run the guard with that input and environment.
hook_on() {
  f=$1
  shift
  # shellcheck disable=SC2086 # sh_cmd may be "busybox sh"
  env "$@" $sh_cmd "$hooks/git-guard.sh" <"$f"
}
expect 2 "the worker pushes" "SETKERNEL_GUARD_NO_PUSH=1 blocks every push" -- hook_on "$tmp/feat.json" SETKERNEL_GUARD_NO_PUSH=1
expect 0 "" "an input without a command passes" -- hook_on "$tmp/nocmd.json"
# With SETKERNEL_GUARD_NO_PUSH=1 the guard reads the command line as the shell does (#43): text that only
# mentions a push passes, and a push in any spelling sk-push-guard blocks is blocked. Each line gives the
# exit code with the variable, the exit code without it (unchanged by #43), then the command, where \n
# is a newline. They run in a repo on a feature branch, as in the issue's repros.
nprepo=$tmp/nprepo
mkdir -p "$nprepo" && git -C "$nprepo" init -q -b agent/1-demo
# guard_env <dir> <command> [VAR=value…]: run the hook on a Bash call with that environment.
guard_env() {
  d=$1 c=$2
  shift 2
  # shellcheck disable=SC2086 # sh_cmd may be "busybox sh"
  jq -n --arg c "$c" --arg d "$d" '{tool_input: {command: $c}, cwd: $d}' | env "$@" $sh_cmd "$hooks/git-guard.sh"
}
while IFS='|' read -r codes c; do
  case $codes in '#'*) continue ;; esac
  expect "${codes% *}" "" "with SETKERNEL_GUARD_NO_PUSH=1, exit ${codes% *}: $c" -- \
    guard_env "$nprepo" "$(printf '%b' "$c")" SETKERNEL_GUARD_NO_PUSH=1
  expect "${codes#* }" "" "without it, exit ${codes#* }: $c" -- guard_env "$nprepo" "$(printf '%b' "$c")"
done <<'EOF'
# Issue part 1: text that only mentions a push.
0 0|git commit -F - <<'EOM'\ndocs: the guard\n\ngit push is the worker's job\nEOM
0 0|git commit -m "docs: the worker pushes; git push is never run by Claude"
0 0|cat > notes.md <<'EOM'\ngit push origin agent/1-demo\nEOM
0 0|rg -n "; git push" docs/
0 0|echo "run tests | git push later"
0 0|grep -n "git push" file
0 0|git commit -m "docs: the worker runs git push, Claude never does"
0 0|gh pr comment 1 --body "Do not run git push; the worker does"
0 0|git commit -m "$(cat <<'EOM'\nfix: say why\n\nThe worker runs git push; Claude doesn't.\nEOM\n)"
0 0|cat <<EOM\nan unquoted body: git push origin x, $HOME\nEOM
0 0|git status # git push origin x
0 0|printf '%s\\n' 'git push origin x' "it's; git push" $'git push\\n'
0 2|git commit -m "fix: a commit message that holds ; git push -f"
# A real push stays blocked: plain, in sh -c, eval, $(…), backticks, a heredoc or here-string a shell runs.
2 0|git push origin HEAD:refs/heads/x
2 0|"git" push origin x
2 0|sh -c "git push origin x"
2 0|bash -lc 'cd /tmp && git push origin x'
2 0|bash -o pipefail -c 'git push origin x'
2 0|xargs sh -c 'git push origin x'
2 0|sh -c 'sh -c "sh -c \\"sh -c git\\\\ push\\""'
2 0|eval "git push origin x"
2 0|env -S 'git push origin x'
2 0|sh -c 'git push origin "${B:-x}"'
2 0|bash -lc 'git push -u origin "${1:-HEAD}"'
2 0|sudo -u bob sh -c 'git push origin ${B:+x}'
2 0|bash -c -x 'git push origin ${B:-x}'
2 0|bash -c 'git push ${xsh:-c}'
2 0|env -S 'git push origin ${B:-x}'
2 0|env -S 'git -c push.default=current push'
2 0|env -S 'git push ${xsh:-c}'
2 0|env -S '-i git push origin x'
2 0|flock -w 5 /tmp/l -c 'git push ${B:+x}'
2 2|sh -c 'git reset --hard "${R:-HEAD}"'
0 0|sh -c 'echo ${x:-a}; ls'
0 0|env -S 'echo ${x:-push}'
2 0|echo "$(git push origin x)"
2 0|echo `git push origin x`
2 0|echo "`git push origin x`"
2 0|x=$(git push origin x)
2 0|echo $((1 + $(git push origin x | wc -l)))
2 0|out=$((git push origin x) 2>&1)
2 0|echo $((git push origin x) | cat)
0 0|echo $(( 1 + 2 ))
0 0|echo $((x << 2)); git status
2 0|git -C "$(git rev-parse --show-toplevel)" push origin x
2 0|bash <<'EOM'\ngit push origin x\nEOM
2 0|cat <<'EOM' | sh\ngit push origin x\nEOM
2 0|cat <<EOM\n$(git push origin x)\nEOM
2 0|bash <<<'git push origin x'
2 0|cat <<'EOM'; git push origin x\nbody\nEOM
2 0|git commit -m 'msg' # a comment\ngit push origin x
2 0|echo a\\ #x; git push origin x
2 0|git commit -m "an unclosed quote; git push origin x
2 0|cat <<'EOM' |\ngit push origin x\nEOM\nbash
2 0|bash -c "$(cat <<'EOM'\ngit push origin x\nEOM\n)"
2 0|source /dev/stdin <<'EOM'\ngit push origin x\nEOM
0 0|git add . && git commit -F - <<'EOM'\nthe worker's git push\nEOM
0 0|gh pr create --title "Fix bash completion" --body-file - <<'EOM'\nthe worker's git push\nEOM
# Like sk-push-guard: text piped into a shell, and a git word anywhere in a command, not only first.
2 0|echo 'git push origin x' | bash
2 0|printf 'git push origin x\\n' | env FOO=1 sh -s
0 0|echo "git push" | grep push
2 0|chrt 5 git push origin x
2 0|echo git push origin x
2 0|git $(echo -C .) push origin x
0 0|which git && git --version
2 0|find . -maxdepth 0 -exec sh -c 'git push origin x' \\;
0 0|psql -c "select 'git push'"
2 0|echo 'git push origin x' |\nbash
2 0|echo 'git push origin x' | /usr/bin/env bash
# A case pattern's ) inside $(…) does not end the $(.
2 0|echo "$(case a in a) git push origin x;; esac)"
0 0|case "$(uname)" in Linux) echo ok;; esac
# A # inside ${…} is text, not a comment, so the push after it runs; the first } outside quotes ends it.
2 0|echo ${x:-a #b}; git push origin x
2 2|echo ${x:-a #b}; git push -f origin x
2 0|echo ${x:+ #}; git push origin x
2 0|echo ${x#a #}; git push origin x
2 0|echo ${x//a/ #}; git push origin x
2 0|echo "${x:-"a #b"}"; git push origin x
2 0|echo ${x:-'}' #b}; git push origin x
2 0|echo ${x:-a\\} #b}; git push origin x
2 0|echo ${x:-$(git push origin x)}
0 0|echo ${x:-a} #b; git push origin x
0 0|git commit -m "fix: ${HOME}, not ~; the worker runs git push"
# A backtick (or \\$) nested in a backtick runs: the raw text is checked.
2 0|echo `echo \\`git push origin x\\``
2 0|echo "`echo \\`git push origin x\\``"
2 0|echo `echo \\$(git push origin x)`
0 0|git commit -m "fix \\`foo\\`; the worker runs git push"
# A segment of blanks only passes under every shell (dash exits 2 on a shift too many).
0 0|true && (ls)
0 0|{ ls; }
# Everyday commands where a segment runs out of words (round 2, item A): they pass under dash too.
0 0|x=1; echo "$x"
0 0|branch=$(git branch --show-current); echo "$branch"
0 0|if [ -f README.md ]; then\n  echo yes\nfi
0 0|for f in *.md; do\n  wc -l "$f"\ndone
0 0|{ echo a; echo b; } > out.txt
0 0|git -c user.name=bot -c user.email=bot@example.com commit -m "fix: x"
0 0|out=$(npm test 2>&1); echo "$out" | tail -20
# A git word after the command word that runs reset or clean without blocking is not a hook failure (B).
0 0|git submodule foreach git reset -q HEAD
0 0|find . -name '*.orig' -exec git reset -q -- {} \\;
0 0|git submodule foreach git clean -d --dry-run
2 0|git submodule foreach git reset --hard
# A heredoc body is commands only if the command that reads it (or a later one in its pipeline, or a
# command it is a $(…) in) runs a shell, not when a shell word is elsewhere on the line (C).
0 0|source .venv/bin/activate && pytest -q && git commit -F - <<'EOM'\nfix: x\n\nThe worker runs git push after the run.\nEOM
0 0|cat > docs/source/deploy.rst <<'EOM'\nThen run git push origin feat to publish\nEOM
0 0|. .venv/bin/activate && cat > notes.md <<'EOM'\nthe worker runs git push\nEOM
0 0|source .venv/bin/activate && gh pr create --title t --body "$(cat <<'EOM'\nthe worker runs git push\nEOM\n)"
2 0|sudo -u root bash <<'EOM'\ngit push origin x\nEOM
2 0|<<'EOM' bash\ngit push origin x\nEOM
2 0|cat <<'EOM' | sudo bash\ngit push origin x\nEOM
2 0|. /dev/stdin <<'EOM'\ngit push origin x\nEOM
2 0|eval "$(cat <<'EOM'\ngit push origin x\nEOM\n)"
# A redirection glued to the shell word (sh<<EOF) is not part of it, and the & of a redirection
# (2>&1, >&2, &>f) or of |& does not end the command (round 5).
2 0|sh<<'EOM'\ngit push origin x\nEOM
2 0|bash<<EOM\ngit push origin x\nEOM
2 0|bash<<-EOM\n\tgit push origin x\n\tEOM
2 0|echo x|sh<<'EOM'\ngit push origin x\nEOM
2 0|true && sh<<'EOM'\ngit push origin x\nEOM
2 0|(sh<<'EOM'\ngit push origin x\nEOM\n)
2 0|{ sh<<'EOM'\ngit push origin x\nEOM\n}
2 0|x=$(sh<<'EOM'\ngit push origin x\nEOM\n)
2 0|sudo -u x sh<<'EOM'\ngit push origin x\nEOM
2 0|sh 2>&1 <<'EOM'\ngit push origin x\nEOM
2 0|bash >&2 <<'EOM'\ngit push origin x\nEOM
2 0|bash &>/dev/null <<'EOM'\ngit push origin x\nEOM
2 0|cat <<'EOM' 2>&1 | sh\ngit push origin x\nEOM
2 0|cat <<'EOM' >&2 | sh\ngit push origin x\nEOM
2 0|cat <<'EOM' |& bash\ngit push origin x\nEOM
2 0|cat <<'EOM' |&\ngit push origin x\nEOM\nbash
2 0|sh 2>&1 <<< 'git push origin x'
2 0|echo 'git push origin x' 2>&1 | sh
0 0|cat<<'EOM'\nthe worker runs git push\nEOM
0 0|cat <<'EOM' 2>&1 | tee f\nthe worker runs git push\nEOM
0 0|cat <<'EOM' >&2\nthe worker runs git push\nEOM
0 0|cat >/tmp/sh <<'EOM'\nthe worker runs git push\nEOM
0 0|git commit -F - 2>&1 <<'EOM'\nthe worker runs git push\nEOM
0 0|bash -x tests/run.sh 2>&1 | tail; git commit -F - <<'EOM'\nthe worker runs git push\nEOM
# Likewise a here-string, and only up to the end of the command that reads it (D).
0 0|read -r owner repo <<< "$pair"; bash tests/run.sh && git commit -m "test: cover git push spellings"
0 0|bash <<< 'echo hi'; git commit -m "docs: the worker runs git push"
2 0|bash <<<"$(true); git push origin x"
2 0|<<<'git push origin x' bash
# An escaped blank in a here-string a shell reads is decoded too; elsewhere it stays text.
2 0|bash <<< git\\ push origin x
2 0|sh <<< git\\ push origin x
0 0|grep -c foo <<< git\\ push
0 0|echo git\\ push
# { and } split words only as reserved words, so ${…} and {} stay in their word (E). Without the
# variable the old split still misses these, as on main.
2 0|git -C ${PWD} push --force origin HEAD:refs/heads/x
2 0|find . -maxdepth 0 -exec git -C {} push origin HEAD:refs/heads/y \\;
2 0|git -C ${dir} push origin x
2 0|parallel git -C {} push ::: a b
2 0|{ git push origin x; }
2 0|echo {}; git push origin x
0 0|echo {a,b} && git commit -m "git push later"
# Issue part 2: spellings sk-push-guard blocks.
2 0|git subtree push --prefix=d origin x
2 0|git send-pack origin HEAD:refs/heads/x
2 0|setsid git push origin x
2 0|flock /tmp/l git push origin x
2 0|flock /tmp/l -c 'git push origin x'
2 0|ionice -c3 git push origin x
2 0|ionice -c idle git push origin x
2 0|exec -a x git push origin x
2 0|git --attr-source HEAD push origin x
2 0|git config alias.q push && git q origin x
2 0|git config alias.q '!git push' && git q origin x
2 2|git -c ALIAS.q=push q origin x
2 0|git -C "dir with spaces" push origin x
# The wrappers are read without the variable too, so a force push through them is blocked there as well.
2 2|setsid git push -f origin x
2 2|flock -w 5 /tmp/l git push -f origin x
2 2|exec -a x git push -f origin x
2 2|git --attr-source HEAD push -f origin x
# Other git commands still pass.
0 0|git config alias.st status
0 0|git config user.name pusher
0 0|git subtree split --prefix=d
0 0|git log --oneline | grep push
EOF
# The no-push reading needs awk; without it the guard checks the raw text, as it does without the variable.
noawk=$tmp/noawk
mkdir -p "$noawk"
for t in "${sh_cmd%% *}" jq sed tr git cat env; do ln -s "$(command -v "$t")" "$noawk/$t"; done
expect 2 "the worker pushes" "without awk, SETKERNEL_GUARD_NO_PUSH=1 still blocks a push" -- \
  guard_env "$nprepo" "git push origin x" PATH="$noawk" SETKERNEL_GUARD_NO_PUSH=1
# busybox sh finds its own awk applet without PATH, so there is nothing to take away.
if ! env PATH="$noawk" $sh_cmd -c 'command -v awk' >/dev/null 2>&1; then
  expect 2 "the worker pushes" "without awk, a quoted mention is blocked, as before #43" -- \
    guard_env "$nprepo" 'git commit -m "docs; git push later"' PATH="$noawk" SETKERNEL_GUARD_NO_PUSH=1
fi
# The guard hides awk's errors and falls back to the raw text, so a scrub that doesn't compile on one awk
# (BSD awk on macOS rejects some regexes gawk takes) shows only as refusals. Run scrub's program on its
# own under each awk here, so a compile error fails loudly. The input reaches every regex, including
# the ones awk compiles only when used.
cp "$hooks/lib/scrub.awk" "$tmp/scrub.awk"
cat >"$tmp/scrub.in" <<'EOF'
{ echo ${x:-a #b} "q" $(git status) `pwd` $((1 + 2)) $'a\tb' {}; } | /usr/bin/env bash <<<"$y" # c
x=1 . ./a && cat <<'EOM' | sh
body
EOM
read -r a <<< "$b"; echo done
EOF
for a in awk original-awk nawk mawk gawk 'busybox awk'; do
  # shellcheck disable=SC2086 # "busybox awk" is two words
  command -v ${a%% *} >/dev/null 2>&1 || continue
  # shellcheck disable=SC2086
  expect 0 "echo done" "scrub compiles and reads a command line under $a" -- \
    env LC_ALL=C $a -f "$tmp/scrub.awk" "$tmp/scrub.in"
done
# The guard finds lib/scrub.awk from its own path, so it works from any working directory: scrub reads
# the quoted mention as text (0); a failed lookup would fall back to the raw text and refuse it (2).
guard_from_root() { (cd / && guard_env "$@"); }
expect 0 "" "git-guard.sh finds scrub.awk from another working directory" -- \
  guard_from_root "$nprepo" 'git commit -m "docs; git push later"' SETKERNEL_GUARD_NO_PUSH=1
# Without jq the guard still reads the command (macOS before 15 ships no jq).
nojq=$tmp/nojq
mkdir -p "$nojq"
for t in "${sh_cmd%% *}" sed tr git cat; do ln -s "$(command -v "$t")" "$nojq/$t"; done
expect 2 "blocked a force push" "without jq: a quoted force push is blocked" -- hook_on "$tmp/force.json" PATH="$nojq"
expect 0 "" "without jq: a feature-branch push passes" -- hook_on "$tmp/feat.json" PATH="$nojq"
# The D1 guard (PreToolUse) denies remote D1 writes and remote --file runs; everything else passes (#18).
d1guard=$root/plugins/setkernel/hooks/d1-guard.sh
# hook <stdin-text>: feed the text to the guard on stdin.
hook() { printf '%s' "$1" | run_sh "$d1guard"; }
# bash_in <command>: the PreToolUse JSON for a Bash command.
bash_in() { jq -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}'; }
deny='"permissionDecision":"deny"'
wr='a remote wrangler d1 execute statement that writes'
cm='spread over lines with a -- comment'
nl='
'
deny_cmd() { expect 0 "$deny" "the guard denies: $1" -- hook "$(bash_in "$1")"; }
allow_cmd() { expect 0 '^$' "the guard allows: $1" -- hook "$(bash_in "$1")"; }
for stmt in "INSERT INTO t VALUES (1)" "insert into t values (1)" "Insert  Into t values (1)" "INSERT OR REPLACE INTO t VALUES (1)" \
  "REPLACE INTO t VALUES (1)" "UPDATE t SET a = 1" "update  t${nl}set a = 1" "DELETE FROM t" "delete${nl}from t" \
  "DROP TABLE t" "drop  index i" "ALTER TABLE t ADD COLUMN c" "CREATE TABLE t (a)" "create unique index i on t(a)" \
  "CREATE TEMP TABLE t (a)" "PRAGMA writable_schema = 1" "pragma  foreign_keys=off" "INSERT/**/INTO t VALUES (1)" \
  "SELECT 1; DROP TABLE t" "delete /* a*b */ from t" "delete /* a ** b */ from t" "delete -- x${nl}from t" \
  "delete --remote${nl}from t" "insert into t values (1) -- ok" "select 1 -- x${nl}; select 2" \
  "delete \\${nl}from t" "drop \\${nl}table t" "insert \\${nl}into t values (1)" \
  "VACUUM INTO 'x.db'" "vacuum main into 'x.db'" "ATTACH DATABASE 'x.db' AS x" "attach 'x.db' as x"; do
  deny_cmd "wrangler d1 execute db --remote --command \"$stmt\""
done
deny_cmd 'wrangler d1 execute db --command "DELETE FROM t" --remote'
deny_cmd "wrangler d1 execute db --remote --command \"select 1 -- done${nl}\"${nl}echo ok"
deny_cmd "wrangler d1 execute db --remote --command 'select 1 -- done${nl}; select 2'"
deny_cmd "wrangler d1 execute db --remote --command 'select 1 /* c */'"
expect 0 "$wr" "the guard denies a write whose line breaks are escaped in a malformed payload" -- hook 'not json: wrangler d1 execute db --remote --command "select 1\nupdate t set a = 1"'
expect 0 "$wr" "the guard denies a remote write after an escaped line break in a malformed payload" -- hook 'not json: wrangler d1 execute db --remote --command "x\ndelete\nfrom t"'
expect 0 "$cm" "the guard denies a -- comment that splits a write in a malformed payload" -- hook 'not json: wrangler d1 execute db --remote --command "delete -- x\nfrom t"'
# Without jq the command is read with sed: a read passes, a write is denied for its own reason.
d1nojq=$tmp/d1nojq
mkdir -p "$d1nojq"
for t in "${sh_cmd%% *}" sed tr awk cat grep; do ln -s "$(command -v "$t")" "$d1nojq/$t"; done
hook_nojq() { printf '%s' "$1" | env PATH="$d1nojq" $sh_cmd "$d1guard"; }
expect 0 '^$' "without jq: a remote read is allowed" -- hook_nojq "$(bash_in 'wrangler d1 execute db --remote --command "SELECT * FROM users"')"
expect 0 '^$' "without jq: a remote read with an escaped quote and a flag after it is allowed" -- hook_nojq "$(bash_in 'wrangler d1 execute db --remote --command "select \"a\" from t" --json')"
expect 0 "$wr" "without jq: a remote DROP TABLE is denied as a write" -- hook_nojq "$(bash_in 'wrangler d1 execute db --remote --command "DROP TABLE t"')"
expect 0 "$wr" "without jq: a write after a line break is denied as a write" -- hook_nojq "$(bash_in "wrangler d1 execute db --remote --command \"select 1${nl}update t set a = 1\"")"
expect 0 "$cm" "without jq: a -- comment that splits a write is denied for the comment" -- hook_nojq "$(bash_in "wrangler d1 execute db --remote --command \"delete -- x${nl}from t\"")"
expect 0 '^$' "without jq: a non-Bash tool is allowed" -- hook_nojq '{"tool_name":"Edit","tool_input":{"command":"wrangler d1 execute db --remote --command \"DROP TABLE t\""}}'
expect 0 '^$' "without jq: a local write is allowed" -- hook_nojq "$(bash_in 'wrangler d1 execute db --local --command "DROP TABLE t"')"
# Known gaps, pinned so a change shows up: indirection hides the SQL from a text match.
allow_cmd 'wrangler d1 execute db --remote --command "$SQL"'
allow_cmd 'wrangler d1 execute db --remote --command "$(echo ZGVsZXRlIGZyb20gdA== | base64 -d)"'
deny_cmd "wrangler d1 execute db --remote --command='DELETE FROM t'"
deny_cmd 'npx wrangler d1 execute db --remote --command "drop table t"'
deny_cmd 'pnpm exec wrangler d1 execute db --remote --command "drop table t"'
deny_cmd 'cd app && npx wrangler --config wrangler.toml d1 execute db --remote --command "drop table t"'
deny_cmd 'wrangler d1 execute db --remote --file schema.sql'
deny_cmd 'wrangler d1 execute db --file=./q.sql --remote'
deny_cmd 'npx wrangler d1 execute db --remote --file schema.sql'
expect 0 "$wr" "the guard denies a remote D1 write inside a malformed payload" -- hook 'not json: wrangler d1 execute db --remote --command "DROP TABLE t"'
expect 0 '"hookEventName":"PreToolUse"' "the deny output names the PreToolUse event" -- hook "$(bash_in 'wrangler d1 execute db --remote --command "DROP TABLE t"')"
allow_cmd 'wrangler d1 execute db --remote --command "SELECT * FROM users"'
allow_cmd "wrangler d1 execute db --remote --command \"SELECT a,${nl}  b${nl}FROM t\""
allow_cmd "wrangler d1 execute db --remote --command \"select 1\"${nl}echo -- done${nl}echo ok"
allow_cmd "wrangler d1 execute db --remote \\${nl}  --command \"select 1\""
allow_cmd 'wrangler d1 execute db --command "select * from t" --remote'
allow_cmd 'wrangler d1 execute db --remote --command "SELECT updated_at, created_at FROM updates"'
allow_cmd 'wrangler d1 execute db --remote --command "PRAGMA table_info(users)"'
allow_cmd 'wrangler d1 execute db --remote --command "SELECT name FROM sqlite_master"'
allow_cmd 'wrangler d1 execute update-db --remote --command "SELECT 1"'
allow_cmd 'wrangler d1 execute db --local --command "DROP TABLE t"'
allow_cmd 'wrangler d1 execute db --local --file schema.sql'
allow_cmd 'wrangler d1 execute db --no-remote --command "DELETE FROM t"'
allow_cmd "wrangler d1 execute db --remote \\${nl}  --command \"select 1\""
allow_cmd 'wrangler d1 execute db --remote --command "select 1 -- just a read"'
allow_cmd 'wrangler d1 list'
allow_cmd 'wrangler d1 migrations apply db --local'
allow_cmd 'git status'
expect 0 '^$' "the guard allows a non-Bash tool" -- hook '{"tool_name":"Edit","tool_input":{"command":"wrangler d1 execute db --remote --command \"DROP TABLE t\""}}'
expect 0 '^$' "the guard allows a payload with no command" -- hook '{"tool_name":"Bash","tool_input":{}}'
expect 0 '^$' "the guard allows empty input" -- hook ''
expect 0 '^$' "the guard allows unrelated malformed input" -- hook 'not json'

# The verify gate (#31): a Stop hook that blocks while the repo's `make check` fails.
gate=$root/plugins/setkernel/hooks/verify-gate.sh
gaterepo=$tmp/gaterepo
mkdir -p "$gaterepo/tools" && git -C "$gaterepo" init -q
# A Makefile in the shape of setkernel/hq's template: STEPS, PASS/FAIL per step, a summary line.
# The test step fails while the file `red` exists; every run is counted in $tmp/gate-runs.
cat >"$gaterepo/Makefile" <<'EOF'
STEPS = lint test
check:
	@sh tools/check.sh $(STEPS)
lint:
	@echo lint is fine
test:
	@echo 'assertion "x" \ failed'; test ! -f red
EOF
cat >"$gaterepo/tools/check.sh" <<EOF
echo run >>"$tmp/gate-runs"
pass=0; fail=0; failed=""
for step in "\$@"; do
  echo "== \$step"
  if make --no-print-directory "\$step"; then echo "PASS \$step"; pass=\$((pass + 1)); else echo "FAIL \$step"; fail=\$((fail + 1)); failed="\$failed \$step"; fi
done
echo "== \$pass passed, \$fail failed\${failed:+:\$failed}"
[ "\$fail" -eq 0 ]
EOF
printf 'red\n' >"$gaterepo/.gitignore"
git -C "$gaterepo" add -A && git -C "$gaterepo" -c user.name=t -c user.email=t@example.com commit -qm init
gstate=$tmp/gate-state
# gate <mode> <hook-input-json> [VAR=value...]: run the hook as Claude Code would.
gate() {
  m=$1 j=$2
  shift 2
  printf '%s' "$j" | env CLAUDE_PROJECT_DIR="$gaterepo" CLAUDE_PLUGIN_DATA="$gstate" SETKERNEL_VERIFY_GATE=1 "$@" $sh_cmd "$gate" "$m"
}
runs() { if [ -f "$tmp/gate-runs" ]; then wc -l <"$tmp/gate-runs" | tr -d ' '; else echo 0; fi; }
in_stop='{"session_id":"s1","hook_event_name":"Stop","permission_mode":"bypassPermissions","stop_hook_active":false,"last_assistant_message":"done, \"agent_type\": \"reviewer\""}'

expect 0 "hooks/verify-gate.sh\\\\\" stop" "hooks.json runs the gate on Stop" -- jq -r '.hooks.Stop[0].hooks[0].command | @json' "$root/plugins/setkernel/hooks/hooks.json"
expect 0 "hooks/verify-gate.sh\\\\\" start" "hooks.json records the baseline on SessionStart" -- jq -r '[.hooks.SessionStart[0].hooks[].command] | @json' "$root/plugins/setkernel/hooks/hooks.json"
expect 0 '^$' "SessionStart: the gate prints nothing into the context" -- sh -c "printf '%s' '{\"session_id\":\"s1\"}' | env CLAUDE_PROJECT_DIR='$gaterepo' CLAUDE_PLUGIN_DATA='$gstate' SETKERNEL_VERIFY_GATE=1 $sh_cmd '$gate' start; echo"
touch "$gaterepo/red"
expect 0 '^$' "a session that changed nothing is not gated (read-only run)" -- gate stop "$in_stop"
expect 0 "^0$" "and its check did not run" -- runs
printf 'change\n' >"$gaterepo/new.txt"
expect 0 '^$' "off unless SETKERNEL_VERIFY_GATE=1" -- gate stop "$in_stop" SETKERNEL_VERIFY_GATE=
expect 0 '^$' "plan mode is not gated" -- gate stop '{"session_id":"s1","permission_mode":"plan"}'
for a in reviewer setkernel:reviewer setkernel:explorer Explore Plan; do
  expect 0 '^$' "a $a run is not gated" -- gate stop "{\"session_id\":\"s1\",\"agent_type\":\"$a\"}"
done
expect 0 "^0$" "none of those ran the check" -- runs
expect 0 '"decision":"block"' "an edited tree with make check red is blocked" -- gate stop "$in_stop"
gate stop "$in_stop" >"$tmp/gate-out" || true
expect 0 "failing: test" "the reason names the failing step" -- jq -er .reason "$tmp/gate-out"
expect 0 'assertion "x" \\ failed' "the reason carries the step's output, quotes and backslashes intact" -- jq -er .reason "$tmp/gate-out"
expect 1 "" "and leaves out the passing step's output" -- sh -c "jq -er .reason '$tmp/gate-out' | grep 'lint is fine'"
expect 0 "block 2 of 3" "the reason counts the blocks" -- jq -er .reason "$tmp/gate-out"
expect 0 "This is the last block" "the third block says it is the last" -- sh -c "gate_out=\$(printf '%s' '$in_stop' | env CLAUDE_PROJECT_DIR='$gaterepo' CLAUDE_PLUGIN_DATA='$gstate' SETKERNEL_VERIFY_GATE=1 $sh_cmd '$gate' stop) && printf '%s' \"\$gate_out\" | jq -er .reason"
gate stop "$in_stop" >"$tmp/gate-out" || true
expect 1 "" "after 3 blocks the run may stop" -- grep '"decision"' "$tmp/gate-out"
expect 0 "fails (exit 2, failing: test) after 3 blocks" "and the failure is reported to the user" -- jq -er .systemMessage "$tmp/gate-out"
expect 0 "block 1 of 3" "a later stop starts a new round of blocks" -- sh -c "printf '%s' '$in_stop' | env CLAUDE_PROJECT_DIR='$gaterepo' CLAUDE_PLUGIN_DATA='$gstate' SETKERNEL_VERIFY_GATE=1 $sh_cmd '$gate' stop | jq -er .reason"
expect 0 "block 1 of 1" "SETKERNEL_VERIFY_GATE_MAX sets the limit" -- sh -c "printf '%s' '{\"session_id\":\"s2\"}' | env CLAUDE_PROJECT_DIR='$gaterepo' CLAUDE_PLUGIN_DATA='$gstate' SETKERNEL_VERIFY_GATE=1 SETKERNEL_VERIFY_GATE_MAX=1 $sh_cmd '$gate' stop | jq -er .reason"
rm -f "$gaterepo/red"
before=$(runs)
expect 0 '^$' "make check green: the run stops" -- gate stop "$in_stop"
expect 0 "^$((before + 1))$" "green ran the check once" -- runs
expect 0 '^$' "a tree that already passed is not checked again" -- gate stop "$in_stop"
expect 0 "^$((before + 1))$" "so the check did not rerun" -- runs
printf 'more\n' >>"$gaterepo/new.txt"
expect 0 '^$' "an edit after green reruns the check" -- gate stop "$in_stop"
expect 0 "^$((before + 2))$" "which ran once more" -- runs
expect 0 '"decision":"block"' "SETKERNEL_VERIFY_CMD overrides make check" -- gate stop '{"session_id":"s3"}' SETKERNEL_VERIFY_CMD='echo boom; exit 1'
expect 0 "boom" "and without a step summary the reason ends with the output" -- sh -c "printf '%s' '{\"session_id\":\"s3\"}' | env CLAUDE_PROJECT_DIR='$gaterepo' CLAUDE_PLUGIN_DATA='$gstate' SETKERNEL_VERIFY_GATE=1 SETKERNEL_VERIFY_CMD='echo boom; exit 1' $sh_cmd '$gate' stop | jq -er .reason"
expect 0 '^$' "a repo without a check target is not gated" -- \
  sh -c "printf '%s' '{\"session_id\":\"s4\"}' | env CLAUDE_PROJECT_DIR='$hookrepo' CLAUDE_PLUGIN_DATA='$gstate' SETKERNEL_VERIFY_GATE=1 $sh_cmd '$gate' stop"
mkdir -p "$tmp/nogit"
expect 0 '^$' "outside a git repo the gate lets the run stop" -- \
  sh -c "printf '%s' '{\"session_id\":\"s4\"}' | env CLAUDE_PROJECT_DIR='$tmp/nogit' CLAUDE_PLUGIN_DATA='$gstate' SETKERNEL_VERIFY_GATE=1 $sh_cmd '$gate' stop"
expect 0 "" "the repo's own index is untouched" -- git -C "$gaterepo" diff --cached --quiet

# The persona hook (#37): opt-in, keyed on a setkernel email, fetched with a stub gh, owner-only cache.
# Made-up persona text only: real personas are private (decision 0001).
persona=$hooks/persona.sh
phome=$tmp/persona-home
pstub=$tmp/persona-stub
pdata=$tmp/persona-data
mkdir -p "$phome" "$pstub"
cat >"$pstub/gh" <<EOF
#!/bin/sh
echo "\$*" >>"$tmp/gh-calls"
[ -f "$tmp/gh-down" ] && { echo 'gh: error connecting to api.github.com' >&2; exit 1; }
case "\$*" in
  *"repos/setkernel/hq/contents/agents/personas/zz-test.md"*) printf '# Made-up test persona\nLikes "quotes" and back\\\\slashes.\n' ;;
  *) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
esac
EOF
chmod +x "$pstub/gh"
# with_email <email>: the global git email the hook keys on.
with_email() { printf '[user]\n\temail = %s\n' "$1" >"$phome/.gitconfig"; }
# persona_hook [VAR=value…]: run the hook as Claude Code would, outside any repo, opted in.
# shellcheck disable=SC2120 # expect and silent pass the arguments
persona_hook() {
  # shellcheck disable=SC2086 # sh_cmd may be "busybox sh"
  (cd "$tmp" && printf '{"session_id":"p1"}' | env HOME="$phome" XDG_CACHE_HOME= GIT_CONFIG_GLOBAL="$phome/.gitconfig" \
    GIT_CONFIG_NOSYSTEM=1 CLAUDE_PLUGIN_DATA="$pdata" PATH="$pstub:$PATH" SETKERNEL_PERSONA=1 "$@" $sh_cmd "$persona")
}
# silent <command…>: "silent" when the command exits 0 and prints nothing, stderr included.
silent() {
  out=$("$@" 2>&1) && [ -z "$out" ] && echo silent
}
gh_calls() { if [ -f "$tmp/gh-calls" ]; then wc -l <"$tmp/gh-calls" | tr -d ' '; else echo 0; fi; }

expect 0 '^10$' "hooks.json runs the persona hook on SessionStart with a 10 s timeout" -- \
  jq -r '.hooks.SessionStart[].hooks[] | select(.command | contains("hooks/persona.sh")) | .timeout' "$hooks/hooks.json"
with_email zz-test@setkernel.com
expect 0 "^silent$" "off unless SETKERNEL_PERSONA=1" -- silent persona_hook SETKERNEL_PERSONA=
expect 0 "^0$" "and gh is not called" -- gh_calls
for e in zz-test@example.com zz-test@setkernel.com.evil.example zz-test@notsetkernel.com; do
  with_email "$e"
  expect 0 "^silent$" "no persona for another domain: $e" -- silent persona_hook
done
for e in ../zz-test@setkernel.com a/b@setkernel.com zz.test@setkernel.com -rf@setkernel.com @setkernel.com 'a b@setkernel.com'; do
  with_email "$e"
  expect 0 "^silent$" "no persona for an unsafe name: $e" -- silent persona_hook
done
expect 0 "^0$" "none of those called gh" -- gh_calls
rm -f "$phome/.gitconfig"
expect 0 "^silent$" "no persona without a git email" -- silent persona_hook

with_email zz-test@setkernel.com
persona_hook >"$tmp/persona-out" 2>&1 || true
expect 0 "^true$" "opted in: SessionStart JSON with the persona as additionalContext" -- \
  jq -e '.hookSpecificOutput.hookEventName == "SessionStart" and (.hookSpecificOutput.additionalContext | test("^Your persona \\(from setkernel/hq agents/personas/zz-test.md, private"))' "$tmp/persona-out"
expect 0 'Likes "quotes" and back\\slashes.' "the persona text arrives intact" -- jq -er .hookSpecificOutput.additionalContext "$tmp/persona-out"
expect 0 "^1$" "gh was called once" -- gh_calls
expect 0 "^drwx------" "the cache dir is owner-only" -- ls -ld "$pdata/persona"
expect 0 "^-rw-------" "the cached persona is owner-only" -- ls -l "$pdata/persona/zz-test.md"
expect 0 "^# Made-up test persona" "the cache holds the persona" -- cat "$pdata/persona/zz-test.md"
touch "$tmp/gh-down"
expect 0 "Made-up test persona" "a fresh cache is used while gh is down" -- persona_hook
expect 0 "^1$" "so gh was not called again" -- gh_calls
with_email ZZ-Test@SetKernel.COM
expect 0 "Made-up test persona" "the email's case does not matter" -- persona_hook
with_email zz-test@setkernel.com
expect 0 "^silent$" "SETKERNEL_PERSONA_TTL=0 forces a fetch; with gh failing, no persona and exit 0" -- silent persona_hook SETKERNEL_PERSONA_TTL=0
expect 0 "^2$" "and gh was called despite the fresh cache" -- gh_calls
rm -rf "$pdata"
expect 0 "^silent$" "gh failing with no cache: no persona, exit 0, gh's error not shown" -- silent persona_hook
rm -f "$tmp/gh-down"
with_email zz-nobody@setkernel.com
expect 0 "^silent$" "no such persona (gh 404): no persona, exit 0" -- silent persona_hook
expect 1 "" "and nothing is cached for it" -- test -e "$pdata/persona/zz-nobody.md"
with_email zz-test@setkernel.com
persona_hook >/dev/null
calls=$(gh_calls)
chmod 755 "$pdata/persona"
touch "$tmp/gh-down"
expect 0 "Made-up test persona" "a cache dir left wider is still used" -- persona_hook
expect 0 "^$calls$" "so gh was not called for it" -- gh_calls
expect 0 "^drwx------" "and made owner-only again" -- ls -ld "$pdata/persona"
rm -f "$tmp/gh-down"
rm -rf "$pdata"
expect 0 "Made-up test persona" "without CLAUDE_PLUGIN_DATA the cache is under XDG_CACHE_HOME" -- persona_hook CLAUDE_PLUGIN_DATA= XDG_CACHE_HOME="$tmp/persona-xdg"
expect 0 "^-rw-------" "and owner-only there too" -- ls -l "$tmp/persona-xdg/setkernel/persona/zz-test.md"
# Without jq there is no safe way to build the JSON here: no persona, exit 0.
pnojq=$tmp/persona-nojq
mkdir -p "$pnojq"
for t in "${sh_cmd%% *}" git tr find cat mkdir chmod mv rm env; do ln -s "$(command -v "$t")" "$pnojq/$t"; done
ln -s "$pstub/gh" "$pnojq/gh"
expect 0 "^silent$" "without jq: no persona, exit 0" -- silent persona_hook PATH="$pnojq" SETKERNEL_PERSONA_TTL=0

# bin/dependabot-policy: writes the block, is idempotent, keeps the repo's own ignores, lifts cleanly.
dp() { python3 "$root/bin/dependabot-policy" "$@"; }
dbrepo() {
  d=$tmp/db-$1
  mkdir -p "$d/.github"
  cat >"$d/.github/dependabot.yml"
  echo "$d"
}
d=$(dbrepo plain <<'EOF'
version: 2
updates:
  - package-ecosystem: npm
    directory: /
    schedule:
      interval: weekly

  # Actions: weekly.
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
EOF
)
cp "$d/.github/dependabot.yml" "$tmp/plain.orig"
expect 1 "stale: " "--check reports a repo without the block" -- dp --check "$d"
expect 0 "wrote " "the block is written" -- dp "$d"
expect 0 "current: " "a second run changes nothing" -- dp --check "$d"
expect 0 '"typescript" # typescript-6.0' "the npm entry gets the TypeScript hold" -- cat "$d/.github/dependabot.yml"
expect 1 "" "no composer hold lands in an npm-only file" -- grep squizlabs "$d/.github/dependabot.yml"
expect 0 "  # Actions: weekly." "the next entry's comment stays with it" -- sed -n '/<<< setkernel/,$p' "$d/.github/dependabot.yml"
echo '{"holds":[]}' >"$tmp/empty.json"
expect 0 "wrote " "lifting every hold rewrites the file" -- dp --policy "$tmp/empty.json" "$d"
expect 0 "" "lifting restores the original byte for byte" -- cmp "$d/.github/dependabot.yml" "$tmp/plain.orig"

d=$(dbrepo own <<'EOF'
version: 2
updates:
  - package-ecosystem: composer
    directory: /
    ignore:
      # Repo-specific pin.
      - dependency-name: 'acme/thing'
EOF
)
dp "$d" >/dev/null
expect 0 "acme/thing" "the repo's own ignore entries stay" -- cat "$d/.github/dependabot.yml"
expect 0 "# <<< setkernel version holds" "the block goes first under the existing ignore:" -- \
  sh -c "grep -A1 '^    ignore:' '$d/.github/dependabot.yml' | tail -1 | grep -q 'setkernel version holds' && grep '<<<' '$d/.github/dependabot.yml'"
d=$(dbrepo flow <<'EOF'
version: 2
updates:
  - package-ecosystem: npm
    directory: /
    ignore: [{dependency-name: x}]
EOF
)
expect 2 "flow-style" "flow-style ignore is refused" -- dp "$d"
expect 0 "nothing to do" "a repo without dependabot.yml is fine" -- dp "$tmp/hookrepo"

# Quote style: follow the file (Prettier with singleQuote), and keep a block a formatter rewrote.
d=$(dbrepo single <<'EOF'
version: 2
updates:
  - package-ecosystem: npm
    directory: '/'
    groups:
      deps:
        patterns: ['*']
EOF
)
dp "$d" >/dev/null
expect 0 "dependency-name: '@types/node' # node-24" "a single-quoted file gets a single-quoted block" -- cat "$d/.github/dependabot.yml"
expect 0 "versions: \['>=25'\]" "the versions list is single-quoted too" -- cat "$d/.github/dependabot.yml"
expect 0 "current: " "the single-quoted block is current" -- dp --check "$d"
d=$(dbrepo reformatted <<'EOF'
version: 2
updates:
  - package-ecosystem: npm
    directory: /
EOF
)
dp "$d" >/dev/null
sed -i.bak -e "s/\"@types\/node\"/'@types\/node'/" -e "s/\[\">=25\"\]/['>=25']/" -e "s/\"typescript\"/'typescript'/" -e "s/\[\">=6.1.0\"\]/['>=6.1.0']/" "$d/.github/dependabot.yml"
rm -f "$d/.github/dependabot.yml.bak"
expect 0 "current: " "a block a formatter re-quoted stays current" -- dp --check "$d"

expect 0 "typescript-6.0" "TypeScript 7 crosses its hold" -- dp crosses npm typescript 7.0.2
expect 1 "" "TypeScript 6.0.3 does not cross" -- dp crosses npm typescript 6.0.3
expect 0 "node-24" "@types/node 26 crosses" -- dp crosses npm @types/node 26.6.4
expect 1 "" "a hold only applies to its ecosystem" -- dp crosses github-actions typescript 7.0.0

# The verify skill (#15) tells the reader to prefer `make check` and how to report Docker-less runs.
skill=$root/plugins/setkernel/skills/verify/SKILL.md
expect 0 "run \`make check\`" "the verify skill runs make check when the repo has the target" -- grep -F 'run `make check`' "$skill"
expect 0 "needs Docker (or OrbStack)" "the verify skill reports a Docker-less run as not run" -- grep -F 'needs Docker (or OrbStack)' "$skill"
expect 0 "Steps 3 and 4 apply either way" "the verify skill keeps the grep and setup steps with a check target" -- grep -F 'Steps 3 and 4 apply either way' "$skill"

# The suite passes with SETKERNEL_GUARD_NO_PUSH=1 in its environment (as in sk-agent runs). One nested run, not recursive.
if [ -z "${SETKERNEL_TESTS_NESTED:-}" ]; then
  expect 0 "passed" "the suite passes with SETKERNEL_GUARD_NO_PUSH=1 inherited" -- env SETKERNEL_TESTS_NESTED=1 SETKERNEL_GUARD_NO_PUSH=1 $sh_cmd "$root/tests/run.sh"
fi

echo "$((n - failures))/$n passed"
[ "$failures" -eq 0 ]
