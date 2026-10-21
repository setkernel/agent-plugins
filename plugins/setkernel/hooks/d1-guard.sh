#!/bin/sh
# PreToolUse (Bash): deny a remote D1 statement that writes or changes the schema, and any remote
# `--file` run (its SQL is not on the command line). Permission rules can't see the SQL: they match
# literal, case-sensitive text. Reads (`SELECT`, `PRAGMA table_info(x)`) and `--local` runs pass.
# The managed deny list holds `d1 migrations apply` (only for the `wrangler` and `npx wrangler`
# prefixes; this hook does not look at it) and `--remote` with `--file`, which this hook also denies;
# it is the only layer for `--remote --command "<write>"` (setkernel#18).
# POSIX sh (the agent VMs have no Node); jq (or sed) only to read the input. Fails open when the command is
# not a remote `d1 execute`. When the input is not JSON that jq can read (this includes a host
# without jq), the raw text is scanned, with its `\n` escapes turned back into line breaks, so a
# malformed payload that names a remote `d1 execute` write is still denied. Without jq, a payload
# with a `command` string is read with sed and judged like any other.
# SQL comments are not parsed, they are refused: a remote `d1 execute` with `/*` anywhere, or with
# `--` inside a quoted string that a line break follows, is denied, because a comment could split a
# phrase. A `--` outside quotes (wrangler's own flags, `echo -- x`) is not SQL and is ignored.
# Known gaps (a text match can't see them): indirection such as `--command "$SQL"` with SQL set in an
# earlier command, or `$(echo ... | base64 -d)`; quoting the words (`wrangler 'd1' execute`); and any
# write shape not listed below. Also not covered: `d1 delete` and `d1 time-travel restore`.
input=$(cat)
raw=0
if command -v jq >/dev/null 2>&1; then
  cmd=$(printf '%s' "$input" | jq -er 'if (.tool_name // "Bash") == "Bash" then (.tool_input.command // empty) else empty end' 2>/dev/null)
  if [ $? -ne 0 ]; then
    # jq failed: no command, another tool, or unreadable input. Only unreadable input is scanned raw.
    printf '%s' "$input" | jq -e . >/dev/null 2>&1 && exit 0
    raw=1
  fi
else
  # No jq (macOS before 15 ships none): pull the string values out with sed, as git-guard.sh does,
  # and undo their JSON escapes. A payload without a `command` string is scanned raw.
  field() {
    printf '%s' "$input" | tr '\n' ' ' |
      sed -n -E 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p'
  }
  tool=$(field tool_name)
  [ -z "$tool" ] || [ "$tool" = Bash ] || exit 0
  cmd=$(field command | sed -e 's/\\\\/@BS@/g' -e 's/\\n/\
/g' -e 's/\\t/ /g' -e 's/\\r/ /g' -e 's/\\"/"/g' -e 's/@BS@/\\/g')
  [ -n "$cmd" ] || raw=1
fi
if [ "$raw" = 1 ]; then
  cmd=$(printf '%s' "$input" | sed 's/\\n/\
/g')
fi

# Lower case, `\r` and tabs as spaces. `lines` keeps its line breaks; `text` is one line, with line
# breaks and backslashes as spaces (the shell drops a backslash before a line break inside double
# quotes), so spacing and line breaks can't split a phrase.
lines=$(printf '%s' "$cmd" | tr '\r\t' '  ' | tr 'A-Z' 'a-z')
text=$(printf '%s' "$lines" | tr '\n\\' '  ')

# Not a remote D1 statement: nothing to say.
printf '%s' "$text" | grep -Eq 'wrangler.*[[:space:]]d1[[:space:]]+execute' || exit 0
printf '%s' "$text" | grep -Eq -- '--remote' || exit 0

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

# SQL comments: refuse rather than parse. `/*` anywhere; `--` inside a quoted string that a line
# break follows (a backslash before the line break continues the command line, so it is not a break).
# A raw (unparseable) payload has no usable quoting, so there every `--` counts as inside quotes,
# except one that starts a wrangler flag name (`--remote`): so `--remote` followed by a line break in
# a malformed payload is a known gap.
printf '%s' "$text" | grep -Fq -- '/*' &&
  deny 'Blocked by the setkernel D1 guard: a remote wrangler d1 execute with a /* comment. Put the SQL on one line, without comments.'
printf '%s\n' "$lines" | awk -v raw="$raw" -v flags='^(remote|local|no-remote|command|json|config|env|yes|persist-to)([^a-z-]|$)' '
  { all = all $0 "\n" }
  END {
    q = raw ? "raw" : ""; dash = 0; n = length(all)
    for (i = 1; i <= n; i++) {
      c = substr(all, i, 1)
      if (c == "\\" && q != "raw" && q != "\047") { i++; continue }
      if (c == "\n") { if (q != "" && dash) exit 1; dash = 0; continue }
      if (q == "") { if (c == "\047" || c == "\"") q = c; continue }
      if (c == q) { q = ""; dash = 0; continue }
      if (c == "-" && substr(all, i + 1, 1) == "-" && !(raw && substr(all, i + 2, 20) ~ flags)) dash = 1
    }
  }' ||
  deny 'Blocked by the setkernel D1 guard: a remote wrangler d1 execute spread over lines with a -- comment. Put the SQL on one line, without comments.'

printf '%s' "$text" | grep -Eq -- '--file' &&
  deny 'Blocked by the setkernel D1 guard: a remote wrangler d1 execute --file run hides its SQL from review. Run reads with --command, or ask the owner to run the file.'

# The statement shapes that write or change the schema. W is a non-word character.
w='[^a-z0-9_]'
s='[[:space:]]+'
shapes="(^|$w)insert${s}(or${s}[a-z]+${s})?into($w|\$)"
shapes="$shapes|(^|$w)replace${s}into($w|\$)"
shapes="$shapes|(^|$w)update$w.*${w}set($w|\$)"
shapes="$shapes|(^|$w)delete${s}from($w|\$)"
shapes="$shapes|(^|$w)(drop|alter|create)${s}(temp|temporary|virtual|unique|table|index|view|trigger)($w|\$)"
shapes="$shapes|(^|$w)vacuum(${s}[^[:space:]]+)?${s}into($w|\$)"
shapes="$shapes|(^|$w)attach${s}(database${s})?.*${w}as($w|\$)"
shapes="$shapes|(^|$w)pragma${s}[a-z0-9_.]+[[:space:]]*="
printf '%s' "$text" | grep -Eq -- "$shapes" &&
  deny 'Blocked by the setkernel D1 guard: a remote wrangler d1 execute statement that writes or changes the schema. Test it with --local; schema changes go through a migration reviewed in a PR.'
exit 0
