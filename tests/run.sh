#!/bin/sh
# Tests for bin/generate, the session hook, the verify gate, the D1 guard and bin/dependabot-policy. POSIX sh; needs jq for the generator tests.
# Usage: tests/run.sh            (set SHELL_UNDER_TEST=dash or "busybox sh" to try other shells)
set -eu

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

# The committed org rules give each Claude environment its branch prefix and signature (#16).
for marker in '`raghav-dev/<topic>`, `— raghav-dev`' '`claude/<topic>`, `— Claude Cloud`' '`lead/<topic>`, `— Claude Lead`' '`agent/<issue>-<slug>`'; do
  expect 0 "$marker" "claudeMd's Who did it names $marker" -- jq -r .claudeMd "$root/managed/settings.json"
done

# The committed org rules carry the self-hosted Google Fonts rule (#20).
for marker in '## Fonts' 'self-hosted' '`fonts.googleapis.com`' '`FONTCONFIG_FILE`' 'Arimo for Arial'; do
  expect 0 "$marker" "claudeMd's Fonts names $marker" -- jq -r .claudeMd "$root/managed/settings.json"
done

# The committed org rules carry the v4 merge quorum in place of "every PR needs Raghav's review" (#25).
for marker in "in force as each repo's gate is qualified" 'R0: one non-author' 'R1: that plus an independent Codex review' \
  'R2: two approvals, Codex and a visual diff' 'R3 (secrets, auth, money, DNS and tofu' 'R2 plus Raghav'"'"'s `/approve <sha>`' \
  'never merge your$' 'only the merge App merges' 'never counts as a Claude reviewer' 'decision 0007'; do
  expect 0 "$marker" "claudeMd's Changes names $marker" -- jq -r .claudeMd "$root/managed/settings.json"
done
expect 1 '^0$' "claudeMd drops the old review-before-merge rule" -- \
  sh -c "jq -r .claudeMd '$root/managed/settings.json' | grep -c 'review before merge'"

expect 1 "stale: plugins/setkernel/policy/holds.md" "a policy edit without regenerating is drift" -- \
  sh -c "jq '.holds[0].summary = \"changed\"' '$tmp/copy/policy/versions.json' >'$tmp/v.json' && mv '$tmp/v.json' '$tmp/copy/policy/versions.json' && sh '$tmp/copy/bin/generate' --check"

# The managed deny list: a secret closed to Read is closed to Edit too, a wrangler denial covers
# `npx wrangler` as well, and the example files stay open (a `!` rule carves only from rules before it).
deny_jq() { jq -er "(.permissions.deny) as \$d | $1" "$root/managed/settings.json"; }
missing='if . == [] then "none missing" else ("missing: " + join(", ")), false end'
expect 0 "none missing" "every Read denial has an Edit twin" -- \
  deny_jq "[\$d[] | select(startswith(\"Read(\")) | \"Edit(\" + .[5:]] - \$d | $missing"
expect 0 "none missing" "every wrangler denial has an npx wrangler twin" -- \
  deny_jq "[\$d[] | select(startswith(\"Bash(wrangler \")) | \"Bash(npx \" + .[5:]] - \$d | $missing"
expect 0 "none missing" "remote D1 migrations and remote --file runs are denied" -- \
  deny_jq "[\"Bash(wrangler d1 migrations apply:*)\", \"Bash(wrangler d1 execute *--remote*--file*)\", \"Bash(wrangler d1 execute *--file*--remote*)\"] - \$d | $missing"
expect 0 "none missing" ".dev.vars.* is denied and the example files are carved out" -- \
  deny_jq "[\"Read(./.dev.vars.*)\", \"Read(!.env.example)\", \"Read(!.dev.vars.example)\"] - \$d | $missing"
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

# The D1 guard (PreToolUse) denies remote D1 writes and remote --file runs; everything else passes (#18).
guard=$root/plugins/setkernel/hooks/d1-guard.sh
# hook <stdin-text>: feed the text to the guard on stdin.
hook() { printf '%s' "$1" | run_sh "$guard"; }
# bash_in <command>: the PreToolUse JSON for a Bash command.
bash_in() { jq -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}'; }
deny='"permissionDecision":"deny"'
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
expect 0 "$deny" "the guard denies a write whose line breaks are escaped in a malformed payload" -- hook 'not json: wrangler d1 execute db --remote --command "select 1\nupdate t set a = 1"'
expect 0 "$deny" "the guard denies a remote write after an escaped line break in a malformed payload" -- hook 'not json: wrangler d1 execute db --remote --command "x\ndelete\nfrom t"'
expect 0 "$deny" "the guard denies a -- comment that splits a write in a malformed payload" -- hook 'not json: wrangler d1 execute db --remote --command "delete -- x\nfrom t"'
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
expect 0 "$deny" "the guard denies a remote D1 write inside a malformed payload" -- hook 'not json: wrangler d1 execute db --remote --command "DROP TABLE t"'
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
grepo=$tmp/gaterepo
mkdir -p "$grepo/tools" && git -C "$grepo" init -q
# A Makefile in the shape of setkernel/hq's template: STEPS, PASS/FAIL per step, a summary line.
# The test step fails while the file `red` exists; every run is counted in $tmp/gate-runs.
cat >"$grepo/Makefile" <<'EOF'
STEPS = lint test
check:
	@sh tools/check.sh $(STEPS)
lint:
	@echo lint is fine
test:
	@echo 'assertion "x" \ failed'; test ! -f red
EOF
cat >"$grepo/tools/check.sh" <<EOF
echo run >>"$tmp/gate-runs"
pass=0; fail=0; failed=""
for step in "\$@"; do
  echo "== \$step"
  if make --no-print-directory "\$step"; then echo "PASS \$step"; pass=\$((pass + 1)); else echo "FAIL \$step"; fail=\$((fail + 1)); failed="\$failed \$step"; fi
done
echo "== \$pass passed, \$fail failed\${failed:+:\$failed}"
[ "\$fail" -eq 0 ]
EOF
printf 'red\n' >"$grepo/.gitignore"
git -C "$grepo" add -A && git -C "$grepo" -c user.name=t -c user.email=t@example.com commit -qm init
gstate=$tmp/gate-state
# gate <mode> <hook-input-json> [VAR=value...]: run the hook as Claude Code would.
gate() {
  m=$1 j=$2
  shift 2
  printf '%s' "$j" | env CLAUDE_PROJECT_DIR="$grepo" CLAUDE_PLUGIN_DATA="$gstate" SETKERNEL_VERIFY_GATE=1 "$@" $sh_cmd "$gate" "$m"
}
runs() { if [ -f "$tmp/gate-runs" ]; then wc -l <"$tmp/gate-runs" | tr -d ' '; else echo 0; fi; }
in_stop='{"session_id":"s1","hook_event_name":"Stop","permission_mode":"bypassPermissions","stop_hook_active":false,"last_assistant_message":"done, \"agent_type\": \"reviewer\""}'

expect 0 "hooks/verify-gate.sh\\\\\" stop" "hooks.json runs the gate on Stop" -- jq -r '.hooks.Stop[0].hooks[0].command | @json' "$root/plugins/setkernel/hooks/hooks.json"
expect 0 "hooks/verify-gate.sh\\\\\" start" "hooks.json records the baseline on SessionStart" -- jq -r '[.hooks.SessionStart[0].hooks[].command] | @json' "$root/plugins/setkernel/hooks/hooks.json"
expect 0 '^$' "SessionStart: the gate prints nothing into the context" -- sh -c "printf '%s' '{\"session_id\":\"s1\"}' | env CLAUDE_PROJECT_DIR='$grepo' CLAUDE_PLUGIN_DATA='$gstate' SETKERNEL_VERIFY_GATE=1 $sh_cmd '$gate' start; echo"
touch "$grepo/red"
expect 0 '^$' "a session that changed nothing is not gated (read-only run)" -- gate stop "$in_stop"
expect 0 "^0$" "and its check did not run" -- runs
printf 'change\n' >"$grepo/new.txt"
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
expect 0 "This is the last block" "the third block says it is the last" -- sh -c "gate_out=\$(printf '%s' '$in_stop' | env CLAUDE_PROJECT_DIR='$grepo' CLAUDE_PLUGIN_DATA='$gstate' SETKERNEL_VERIFY_GATE=1 $sh_cmd '$gate' stop) && printf '%s' \"\$gate_out\" | jq -er .reason"
gate stop "$in_stop" >"$tmp/gate-out" || true
expect 1 "" "after 3 blocks the run may stop" -- grep '"decision"' "$tmp/gate-out"
expect 0 "fails (exit 2, failing: test) after 3 blocks" "and the failure is reported to the user" -- jq -er .systemMessage "$tmp/gate-out"
expect 0 "block 1 of 3" "a later stop starts a new round of blocks" -- sh -c "printf '%s' '$in_stop' | env CLAUDE_PROJECT_DIR='$grepo' CLAUDE_PLUGIN_DATA='$gstate' SETKERNEL_VERIFY_GATE=1 $sh_cmd '$gate' stop | jq -er .reason"
expect 0 "block 1 of 1" "SETKERNEL_VERIFY_GATE_MAX sets the limit" -- sh -c "printf '%s' '{\"session_id\":\"s2\"}' | env CLAUDE_PROJECT_DIR='$grepo' CLAUDE_PLUGIN_DATA='$gstate' SETKERNEL_VERIFY_GATE=1 SETKERNEL_VERIFY_GATE_MAX=1 $sh_cmd '$gate' stop | jq -er .reason"
rm -f "$grepo/red"
before=$(runs)
expect 0 '^$' "make check green: the run stops" -- gate stop "$in_stop"
expect 0 "^$((before + 1))$" "green ran the check once" -- runs
expect 0 '^$' "a tree that already passed is not checked again" -- gate stop "$in_stop"
expect 0 "^$((before + 1))$" "so the check did not rerun" -- runs
printf 'more\n' >>"$grepo/new.txt"
expect 0 '^$' "an edit after green reruns the check" -- gate stop "$in_stop"
expect 0 "^$((before + 2))$" "which ran once more" -- runs
expect 0 '"decision":"block"' "SETKERNEL_VERIFY_CMD overrides make check" -- gate stop '{"session_id":"s3"}' SETKERNEL_VERIFY_CMD='echo boom; exit 1'
expect 0 "boom" "and without a step summary the reason ends with the output" -- sh -c "printf '%s' '{\"session_id\":\"s3\"}' | env CLAUDE_PROJECT_DIR='$grepo' CLAUDE_PLUGIN_DATA='$gstate' SETKERNEL_VERIFY_GATE=1 SETKERNEL_VERIFY_CMD='echo boom; exit 1' $sh_cmd '$gate' stop | jq -er .reason"
expect 0 '^$' "a repo without a check target is not gated" -- \
  sh -c "printf '%s' '{\"session_id\":\"s4\"}' | env CLAUDE_PROJECT_DIR='$hookrepo' CLAUDE_PLUGIN_DATA='$gstate' SETKERNEL_VERIFY_GATE=1 $sh_cmd '$gate' stop"
mkdir -p "$tmp/nogit"
expect 0 '^$' "outside a git repo the gate lets the run stop" -- \
  sh -c "printf '%s' '{\"session_id\":\"s4\"}' | env CLAUDE_PROJECT_DIR='$tmp/nogit' CLAUDE_PLUGIN_DATA='$gstate' SETKERNEL_VERIFY_GATE=1 $sh_cmd '$gate' stop"
expect 0 "" "the repo's own index is untouched" -- git -C "$grepo" diff --cached --quiet

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

echo "$((n - failures))/$n passed"
[ "$failures" -eq 0 ]
