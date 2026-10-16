#!/bin/sh
# PreToolUse (Bash): deny a remote D1 statement that writes or changes the schema, and any remote
# `--file` run (its SQL is not on the command line). Permission rules can't see the SQL: they match
# literal, case-sensitive text. Reads (`SELECT`, `PRAGMA table_info(x)`) and `--local` runs pass.
# The managed deny list already holds `d1 migrations apply` and `--remote` with `--file`; this is
# the second layer for those and the only one for `--remote --command "<write>"` (setkernel#18).
# POSIX sh (the agent VMs have no Node); jq only to read the input. Fails open when the command is
# not a remote `d1 execute`. When the input is not JSON that jq can read (this includes a host
# without jq), the raw text is scanned, with its `\n` escapes turned back into line breaks, so a
# malformed payload that names a remote `d1 execute` write is still denied.
# SQL comments are not parsed, they are refused: a remote `d1 execute` with `/*` anywhere, or with
# `--` on a line that another line follows, is denied, because a comment could split a phrase.
# Known gaps (a text match can't see them): indirection such as `--command "$SQL"` with SQL set in an
# earlier command, or `$(echo ... | base64 -d)`; and any write shape not listed below.
input=$(cat)
cmd=$(printf '%s' "$input" | jq -er 'if (.tool_name // "Bash") == "Bash" then (.tool_input.command // empty) else empty end' 2>/dev/null)
if [ $? -ne 0 ]; then
  # jq failed: no command, another tool, or unreadable input. Only unreadable input is scanned raw.
  printf '%s' "$input" | jq -e . >/dev/null 2>&1 && exit 0
  cmd=$(printf '%s' "$input" | sed 's/\\n/\
/g')
fi

# Lower case, `\r` and tabs as spaces. `lines` keeps its line breaks; `text` is one line, so spacing
# and line breaks can't split a phrase.
lines=$(printf '%s' "$cmd" | tr '\r\t' '  ' | tr 'A-Z' 'a-z')
text=$(printf '%s' "$lines" | tr '\n' ' ')

# Not a remote D1 statement: nothing to say.
printf '%s' "$text" | grep -Eq 'wrangler.*[[:space:]]d1[[:space:]]+execute' || exit 0
printf '%s' "$text" | grep -Eq -- '--remote' || exit 0

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

# SQL comments: refuse rather than parse. `/*` anywhere; `--` on a line that another line follows
# (a backslash before the line break continues the command line, so it is not a break).
printf '%s' "$text" | grep -Fq -- '/*' &&
  deny 'Blocked by the setkernel D1 guard: a remote wrangler d1 execute with a /* comment. Put the SQL on one line, without comments.'
printf '%s\n' "$lines" | awk '
  { if (sub(/\\$/, "")) { buf = buf $0; next } n++; line[n] = buf $0; buf = "" }
  END { if (buf != "") line[++n] = buf; for (i = 1; i < n; i++) if (index(line[i], "--")) exit 1 }' ||
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
