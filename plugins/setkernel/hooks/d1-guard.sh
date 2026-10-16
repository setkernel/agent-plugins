#!/bin/sh
# PreToolUse (Bash): deny a remote D1 statement that writes or changes the schema, and any remote
# `--file` run (its SQL is not on the command line). Permission rules can't see the SQL: they match
# literal, case-sensitive text. Reads (`SELECT`, `PRAGMA table_info(x)`) and `--local` runs pass.
# The managed deny list already holds `d1 migrations apply` and `--remote` with `--file`; this is
# the second layer for those and the only one for `--remote --command "<write>"` (setkernel#18).
# POSIX sh (the agent VMs have no Node); jq only to read the input. Fails open when the command is
# not a remote `d1 execute`. When the input is not JSON that jq can read, the raw text is scanned,
# so a malformed payload that names a remote `d1 execute` write is still denied.
input=$(cat)
cmd=$(printf '%s' "$input" | jq -er 'if (.tool_name // "Bash") == "Bash" then (.tool_input.command // empty) else empty end' 2>/dev/null)
if [ $? -ne 0 ]; then
  # jq failed: no command, another tool, or unreadable input. Only unreadable input is scanned raw.
  printf '%s' "$input" | jq -e . >/dev/null 2>&1 && exit 0
  cmd=$input
fi

# One line, lower case, SQL block comments gone, so spacing and `/**/` can't split a phrase.
text=$(printf '%s' "$cmd" | tr '\n\r\t' '   ' | sed 's#/\*[^*]*\*/# #g' | tr 'A-Z' 'a-z')

# Not a remote D1 statement: nothing to say.
printf '%s' "$text" | grep -Eq 'wrangler.*[[:space:]]d1[[:space:]]+execute' || exit 0
printf '%s' "$text" | grep -Eq -- '--remote' || exit 0

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

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
shapes="$shapes|(^|$w)pragma${s}[a-z0-9_.]+[[:space:]]*="
printf '%s' "$text" | grep -Eq -- "$shapes" &&
  deny 'Blocked by the setkernel D1 guard: a remote wrangler d1 execute statement that writes or changes the schema. Test it with --local; schema changes go through a migration reviewed in a PR.'
exit 0
