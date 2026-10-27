# scrub.awk: git-guard.sh runs it with awk -f in no-push mode. It reads a command line on stdin and
# prints it the way the shell reads it, then each $(…) command on a line of its own; it exits 1 on
# text it cannot read. Text that is only data is not checked as a command. A heredoc body is dropped
# unless a shell reads it: the
# command that reads it runs one (`bash <<EOF`, `. /dev/stdin <<EOF`), or a later command in its
# pipeline (`cat <<EOF | sh`), or a command it is a $(…) in (`bash -c "$(cat <<EOF …)"`); a shell
# word elsewhere on the line (`source venv && git commit -F - <<EOF`) doesn't count. An unquoted body
# keeps its $(…) and backticks, which the shell runs. Quoted and escaped text stays one word: its
# blanks, operators, quotes and backslashes become control characters (decode turns them back), and
# so do { and } unless they are reserved words (`git -C ${dir} push`, `-exec git -C {} push`).
# A $(…) or backtick, quoted or not, is left in its word as the character \023 ($ph) and its command
# is checked on a line of its own after the rest (`git -C "$(pwd)" push` still reads as a push).
# A $((…)) is checked that way too: bash runs `$((git push) 2>&1)` as a command, and arithmetic never
# reads as a push. Comments are dropped, but not a # inside ${…}, where it is text. A here-string a
# shell reads is kept as commands, its quotes and escapes decoded (`bash <<< git\ push`), up to the
# end of that command, and a pipe into a shell after text that names a git push adds a `git push`
# line. On text it can't read (an unclosed quote, $(…) or ${…}, or a backtick nested in a backtick)
# it exits 1, and check_cmd checks the raw text instead, as it does without the variable.
# It prints the scrubbed command line, then the commands found inside $(…) one per line; exit 1 means it could not read the text.
function enc(c) { return (c in E) ? E[c] : c }
function quo(c) { return raw ? c : enc(c) }
function emit(x) { buf[lv] = buf[lv] x }
function emitc(x) { buf[lv] = buf[lv] x; cv = cv x }
function shellword(t) {
  return (" " t " ") ~ /[^A-Za-z0-9_.-]((ba|z|da|k)?sh|eval|source)[^A-Za-z0-9_]/ || (";" t) ~ /[;&|(][ \t]*\.[ \t]/
}
# readsh(t): true if the simple command t (scrubbed text) runs a shell: one of its words is a shell,
# eval or source, or its command word is `.`. A redirection and its target are not words, glued or
# not (`sh<<EOF`, `sh 2>&1`, `cat >/tmp/sh`).
function readsh(t,   w, n, k, f) {
  gsub(/<<<[ \t]*[^ \t;&|<>()]*/, " ", t); gsub(/<<-?/, " ", t)
  gsub(/(&>>?|[<>]&|>>|<>|>[|]?|<)[ \t]*[^ \t;&|<>()]*/, " ", t)
  n = split(t, w, /[ \t]+/); f = 1
  for (k = 1; k <= n; k++) {
    if (w[k] == "") continue
    if (f && w[k] ~ /^([A-Za-z_][A-Za-z0-9_]*=.*|!|then|do|else|elif|if|while|until|time)$/) continue
    if (f && w[k] == ".") return 1
    f = 0
    if (w[k] ~ /^([^\/]*\/)*((ba|z|da|k)?sh|eval|source)$/) return 1
  }
  return 0
}
# segat(b): where the simple command at the end of the scrubbed text b starts. The & of a
# redirection (2>&1, <&3, &>f) does not end a command.
function segat(b,   k, c) {
  for (k = length(b); k > 0; k--) {
    c = substr(b, k, 1)
    if (c == "&" && (substr(b, k - 1, 1) ~ /[<>]/ || substr(b, k + 1, 1) == ">")) continue
    if (index(";&|\n({", c)) break
  }
  return k
}
# hreads(j, hdr): true if a shell reads heredoc j, decided at the end of its header line hdr: its
# command or a later one in its pipeline runs a shell, or a command it is a $(…) or backtick in does
# (bash -c "$(cat <<EOF …)"). Where the command is hard to tell (after a } or ), or the $(…) it was
# in has closed), any shell word on the header line counts, as before.
function hreads(j, hdr,   p, q, m, k) {
  if (PL[j] > lv || PG[j] != GEN[PL[j]]) return shellword(hdr)
  # The & of a redirection or of |& (a pipe that takes stderr too) does not end the command.
  p = substr(buf[PL[j]], PS[j] + 1); gsub(/[<>]&|&>/, ">", p); gsub(/[|]&/, "|", p)
  if (match(p, /[;&\n]/)) p = substr(p, 1, RSTART - 1)
  if (p ~ /[)}]/) return shellword(hdr)
  m = split(p, q, "|")
  for (k = 1; k <= m; k++) if (readsh(q[k])) return 1
  for (k = PL[j] - 1; k >= 1; k--) if (readsh(substr(buf[k], segat(buf[k]) + 1))) return 1
  return 0
}
function nest() { lv++; buf[lv] = ""; CZ[lv] = 0; GEN[lv]++ }
function lineof(p) { while (ln < nl && O[ln + 1] <= p) ln++; return ln }
function pop(st) { return substr(st, 1, length(st) - 1) }
# lex(text, mode): mode C reads a command line, mode H an unquoted heredoc body. The stack st holds
# a letter per open context: S single quote, A dollar-single quote, D double quote, P $(, R $((,
# G a ( inside $( or $((, B a backtick, V a ${ outside quotes, W a ${ inside them. Output goes to
# buf[lv]; each $(…), $((…)) and backtick opens the next level and, when it closes, adds that level
# to the lines after the rest (subs).
function lex(s, mode,   st, t, i, n, c, d, ws, k, m, e, j, p, dq, dash, body, cmp, hdr, hl, save, base, cs, keep) {
  nest(); base = lv
  st = mode; n = length(s); ws = 1; cs = 1
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1); t = substr(st, length(st))
    # In a backtick the shell drops the backslash before ` and $ and reads the text again, so \` there
    # opens a nested backtick and \$( a $(: too hard to follow, so the raw text is checked instead.
    if (c == "\\" && index(st, "B") && t != "S" && t != "A" && substr(s, i + 1, 1) ~ /[`$]/) bad = 1
    if (t == "S") { if (c == "\047") st = pop(st); else emit(quo(c)); continue }
    if (t == "A") {
      if (c == "\047") st = pop(st)
      else if (c == "\\") { i++; d = substr(s, i, 1); emit(quo(d == "n" ? "\n" : d == "t" ? "\t" : d)) }
      else emit(quo(c))
      continue
    }
    if (t == "D" || t == "H") {
      if (c == "\"" && t == "D") { st = pop(st); continue }
      if (c == "\\") {
        d = substr(s, i + 1, 1)
        if (d == "\n") i++
        else if (d == "$" || d == "`" || d == "\\" || (d == "\"" && t == "D")) { emit(quo(d)); i++ }
        else emit(quo(c))
        continue
      }
      if (c != "`" && !(c == "$" && substr(s, i + 1, 1) ~ /[({]/)) { emit(quo(c)); continue }
    }
    # In ${…} quotes, escapes, $(…) and backticks are read as in a command, the first } outside them
    # ends it, and # is text, not a comment (echo ${x:-a #b}; git push runs the push).
    if (t == "V" || t == "W") {
      if (c == "}") { st = pop(st); ws = 0 }
      if (c == "}" || index("\\\047\"`$", c) == 0) { if (t == "W") emit(quo(c)); else emitc(enc(c)); continue }
    }
    if (c == "$" && substr(s, i + 1, 1) == "{") {
      if (t == "D" || t == "H" || t == "W") { emit("$" quo("{")); st = st "W" } else { emitc("$" enc("{")); st = st "V" }
      i++; ws = 0; continue
    }
    # The rest is read as commands.
    if (c == "$" && substr(s, i + 1, 2) == "((") { emitc(PH); nest(); st = st "R"; i += 2; ws = 1; continue }
    if (c == "$" && substr(s, i + 1, 1) == "(") { emitc(PH); nest(); st = st "P"; i++; ws = 1; continue }
    if (c == "`" && t == "B") { subs = subs "\n" buf[lv]; lv--; st = pop(st); ws = 0; continue }
    if (c == "`") { emitc(PH); nest(); st = st "B"; ws = 1; continue }
    if (c == "\\") { i++; d = substr(s, i, 1); if (d != "\n") { emitc(quo(d)); ws = 0 }; continue }
    if (c == "\047") { st = st "S"; ws = 0; continue }
    if (c == "\"") { st = st "D"; ws = 0; continue }
    if (c == "$" && substr(s, i + 1, 1) == "\047") { st = st "A"; i++; ws = 0; continue }
    if (c == "(") { emitc(c); ws = 1; if (t == "P" || t == "G" || t == "R") st = st "G"; continue }
    # A case pattern ends in ) too: inside $(…) it does not close the $(.
    if (ws && substr(s, i, 4) == "case" && substr(s, i + 4, 1) ~ /[ \t]/) CZ[lv]++
    if (ws && substr(s, i, 4) == "esac" && substr(s, i + 4, 1) !~ /[A-Za-z0-9_]/ && CZ[lv] > 0) CZ[lv]--
    if (c == ")" && t == "P" && CZ[lv] > 0) { emitc(c); ws = 1; continue }
    if (c == ")" && t == "P") { subs = subs "\n" buf[lv]; lv--; st = pop(st); ws = 0; continue }
    if (c == ")" && t == "R") { subs = subs "\n" buf[lv]; lv--; st = pop(st); if (substr(s, i + 1, 1) == ")") i++; ws = 0; continue }
    if (c == ")") { emitc(c); ws = 1; if (t == "G") st = pop(st); continue }
    if (c == "#" && ws) { while (i < n && substr(s, i + 1, 1) != "\n") i++; continue }
    # A here-string a shell reads is kept as commands, up to the end of that command. Where it comes
    # before the command word (<<<"…" bash), any shell word on the line counts.
    if (substr(s, i, 3) == "<<<") {
      if (mode == "C") {
        p = substr(buf[lv], segat(buf[lv]) + 1); e = p; gsub(/[A-Za-z_][A-Za-z0-9_]*=[^ \t]*/, "", e)
        if ((p ~ /[)}]/ || e !~ /[^ \t]/) ? shellword(L[lineof(i)]) : readsh(p)) { raw = 1; rawlv = lv }
      }
      emitc("<<<"); i += 2; ws = 1
      continue
    }
    if (substr(s, i, 2) == "<<" && mode == "C" && index(st, "R") == 0) {
      k = i + 2; dash = 0; d = ""; dq = 0
      if (substr(s, k, 1) == "-") { dash = 1; k++ }
      while (substr(s, k, 1) == " " || substr(s, k, 1) == "\t") k++
      while (k <= n) {
        c = substr(s, k, 1)
        if (index(" \t\n;&|<>()", c)) break
        if (c == "\047" || c == "\"") {
          e = index(substr(s, k + 1), c)
          if (!e) break
          d = d substr(s, k + 1, e - 1); k += e + 1; dq = 1; continue
        }
        if (c == "\\") { d = d substr(s, k + 1, 1); k += 2; dq = 1; continue }
        d = d c; k++
      }
      if (d != "") { np++; PD[np] = dash; PQ[np] = dq; PW[np] = d; PL[np] = lv; PG[np] = GEN[lv]; PS[np] = segat(buf[lv]) }
      emitc("<<"); ws = 1
      if (d != "") i = k - 1; else i++
      continue
    }
    if (c == "\n") {
      emitc(c); ws = 1; raw = 0; rawlv = -1; cs = i + 1; hdr = cv; cv = ""
      if (np == 0 || mode != "C") continue
      # The heredoc bodies start on the next line. Skip them unless a shell reads them (hreads), or
      # the header line ends in a pipe and the line after the last body runs one. If a body has no
      # end line, the bodies are read as commands.
      keep = 0
      for (j = 1; j <= np; j++) if (hreads(j, hdr)) keep = 1
      hl = lineof(i); k = hl
      for (j = 1; j <= np; j++) {
        dash = PD[j]; dq = PQ[j]; d = PW[j]; body = ""
        for (m = k + 1; m <= nl; m++) {
          cmp = L[m]
          if (dash == "1") sub(/^\t+/, "", cmp)
          if (cmp == d) break
          body = body (m > k + 1 ? "\n" : "") L[m]
        }
        if (m > nl) { k = hl; break }
        if (dq == "0") { save = raw; raw = 0; lex(body, "H"); raw = save }
        k = m
      }
      np = 0; cv = ""
      if (k > hl && !keep && !(hdr ~ /\|&?[ \t\n]*$/ && shellword(L[k + 1]))) i = O[k] + length(L[k]) - 1
      continue
    }
    # A pipe into a shell: the shell runs what the commands before it print, so a git push anywhere
    # in their text counts (`echo "git push" | bash`).
    if (c == "|" && mode == "C" && substr(s, i + 1, 1) != "|" && substr(s, i - 1, 1) != "|") {
      e = substr(s, i + 1); k = index(e "\n", "\n")
      if (substr(e, 1, k - 1) ~ /^[ \t\\]*$/) k += index(substr(e, k + 1) "\n", "\n") # the shell is on the next line
      e = substr(e, 1, k - 1); gsub(/\\?\n/, " ", e)
      if (e ~ PIPESH && (" " substr(s, cs, i - cs) " ") ~ GITPUSH) subs = subs "\ngit push"
    }
    # A command ends at ; & or |, but not at the & of a redirection (2>&1 | sh, &>f).
    if (index(";&|", c) && !(c == "&" && (substr(s, i - 1, 1) ~ /[<>]/ || substr(s, i + 1, 1) == ">"))) {
      cs = i + 1; if (lv == rawlv) { raw = 0; rawlv = -1 }
    }
    # { and } are words of their own only as reserved words (`{ ls; }`); elsewhere (`-C {}`, `{a,b}`)
    # they are part of a word. (No regex here: BSD awk rejects an empty alternative like /^(x|)$/.)
    d = substr(s, i + 1, 1)
    if (c == "{" && !(ws && (d == "" || index(" \t\n", d)))) c = enc(c)
    if (c == "}" && !(ws && (d == "" || index(" \t\n;&|)<>", d)))) c = enc(c)
    emitc(c); ws = index(" \t;&|<>", c) > 0
  }
  if (st != mode) bad = 1
  t = buf[base]; lv = base - 1
  return t
}
BEGIN {
  src = " \t\n;&|(){}<>`\"\047\\"
  for (k = 1; k <= 16; k++) E[substr(src, k, 1)] = sprintf("%c", k < 9 ? k : k + 2)
  PH = sprintf("%c", 19)
  PIPESH = "^[ \t&]*(([A-Za-z_][A-Za-z0-9_]*=[^ \t]*|([^ \t;&|]*/)?(env|sudo|doas|command|exec|nohup|nice|time|timeout|setsid|stdbuf)|-[^ \t]*|[0-9]+)[ \t]+)*([^ \t;&|]*/)?(ba|z|da|k)?sh([ \t;&|)]|$)"
  GITPUSH = "[^A-Za-z0-9_-]git([^A-Za-z0-9_-]|[^A-Za-z0-9_-].*[^A-Za-z0-9_-])(push|send-pack)[^A-Za-z0-9_-]"
}
{ s = (NR > 1) ? s "\n" $0 : $0 }
END {
  nl = split(s, L, "\n"); O[1] = 1
  for (k = 1; k < nl; k++) O[k + 1] = O[k] + length(L[k]) + 1
  ln = 1; rawlv = -1; r = lex(s, "C")
  if (bad) exit 1
  printf "%s%s", r, subs
}
