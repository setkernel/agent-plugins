---
name: request-review
description: Ask two agent seats to review a person's pull request - request the reviewers one by one, then add the agent-review label. Use when asked to get agent reviews on a PR Raghav or an employee opened; sk-agent asks its own peers, so it refuses inside an sk-agent run.
---
1. Take the PR from the argument: `$ARGUMENTS`. Accept `https://github.com/<owner>/<repo>/pull/<n>`
   or `<owner>/<repo>#<n>`. With no argument or another form, ask for the PR; don't guess it from
   the current branch.
2. Run, with `<owner>/<repo>` and `<n>` from the argument:
   `sh "${CLAUDE_PLUGIN_ROOT}/skills/request-review/request-review.sh" <owner>/<repo> <n>`
3. Report its output as it is: on exit 0, the seats requested and the PR URL; on exit 1, the
   reason, and who was asked and who failed.
4. Don't work around a refusal: no `gh pr edit --add-reviewer`, no label by hand, no retry with
   other logins. Never approve, merge or comment on the PR, and never edit its body.
