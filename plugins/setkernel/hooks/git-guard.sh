#!/bin/sh
# PreToolUse (Bash): the setkernel git guard. Blocks the git commands the org rules say to stop and
# ask about, including the forms a deny rule's text match misses (`git -C dir push -f`,
# `sh -c "git push -f"`, `env git …`, git aliases):
#   - a force push (`--force`, `--force-with-lease`, `-f` in any cluster, a `+ref`, `--mirror`);
#   - deleting a remote branch (`--delete`, `-d`, `:branch`, `--prune`);
#   - a push to the default branch (`main`, `master`, origin's HEAD), named or implied;
#   - `git reset --hard` and `git clean -f…`.
# Long options count in any abbreviation git accepts (`--force-w`, `--del`, `--har`).
# With SETKERNEL_GUARD_NO_PUSH=1 in the environment (sk-agent's runs) it blocks every push.
#
# A speed bump against mistakes, not a sandbox: a script or `g=git; $g push` still gets past it.
# A bare `git push` is checked against the current branch's name only, so a push that reaches the
# default branch through upstream tracking (`push.default=upstream`, upstream `origin/main`) passes.
# It drops quotes and splits on shell operators, so a commit message that holds `; git push -f`
# is blocked too. Exit 2 blocks the call and shows Claude the reason; exit 0 lets it through.
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
  if [ "${SETKERNEL_GUARD_NO_PUSH:-}" = 1 ]; then
    echo "setkernel git guard: blocked $1. This run must not push or discard work: commit and stop; the worker pushes your branch." >&2
  else
    echo "setkernel git guard: blocked $1. The org rules say to stop and ask the owner first (When to stop). Don't retry it in another form; if the owner agrees, they run it themselves." >&2
  fi
  exit 2
}

# check_cmd <text>: check each simple command in a command line.
check_cmd() {
  [ "$depth" -lt 4 ] || return 0
  depth=$((depth + 1))
  segs=$(printf '%s\n' "$1" | tr -d "\"'\\\\" | tr ';&|(){}<>`' '\n\n\n\n\n\n\n\n\n\n')
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

# check_words <word…>: skip assignments and wrappers (env, sudo, sh -c, xargs, …), then check git.
# A cd or pushd moves the directory later segments read the branch and aliases from.
check_words() {
  while [ $# -gt 0 ]; do
    case $1 in
      [A-Za-z_]*=*) shift ;;
      env | sudo | command | builtin | exec | nohup | time | nice | stdbuf | noglob | xargs | timeout | eval | \
        sh | bash | zsh | dash | ksh | then | do | else | if | while | until | !)
        shift
        while [ $# -gt 0 ]; do
          case $1 in -* | [0-9]*) shift ;; *) break ;; esac
        done
        ;;
      *) break ;;
    esac
  done
  case ${1-} in
    git | */git) shift && check_git "$@" ;;
    cd | pushd) shift
      while [ $# -gt 0 ]; do
        case $1 in --) shift; break ;; -?*) shift ;; *) break ;; esac
      done
      case ${1-} in '' | -) ;; /*) cwd=$1 ;; *) cwd=$cwd/$1 ;; esac ;;
  esac
}

# check_git <arg…>: check a git command run in $cwd.
check_git() {
  dir=$cwd
  while [ $# -gt 0 ]; do
    case $1 in
      -C) [ $# -ge 2 ] || return 0
        case $2 in /*) dir=$2 ;; *) dir=$dir/$2 ;; esac
        shift 2 ;;
      -c) # An alias set here to push, reset, clean or a shell command only serves to get past this.
        case ${2-} in alias.*=push* | alias.*=reset* | alias.*=clean* | alias.*=!*) block "a git alias set on the command line (-c $2)" ;; esac
        [ $# -ge 2 ] || return 0
        shift 2 ;;
      --git-dir | --work-tree | --namespace | --config-env) [ $# -ge 2 ] || return 0; shift 2 ;;
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
    *) # An alias: check what it expands to, in the directory git ran it in (a subshell keeps
      # this call's cwd and dir; a block there exits 2, which is passed on).
      exp=$(git -C "$dir" config --get "alias.$sub" 2>/dev/null) || return 0
      case $exp in
        !*) (cwd=$dir; check_cmd "${exp#!} $*") || exit $? ;;
        *) (cwd=$dir; check_cmd "git $exp $*") || exit $? ;;
      esac ;;
  esac
}

check_push() {
  [ "${SETKERNEL_GUARD_NO_PUSH:-}" = 1 ] && block "git push"
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
        case $a in *o) shift ;; esac ;;
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
