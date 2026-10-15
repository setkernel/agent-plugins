#!/bin/sh
# Tests for bin/generate, the session hook and bin/dependabot-policy. POSIX sh; needs jq for the generator tests.
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

# The org rules load into every session: keep them to the README's 40–60 lines (#23).
expect 0 "" "the org rules stay within 60 lines" -- test "$(wc -l <"$root/rules/org-rules.md")" -le 60

expect 1 "stale: plugins/setkernel/policy/holds.md" "a policy edit without regenerating is drift" -- \
  sh -c "jq '.holds[0].summary = \"changed\"' '$tmp/copy/policy/versions.json' >'$tmp/v.json' && mv '$tmp/v.json' '$tmp/copy/policy/versions.json' && sh '$tmp/copy/bin/generate' --check"

# The managed deny list: a secret closed to Read is closed to Edit too, a wrangler denial covers
# `npx wrangler` as well, and the example files stay open (a `!` rule carves only from rules before it).
deny_jq() { jq -er "(.permissions.deny) as \$d | $1" "$root/managed/settings.json"; }
missing='if . == [] then "none missing" else ("missing: " + join(", ")), false end'
expect 0 "none missing" "every Read denial has an Edit twin" -- \
  deny_jq "[\$d[] | select(startswith(\"Read(\")) | \"Edit(\" + .[5:]] - \$d | $missing"
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
# Without jq the guard still reads the command (macOS before 15 ships no jq).
nojq=$tmp/nojq
mkdir -p "$nojq"
for t in "${sh_cmd%% *}" sed tr git cat; do ln -s "$(command -v "$t")" "$nojq/$t"; done
expect 2 "blocked a force push" "without jq: a quoted force push is blocked" -- hook_on "$tmp/force.json" PATH="$nojq"
expect 0 "" "without jq: a feature-branch push passes" -- hook_on "$tmp/feat.json" PATH="$nojq"

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
