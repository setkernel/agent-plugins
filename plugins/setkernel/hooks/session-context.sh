#!/bin/sh
# SessionStart: print the git state an agent would otherwise gather with several commands.
# Claude Code adds a SessionStart hook's stdout to the session context. Local git only, no
# network, POSIX sh (the agent VMs have no Node). Fails open: always exits 0.
holds="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/policy/holds.md"
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

branch=$(git branch --show-current 2>/dev/null)
head=$(git log -1 --format='%h %s (%cr)' 2>/dev/null)
echo "# Session context (setkernel plugin)"
echo "- Branch \`${branch:-(detached)}\` at ${head:-(no commits)}"

# --no-optional-locks keeps this from taking the index lock another agent's git command may need.
changed=$(git --no-optional-locks status --short 2>/dev/null)
if [ -n "$changed" ]; then
  n=$(printf '%s\n' "$changed" | wc -l | tr -d ' ')
  echo "- Working tree: $n changed path(s); treat changes you did not make as someone else's work:"
  printf '%s\n' "$changed" | head -n 15 | sed 's/^/  - /'
  [ "$n" -gt 15 ] && echo "  - … $((n - 15)) more (git status --short)"
else
  echo "- Working tree: clean"
fi
echo "- Follow the setkernel org rules and this repo's AGENTS.md; end with Blocked on owner / Changed / Found."

# The org version holds (generated from policy/versions.json; the plugin auto-updates from main).
if [ -r "$holds" ]; then
  echo
  cat "$holds"
fi
exit 0
