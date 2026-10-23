#!/bin/sh
# SessionStart: load this seat's persona into the session (setkernel/agent-plugins#37).
# Off unless SETKERNEL_PERSONA=1, so a machine that still runs its own persona hook doesn't load it
# twice. A port of setkernel/hq's agents/vm/sk-persona.sh, which `allowManagedHooksOnly` stops.
#
# Key:    git config user.email, <name>@setkernel.com on each seat.
# Source: setkernel/hq agents/personas/<name>.md, fetched with this machine's own gh login. The
#         text is private (decision 0001): it never enters this repo and is kept only in an
#         owner-only cache: ${CLAUDE_PLUGIN_DATA:-${XDG_CACHE_HOME:-~/.cache}/setkernel}/persona,
#         used while younger than SETKERNEL_PERSONA_TTL minutes (360); 0 forces a fetch.
# Output: SessionStart JSON with hookSpecificOutput.additionalContext.
#
# Anything missing (no opt-in, no email, another domain, no gh or jq, no access, no such persona,
# network down with no fresh cache) means no persona: it prints nothing and exits 0. POSIX sh.
# No time limit of its own: Claude Code cancels it at the registered `timeout` (10 s), and a
# SessionStart hook that fails or times out doesn't block the session.
[ "${SETKERNEL_PERSONA:-}" = 1 ] || exit 0

# The hook's stdin carries the session JSON; it isn't needed, and gh must not read it.
exec 0</dev/null
repo=setkernel/hq
ttl=${SETKERNEL_PERSONA_TTL:-360}
case $ttl in '' | *[!0-9]*) ttl=360 ;; esac

# Only <name>@setkernel.com with a plain lowercase name: that name becomes a path.
name=$(git config user.email 2>/dev/null | tr '[:upper:]' '[:lower:]')
case $name in
  *@setkernel.com) name=${name%@setkernel.com} ;;
  *) exit 0 ;;
esac
case $name in '' | -* | *[!a-z0-9-]*) exit 0 ;; esac

command -v gh >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# The cache: sk-agent starts a session every few minutes, so fetch only when the copy is stale or
# missing. The dir is made owner-only even if it existed wider; if that fails (not ours), the cache
# is neither read nor written.
dir=${CLAUDE_PLUGIN_DATA:-${XDG_CACHE_HOME:-$HOME/.cache}/setkernel}/persona
file=$dir/$name.md
cache=
(umask 077 && mkdir -p "$dir" && chmod 700 "$dir") 2>/dev/null && cache=1
text=
# TTL 0 is decided here, not by find: BSD find -mmin -0 matches a file written this minute.
if [ -n "$cache" ] && [ "$ttl" -gt 0 ] && [ -n "$(find "$file" -mmin "-$ttl" 2>/dev/null)" ]; then
  text=$(cat "$file" 2>/dev/null)
fi
if [ -z "$text" ]; then
  text=$(GH_PROMPT_DISABLED=1 gh api -H 'Accept: application/vnd.github.raw+json' \
    "repos/$repo/contents/agents/personas/$name.md" 2>/dev/null) || exit 0
  [ -n "$text" ] || exit 0
  # Write then rename, so a concurrent session never reads half a file.
  if [ -n "$cache" ]; then
    (umask 077 && printf '%s\n' "$text" >"$file.$$" && mv -f "$file.$$" "$file") 2>/dev/null || rm -f "$file.$$"
  fi
fi

printf '%s\n\n%s\n' \
  "Your persona (from $repo agents/personas/$name.md, private: never copy it into a public repo, issue or PR). It shapes how you approach work and what you look for in review, not what you are allowed to do." \
  "$text" |
  jq -Rs '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: .}}' 2>/dev/null
exit 0
