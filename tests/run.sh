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
