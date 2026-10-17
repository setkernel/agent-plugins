#!/bin/sh
# verify-gate: keep a run from finishing while the repo's check fails (setkernel/agent-plugins#31).
#   sh verify-gate.sh start   SessionStart: remember the tree the session started from. Prints nothing.
#   sh verify-gate.sh stop    Stop: run the repo's check; while it fails, block with the failing step.
# Off unless SETKERNEL_VERIFY_GATE=1 (it reaches every seat on merge; canary it first).
# The check is SETKERNEL_VERIFY_CMD, else `make check` when the Makefile has a check target (the
# org's one check command, docs/repo-standard.md in setkernel/hq). No check: nothing to gate.
# Skipped for read-only runs: plan mode, the explorer/reviewer/Explore/Plan agents, and a session
# whose tree is unchanged since it started. Blocks at most SETKERNEL_VERIFY_GATE_MAX times (3),
# then lets the run stop with the failure reported. Reads the hook JSON on stdin; POSIX sh, no jq.
# Fails open: anything unexpected (no git, no state dir) lets the run stop.
mode=${1:-stop}
[ "${SETKERNEL_VERIFY_GATE:-}" = 1 ] || exit 0

input=$(tr -d '\n\r')
# field <name>: a string field of the hook input (ids, modes and agent names only).
field() {
  printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([A-Za-z0-9_:.-]*\)\".*/\1/p"
}
sid=$(field session_id)
case $sid in '' | *[!A-Za-z0-9_-]*) sid=unknown ;; esac

cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$top" || exit 0
state=${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}/setkernel}/verify-gate
mkdir -p "$state" 2>/dev/null || exit 0
key=$state/$sid

# tree_id: the git tree of the working tree as it is, untracked files included, ignored ones not.
# Uses a copy of the index so the repo's own index is never touched.
tree_id() {
  idx=$key.index.$$
  src=$(git rev-parse --git-path index 2>/dev/null)
  if [ -f "$src" ]; then cp "$src" "$idx" 2>/dev/null || return 1; else rm -f "$idx"; fi
  GIT_INDEX_FILE=$idx git add -A >/dev/null 2>&1 && GIT_INDEX_FILE=$idx git write-tree 2>/dev/null
  rc=$?
  rm -f "$idx" "$idx.lock"
  return "$rc"
}

if [ "$mode" = start ]; then
  # Keep the first baseline: a resume or compaction must not hide edits made earlier in the session.
  find "$state" -type f -mtime +7 -exec rm -f {} + 2>/dev/null
  [ -s "$key.base" ] || tree_id >"$key.base" 2>/dev/null
  exit 0
fi

[ "$(field permission_mode)" = plan ] && exit 0
case $(field agent_type) in
  explorer | reviewer | setkernel:explorer | setkernel:reviewer | Explore | Plan) exit 0 ;;
esac

cmd=${SETKERNEL_VERIFY_CMD:-}
if [ -z "$cmd" ]; then
  # make reads the first of these that exists, so only that one decides.
  for mf in GNUmakefile makefile Makefile; do
    [ -f "$mf" ] || continue
    grep -q '^check[[:space:]]*:' "$mf" && cmd="make check"
    break
  done
fi
[ -n "$cmd" ] || exit 0

tree=$(tree_id) || tree=""
if [ -n "$tree" ]; then
  [ "$tree" = "$(cat "$key.base" 2>/dev/null)" ] && exit 0 # changed nothing: a read-only run
  [ "$tree" = "$(cat "$key.pass" 2>/dev/null)" ] && exit 0 # this tree already passed
fi

max=${SETKERNEL_VERIFY_GATE_MAX:-3}
case $max in '' | *[!0-9]*) max=3 ;; esac
blocks=$(cat "$key.blocks" 2>/dev/null)
case $blocks in '' | *[!0-9]*) blocks=0 ;; esac

log=$key.log
sh -c "$cmd" >"$log" 2>&1 </dev/null
status=$?
if [ "$status" -eq 0 ]; then
  [ -n "$tree" ] && printf '%s\n' "$tree" >"$key.pass"
  rm -f "$key.blocks"
  exit 0
fi

# The failing steps, from tools/check.sh's last line: "== 1 passed, 2 failed: lint test".
steps=$(sed -n 's/^== [0-9]* passed, [0-9]* failed: *//p' "$log" | tail -n 1)
# excerpt: the last 20 lines of each failing step's section, or the end of the output.
excerpt() {
  if [ -n "$steps" ]; then
    awk -v steps=" $steps " '
      /^== / { name = substr($0, 4); on = index(steps, " " name " ") > 0; n = 0; next }
      on && $0 == "FAIL " name { print "--- " name; s = n > 20 ? n - 20 : 0; for (i = s + 1; i <= n; i++) print buf[i]; on = 0; next }
      on { buf[++n] = $0 }' "$log"
  else
    tail -n 40 "$log"
  fi
}
# json_str: stdin as a JSON string. Printable ASCII only, so odd bytes in check output can't break it.
json_str() {
  LC_ALL=C tr -d '\r' | LC_ALL=C tr '\t' ' ' | LC_ALL=C tr -cd '\012\040-\176' | cut -c1-300 |
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'BEGIN { printf "\"" } { printf "%s%s", (NR > 1 ? "\\n" : ""), $0 } END { printf "\"" }'
}
what="\`$cmd\` fails (exit $status${steps:+, failing: $steps})"

if [ "$blocks" -ge "$max" ]; then
  rm -f "$key.blocks"
  printf '{"systemMessage":%s}\n' "$(printf 'setkernel verify gate: %s after %s blocks; letting the run stop with it failing. Output: %s' \
    "$what" "$max" "$log" | json_str)"
  exit 0
fi
blocks=$((blocks + 1))
printf '%s\n' "$blocks" >"$key.blocks"
if [ "$blocks" -ge "$max" ]; then
  next="This is the last block: if you stop again with it failing, the run ends, and your report must give the check as fail with the failing step."
else
  next="After $max blocks the run may stop, and its report must give the check as fail."
fi
{
  echo "setkernel verify gate (block $blocks of $max): $what in $top, so this run can't finish as done."
  excerpt | head -n 80
  echo "Full output: $log"
  echo "Fix it and stop again; the gate reruns the check. If the failure is not yours to fix (it fails on the default branch too, or needs the owner), say so and report the check as fail. $next"
} >"$key.reason"
printf '{"decision":"block","reason":%s}\n' "$(json_str <"$key.reason")"
exit 0
