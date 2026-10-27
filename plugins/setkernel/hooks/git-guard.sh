#!/bin/sh
# PreToolUse (Bash): the setkernel git guard. Blocks the git commands the org rules say to stop and
# ask about, including the forms a deny rule's text match misses (`git -C dir push -f`,
# `sh -c "git push -f"`, `env git …`, git aliases):
#   - a force push (`--force`, `--force-with-lease`, `-f` in any cluster, a `+ref`, `--mirror`);
#   - deleting a remote branch (`--delete`, `-d`, `:branch`, `--prune`);
#   - a push to the default branch (`main`, `master`, origin's HEAD), named or implied;
#   - `git reset --hard` and `git clean -f…`.
# Long options count in any abbreviation git accepts (`--force-w`, `--del`, `--har`).
# With SETKERNEL_GUARD_NO_PUSH=1 in the environment (sk-agent's runs) it blocks every push, including
# `git send-pack`, `git subtree push` and an alias set to push earlier in the same command line, and
# reads the command line the way the shell does (scrub, below): text that only mentions a push (a
# commit message, a heredoc body, a quoted search pattern) passes, while `sh -c "git push"`, `eval`,
# `$(git push)` and backticks are still read as commands (#43).
#
# A speed bump against mistakes, not a sandbox: a script or `g=git; $g push` still gets past it.
# A bare `git push` is checked against the current branch's name only, so a push that reaches the
# default branch through upstream tracking (`push.default=upstream`, upstream `origin/main`) passes.
# The branch is read before the command runs, so `git checkout main && git push` passes too.
# Without that variable it drops quotes and splits on shell operators, so a commit message that
# holds `; git push -f` is blocked too. Exit 2 blocks the call and shows Claude the reason; exit 0
# lets it through.
# POSIX sh; reads the hook JSON with jq, or with sed where jq is missing.
set -f
nl='
'
input=$(cat)

if command -v jq >/dev/null 2>&1; then
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
  cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
else
  # The value of a JSON string field, unescaped enough for the checks below.
  field() {
    printf '%s' "$input" | tr '\n' ' ' |
      sed -n -E 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' |
      sed -e 's/\\n/; /g' -e 's/\\t/ /g' -e 's/\\"/"/g' -e 's/\\\\/\\/g'
  }
  cmd=$(field command)
  cwd=$(field cwd)
fi
[ -n "$cmd" ] || exit 0
cwd=${cwd:-.}
depth=0
nopush=0
if [ "${SETKERNEL_GUARD_NO_PUSH:-}" = 1 ]; then nopush=1; fi
ph=$(printf '\023') # scrub's stand-in for a command substitution

# abbrev <arg> <long-option>…: true if <arg>, minus any `=value`, is one of the options or a prefix
# of one. git takes any unique prefix and rejects an ambiguous one, so this never blocks a command
# git would run as something else.
abbrev() {
  w=${1%%=*}
  shift
  case $w in --?*) ;; *) return 1 ;; esac
  for o; do case $o in "$w"*) return 0 ;; esac; done
  return 1
}

block() {
  if [ "$nopush" = 1 ]; then
    echo "setkernel git guard: blocked $1. This run must not push or discard work: commit and stop; the worker pushes your branch." >&2
  else
    echo "setkernel git guard: blocked $1. The org rules say to stop and ask the owner first (When to stop). Don't retry it in another form; if the owner agrees, they run it themselves." >&2
  fi
  exit 2
}

# scrub prints the command line the way the shell reads it, so text that is only data is not checked as a
# command (no-push mode only). The awk program is lib/scrub.awk, next to this file; if it is missing or awk is
# absent, scrub fails and check_cmd checks the raw text instead.
case $0 in */*) hookdir=${0%/*} ;; *) hookdir=. ;; esac
scrub() { printf '%s\n' "$1" | LC_ALL=C awk -f "$hookdir/lib/scrub.awk" 2>/dev/null; }

# decode <word>: a word from scrub with its control characters turned back into the text they stand for.
decode() {
  printf '%s' "$1" | LC_ALL=C tr '\001\002\003\004\005\006\007\010\013\014\015\016\017\020\021\022' " \\t\\n;&|(){}<>\`\"'\\\\"
}

# check_cmd <text>: check each simple command in a command line.
check_cmd() {
  if [ "$depth" -ge 4 ]; then # nested too deep to follow: it passes, unless no push may run
    if [ "$nopush" = 1 ]; then case $1 in *push* | *send-pack*) block "a git push nested too deep to read" ;; esac; fi
    return 0
  fi
  depth=$((depth + 1))
  t=$1
  if [ "$nopush" = 1 ]; then t=$(scrub "$1") || t=$1; fi
  # Drop a redirect's file descriptor number (the 2 in 2>&1) so it is not read as a git word.
  segs=$(printf '%s\n' "$t" | tr -d "\"'\\\\" |
    sed -E 's/(^|[[:space:];&|(){}`])[0-9]+([<>])/\1\2/g' |
    tr ';&|(){}<>`' '\n\n\n\n\n\n\n\n\n\n')
  IFS=$nl
  for seg in $segs; do
    IFS=' 	'
    # shellcheck disable=SC2086 # split the segment into words; globbing is off
    check_words $seg
    IFS=$nl
  done
  IFS=" 	$nl"
  depth=$((depth - 1))
}

# run_code <command> <arg…>: (no-push mode, where quoted text is one word) check the text that a
# shell runs with -c, eval runs, flock runs with -c or env runs with -S, as a command line of its own.
run_code() {
  rc=$1 rf=0
  shift
  if [ "$rc" = eval ]; then
    (check_cmd "$(decode "$*")") || exit $?
    return 0
  fi
  while [ $# -gt 0 ]; do
    # Match on the literal kind (sh for bash, zsh, dash and ksh): with a leading *, a word that only
    # holds :- or sh:-c (`${B:-x}`, `${xsh:-c}`) would match an option pattern and go unread.
    case $rc in *sh) rk='sh' ;; flock-file) rk=flock ;; *) rk=$rc ;; esac
    case $rf:$rk:$1 in
      1:env:* | 1:flock:* | 1:sh:[!+-]* | 1:sh:) # the value of -S or -c, or sh's first operand after -c
        (check_cmd "$(decode "$1")") || exit $?
        return 0 ;;
      0:env:-S | 0:env:--split-string | ?:flock:-c | ?:flock:--command | ?:sh:--command) rf=1 ;;
      0:env:-S?*) (check_cmd "$(decode "${1#-S}")") || exit $? ;;
      0:env:--split-string=*) (check_cmd "$(decode "${1#*=}")") || exit $? ;;
      0:env:-[uC] | 0:flock:-[wE] | ?:sh:[-+][oO]) [ $# -ge 2 ] && shift ;; # the option's value
      ?:sh:--*) ;;
      ?:sh:-*c*) rf=1 ;;
      0:env:-* | 0:flock:-* | ?:sh:[-+]*) ;;
      0:env:[A-Za-z_]*=*) ;;
      *)
        [ "$rc" = flock ] || return 0
        rc=flock-file ;; # flock's first word is the lock file
    esac
    shift
  done
}

# scan_git <command> <arg…>: (no-push mode) check every git word after the command word too, as
# sk-push-guard does, so a wrapper this guard doesn't know (`chrt 5 git push`, `watch git push`) still
# counts. Quoted text is one word here, so `grep "git push"` has no git word. Like sk-push-guard, the
# word after any -c (or a cluster ending in c, or --command) is checked as a command line too:
# `find . -exec sh -c '…' \;`, `su -c '…'`, `script -qc '…'`.
scan_git() {
  [ $# -gt 0 ] || return 0 # a segment of blanks only (`{ ls; }`): dash exits 2 on a shift too many
  shift
  sc=''
  while [ $# -gt 0 ]; do
    case $sc in --command | -*c) case $sc in --?*c) ;; *) (check_cmd "$(decode "$1")") || exit $? ;; esac ;; esac
    case $1 in git | */git) shift; (check_git "$@") || exit $?; sc=''; continue ;; esac
    sc=$1
    shift
  done
}

# check_words <word…>: skip assignments and wrappers (env, sudo, sh -c, xargs, …), then check git.
# Wrapper options that take a value are skipped for sudo -u/-g/-h, doas -u, env -u/-C, nice -n,
# ionice -c/-n/-p, flock -w/-E, exec -a, timeout -s/-k and stdbuf -i/-o/-e; other wrappers' value
# options are not known and can get past the guard. flock's lock file is skipped too.
# A cd or pushd moves the directory later segments read the branch and aliases from.
check_words() {
  while [ $# -gt 0 ]; do
    case $1 in
      [A-Za-z_]*=*) shift ;;
      env | sudo | doas | command | builtin | exec | nohup | time | nice | ionice | setsid | flock | stdbuf | \
        noglob | xargs | timeout | eval | sh | bash | zsh | dash | ksh | then | do | else | if | while | until | !)
        w=$1
        shift
        if [ "$nopush" = 1 ]; then
          case $w in env | eval | flock | sh | bash | zsh | dash | ksh) run_code "$w" "$@" ;; esac
        fi
        while [ $# -gt 0 ]; do
          case $w:$1 in # options that take a value: skip it too, or it reads as the command
            sudo:-[ughpCDRTU] | doas:-u | env:-[uC] | nice:-n | ionice:-[cnp] | flock:-[wE] | exec:-a | timeout:-[sk] | stdbuf:-[ioe])
              [ $# -ge 2 ] && shift 2 && continue ;;
            flock:[!-]*) w=flock-file; shift; continue ;;
          esac
          case $1 in -* | [0-9]*) shift ;; *) break ;; esac
        done
        ;;
      *) break ;;
    esac
  done
  if [ "$nopush" = 1 ]; then scan_git "$@"; fi
  case ${1-} in
    git | */git) shift && check_git "$@" ;;
    cd | pushd) shift
      while [ $# -gt 0 ]; do
        case $1 in --) shift; break ;; -?*) shift ;; *) break ;; esac
      done
      d=$(decode "${1-}")
      case $d in '' | -) ;; /*) cwd=$d ;; *) cwd=$cwd/$d ;; esac ;;
  esac
}

# check_git <arg…>: check a git command run in $cwd.
check_git() {
  dir=$cwd
  while [ $# -gt 0 ]; do
    case $1 in
      -C) [ $# -ge 2 ] || return 0
        d=$(decode "$2")
        case $d in /*) dir=$d ;; *) dir=$dir/$d ;; esac
        shift 2 ;;
      -c) # An alias set here to push, reset, clean or a shell command only serves to get past this.
        # The section name is read in any case (-c ALIAS.x=push).
        case ${2-} in [Aa][Ll][Ii][Aa][Ss].*=push* | [Aa][Ll][Ii][Aa][Ss].*=reset* | [Aa][Ll][Ii][Aa][Ss].*=clean* | [Aa][Ll][Ii][Aa][Ss].*=!*)
          block "a git alias set on the command line (-c $(decode "$2"))" ;;
        esac
        [ $# -ge 2 ] || return 0
        shift 2 ;;
      --git-dir | --work-tree | --namespace | --config-env | --attr-source | --super-prefix) [ $# -ge 2 ] || return 0; shift 2 ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 0
  sub=$1
  shift
  case $sub in
    push) check_push "$@" ;;
    reset) for a; do abbrev "$a" --hard && block "git reset $a"; done ;;
    clean) for a; do
        case $a in --*) abbrev "$a" --force && block "git clean $a" ;; -f* | -[!-]*f*) block "git clean $a" ;; esac
      done ;;
    send-pack | http-push) if [ "$nopush" = 1 ]; then block "git $sub"; fi ;;
    *"$ph"*) # a $(…) where the subcommand goes (no-push mode): any later push word counts
      for a; do [ "$a" = push ] && block "git … push after a command substitution"; done ;;
    subtree) if [ "$nopush" = 1 ]; then for a; do [ "$a" = push ] && block "git subtree push"; done; fi ;;
    config) # An alias set to push can be run later in the same command line, which the alias lookup
      # below can't see yet (git config alias.q push && git q).
      if [ "$nopush" = 1 ]; then
        k=''
        for a; do
          case $k in [Aa][Ll][Ii][Aa][Ss].*)
            case " $a " in *[!A-Za-z0-9_]push[!A-Za-z0-9_]* | *send-pack*) block "a git alias set to push (git config $k)" ;; esac ;;
          esac
          k=$a
        done
      fi ;;
    *) # An alias: check what it expands to, in the directory git ran it in (a subshell keeps
      # this call's cwd and dir; a block there exits 2, which is passed on).
      exp=$(git -C "$dir" config --get "alias.$sub" 2>/dev/null) || return 0
      case $exp in
        !*) (cwd=$dir; check_cmd "${exp#!} $*") || exit $? ;;
        *) (cwd=$dir; check_cmd "git $exp $*") || exit $? ;;
      esac ;;
  esac
  return 0 # a check that didn't block (a last test that failed) is not a hook failure
}

check_push() {
  [ "$nopush" = 1 ] && block "git push"
  remote='' named=0
  while [ $# -gt 0 ]; do
    a=$1
    shift
    case $a in
      --*)
        abbrev "$a" --force --force-with-lease --force-if-includes --mirror && block "a force push (git push $a)"
        abbrev "$a" --delete --prune && block "deleting a remote branch (git push $a)"
        abbrev "$a" --all --branches && block "a push of every branch, the default branch too (git push $a)"
        if abbrev "$a" --tags; then
          named=1
        else
          case $a in *=*) ;; *) abbrev "$a" --repo --receive-pack --exec --push-option && [ $# -gt 0 ] && shift ;; esac
        fi ;;
      -*)
        case $a in *f*) block "a force push (git push $a)" ;; esac
        case $a in *d*) block "deleting a remote branch (git push $a)" ;; esac
        case $a in *o) [ $# -gt 0 ] && shift ;; esac ;;
      *)
        if [ -z "$remote" ]; then
          remote=$a
        else
          named=1
          check_refspec "$a"
        fi ;;
    esac
  done
  [ "$named" = 1 ] || check_dst "$(current_branch)" "git push from"
}

check_refspec() {
  case $1 in
    +*) block "a force push (git push … $1)" ;;
    :*) block "deleting a remote branch (git push … $1)" ;;
    *:*) check_dst "${1##*:}" "git push … $1 to" ;;
    HEAD | @) check_dst "$(current_branch)" "git push … $1 from" ;;
    *) check_dst "$1" "git push … $1 to" ;;
  esac
}

# check_dst <branch> <what>: block a push whose destination is the default branch.
check_dst() {
  b=${1#refs/heads/}
  [ -n "$b" ] || return 0
  case $b in main | master) block "$2 the default branch ($b)" ;; esac
  head=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || return 0
  [ "$b" = "${head#*/}" ] && block "$2 the default branch ($b)"
  return 0
}

current_branch() { git -C "$dir" branch --show-current 2>/dev/null; }

check_cmd "$cmd"
exit 0
