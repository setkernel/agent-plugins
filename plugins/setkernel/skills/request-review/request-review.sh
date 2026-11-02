#!/bin/sh
# /setkernel:request-review: ask two agent seats to review a person's PR (setkernel/agent-plugins#63).
# Usage: request-review.sh <owner/repo> <number>
#
# An agent picks a review when the PR carries `agent-review`, the agent is a requested reviewer and
# the PR isn't labelled `human`. sk-agent asks peers only for the PRs it opens, so this does the same
# for a person's PR: reviewers first, the label last, as sk-agent does.
#
# Candidates: the org team's members, minus the PR author, the caller and Raghav, least busy first
# (open review requests in the org), random among ties. One REST call per login; a refused login is
# skipped; a login GitHub dropped (read back after each call) is asked once more. A seat is a team
# member other than Raghav or the author who is a requested reviewer. With two seats on the PR the
# label goes on and it exits 0; a re-run asks nobody new. Fewer than two after every candidate: no
# label, exit 1. It never approves, merges, comments or edits the PR body. POSIX sh, gh and jq only.
set -u
org=setkernel
team=engineering
owner=realRaghavGupta
label=agent-review
want=2
export GH_PROMPT_DISABLED=1

die() {
  echo "request-review: $*" >&2
  exit 1
}

# sk-agent sets this in every run; it requests its own peers, after its self-review, in its own order.
[ "${SETKERNEL_GUARD_NO_PUSH:-}" = 1 ] &&
  die "refused inside an sk-agent run: sk-agent asks its own peers for the PRs it opens."
[ $# -eq 2 ] || die "usage: request-review.sh <owner/repo> <number>"
repo=$1 num=$2
case $repo in [A-Za-z0-9]*/[A-Za-z0-9._-]*) ;; *) die "not an owner/repo: $repo" ;; esac
case $repo in */*/* | *[!A-Za-z0-9._/-]*) die "not an owner/repo: $repo" ;; esac
case $num in '' | *[!0-9]*) die "not a PR number: $num" ;; esac
command -v gh >/dev/null 2>&1 || die "needs gh"
command -v jq >/dev/null 2>&1 || die "needs jq"

# The PR first: refuse a closed PR, a draft or one a person keeps for humans.
pr=$(gh api "repos/$repo/pulls/$num") || die "cannot read $repo#$num"
url=$(printf '%s' "$pr" | jq -r .html_url)
author=$(printf '%s' "$pr" | jq -r .user.login)
[ "$(printf '%s' "$pr" | jq -r .state)" = open ] || die "$url is closed."
[ "$(printf '%s' "$pr" | jq -r .draft)" = true ] && die "$url is a draft."
printf '%s' "$pr" | jq -e '[.labels[].name] | index("human")' >/dev/null &&
  die "$url is labelled human: agents don't review it."

me=$(gh api user --jq .login) && [ -n "$me" ] || die "cannot tell who is calling (gh api user)."
members=$(gh api --paginate "orgs/$org/teams/$team/members" --jq '.[].login') && [ -n "$members" ] ||
  die "cannot list the members of $org/$team (the gh login needs read:org)."

tmpd=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$tmpd"' EXIT
# pool: the logins that count as seats. requested: the logins now requested on the PR.
printf '%s\n' "$members" | grep -Fvx -e "$owner" -e "$author" >"$tmpd/pool"
requested() { gh api "repos/$repo/pulls/$num/requested_reviewers" --jq '.users[].login'; }
seats() { printf '%s\n' "$1" | grep -Fx -f "$tmpd/pool"; }
count() { printf '%s' "$1" | grep -c .; }
now=$(requested) || die "cannot read the requested reviewers of $url"
have=$(seats "$now")

asked='' failed=''
if [ "$(count "$have")" -lt "$want" ]; then
  # Least busy first, random among ties; a load the search can't count goes last.
  printf '%s\n%s\n' "$me" "$have" | grep . >"$tmpd/skip"
  order=$(grep -Fvx -f "$tmpd/skip" "$tmpd/pool" |
    while read -r login; do
      load=$(gh api -X GET search/issues --jq .total_count \
        -f q="org:$org is:pr is:open review-requested:$login -label:human" 2>/dev/null) || load=999999
      echo "$load $login"
    done | awk 'BEGIN { srand() } { print $1, rand(), $2 }' | sort -k1,1n -k2,2n | cut -d' ' -f3)
  for login in $order; do
    [ "$(count "$have")" -ge "$want" ] && break
    asked="$asked $login"
    ok=
    for try in 1 2; do
      if ! gh api -X POST "repos/$repo/pulls/$num/requested_reviewers" -f "reviewers[]=$login" >/dev/null; then
        echo "request-review: GitHub refused $login; trying the next candidate." >&2
        break
      fi
      now=$(requested) || die "cannot read the requested reviewers of $url"
      printf '%s\n' "$now" | grep -Fqx -e "$login" && { ok=1; break; }
      [ "$try" = 1 ] && echo "request-review: $login was dropped; asking once more." >&2
    done
    [ -n "$ok" ] || failed="$failed $login"
    have=$(seats "$now")
  done
fi

if [ "$(count "$have")" -lt "$want" ]; then
  die "only $(count "$have") of $want seats on $url; no $label label added. Asked:${asked:- nobody}. Failed:${failed:- none}."
fi
# Label last, once the reviewers are on.
if ! printf '%s' "$pr" | jq -e --arg l "$label" '[.labels[].name] | index($l)' >/dev/null; then
  gh api -X POST "repos/$repo/issues/$num/labels" -f "labels[]=$label" >/dev/null || die "could not add the $label label to $url"
fi
echo "Review requested from $(printf '%s' "$have" | tr '\n' ' ') on $url; labelled $label."
