#!/bin/sh
# Tests for check/check.sh and bin/generate. POSIX sh; needs jq for the generator tests.
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
check() { run_sh "$root/check/check.sh" "$@"; }

# A repository that follows the standard.
good_repo() {
  r=$tmp/$1
  mkdir -p "$r/.claude/skills/deploy" "$r/.claude/agents"
  {
    echo "# AGENTS.md"
    echo
    check --print-block
    echo
    echo "## What this repo is"
    echo "A fixture."
  } >"$r/AGENTS.md"
  printf '@AGENTS.md\n' >"$r/CLAUDE.md"
  echo "repo-specific" >"$r/.claude/skills/deploy/SKILL.md"
  echo "$r"
}

r=$(good_repo pass)
expect 0 "ok   AGENTS.md has the current pointer block" "a conforming repo passes" -- check "$r"

r=$(good_repo prose)
printf '# CLAUDE.md\n\nSee AGENTS.md.\n\n@AGENTS.md\n' >"$r/CLAUDE.md"
expect 0 "ok   CLAUDE.md imports @AGENTS.md" "CLAUDE.md with prose around the import passes" -- check "$r"

r=$(good_repo symlink)
rm "$r/CLAUDE.md" && ln -s AGENTS.md "$r/CLAUDE.md"
expect 0 "CLAUDE.md is a symlink to AGENTS.md" "CLAUDE.md symlinked to AGENTS.md passes" -- check "$r"

r=$(good_repo crlf)
sed 's/$/\r/' "$r/AGENTS.md" >"$r/AGENTS.tmp" && mv "$r/AGENTS.tmp" "$r/AGENTS.md"
expect 0 "ok   AGENTS.md has the current pointer block" "CRLF line endings pass" -- check "$r"

r=$(good_repo noblock)
printf '# AGENTS.md\n\n## Commands\n' >"$r/AGENTS.md"
expect 1 "FAIL AGENTS.md has no kit:core pointer block" "a missing pointer block fails" -- check "$r"

r=$(good_repo noagents)
rm "$r/AGENTS.md"
expect 1 "FAIL AGENTS.md is missing" "a missing AGENTS.md fails" -- check "$r"

r=$(good_repo stale)
sed 's/apply here/applied here/' "$r/AGENTS.md" >"$r/AGENTS.tmp" && mv "$r/AGENTS.tmp" "$r/AGENTS.md"
expect 1 "stale or edited" "an edited pointer block fails" -- check "$r"

r=$(good_repo oldkit)
printf '# AGENTS.md\n\n<!-- kit:core 1.1.0 start -->\n## Working rules\n<!-- kit:core end -->\n' >"$r/AGENTS.md"
expect 1 "stale or edited" "an agent-kit 1.1.0 core block fails as stale" -- check "$r"

r=$(good_repo twoblocks)
check --print-block >>"$r/AGENTS.md"
expect 1 "has 2 kit:core blocks" "two blocks fail" -- check "$r"

r=$(good_repo late)
{ printf '# AGENTS.md\n\n## Commands\n\n'; check --print-block; } >"$r/AGENTS.md"
expect 1 "move the kit:core pointer block to the top" "a block after the first section fails" -- check "$r"

r=$(good_repo noimport)
printf 'Read AGENTS.md\n' >"$r/CLAUDE.md"
expect 1 "FAIL CLAUDE.md does not import AGENTS.md" "CLAUDE.md without the import fails" -- check "$r"

r=$(good_repo indented)
printf '  @AGENTS.md is the file\n' >"$r/CLAUDE.md"
expect 1 "FAIL CLAUDE.md does not import AGENTS.md" "an import that is not a whole line fails" -- check "$r"

r=$(good_repo noclaude)
rm "$r/CLAUDE.md"
expect 1 "FAIL CLAUDE.md is missing" "a missing CLAUDE.md fails" -- check "$r"

r=$(good_repo copies)
mkdir -p "$r/.claude/skills/verify" "$r/.claude/skills/ship-pr" && touch "$r/.claude/agents/reviewer.md"
expect 1 "delete these): .claude/skills/ship-pr .claude/skills/verify .claude/agents/reviewer.md" \
  "hand-copied org skills and agents fail" -- check "$r"

r=$(good_repo linked)
ln -s ../../.agents/skills/verify "$r/.claude/skills/verify"
expect 1 "\.claude/skills/verify" "a dangling symlink to an org skill fails" -- check "$r"

expect 2 "usage" "an unknown option is a usage error" -- check --nope
expect 2 "not a directory" "a missing directory is a usage error" -- check "$tmp/does-not-exist"

# The generator: the committed files are current, and drift is detected.
expect 0 "generated files are current" "committed generated files are current" -- run_sh "$root/bin/generate" --check
cp -R "$root" "$tmp/copy"
rm -rf "$tmp/copy/.git"
printf '\nOne more rule.\n' >>"$tmp/copy/rules/org-rules.md"
expect 1 "stale: managed/settings.json" "a rules edit without regenerating is drift" -- run_sh "$tmp/copy/bin/generate" --check
expect 0 "wrote managed/settings.json" "regenerating writes the settings" -- run_sh "$tmp/copy/bin/generate"
expect 0 "generated files are current" "after regenerating there is no drift" -- run_sh "$tmp/copy/bin/generate" --check
expect 0 "One more rule.\"" "claudeMd carries the new rule" -- jq .claudeMd "$tmp/copy/managed/settings.json"
mkdir -p "$tmp/copy/plugins/setkernel/skills/new-skill"
expect 1 "ORG_SKILLS=\"new-skill review-blockers" "a new plugin skill lands in the checker" -- run_sh "$tmp/copy/bin/generate" --check

expect 1 "stale: plugins/setkernel/policy/holds.md" "a policy edit without regenerating is drift" -- \
  sh -c "jq '.holds[0].summary = \"changed\"' '$tmp/copy/policy/versions.json' >'$tmp/v.json' && mv '$tmp/v.json' '$tmp/copy/policy/versions.json' && sh '$tmp/copy/bin/generate' --check"

# The session hook prints the git state and the version holds.
hookrepo=$tmp/hookrepo
mkdir -p "$hookrepo" && git -C "$hookrepo" init -q
expect 0 "Version holds (setkernel org policy)" "the session hook prints the holds" -- \
  env CLAUDE_PROJECT_DIR="$hookrepo" sh "$root/plugins/setkernel/hooks/session-context.sh"
expect 0 "typescript-6.0" "the printed holds name each hold" -- \
  env CLAUDE_PROJECT_DIR="$hookrepo" sh "$root/plugins/setkernel/hooks/session-context.sh"

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
