---
name: ship-pr
description: Take the current work to a reviewable pull request the setkernel way - verify, review, push a branch, open the PR with the standard body. Use when a change is ready.
---
1. Run the `verify` skill. Fix failures caused by this change; report pre-existing ones.
2. Run the `review-blockers` skill and fix confirmed blockers.
3. Commit with a conventional message (`feat:`, `fix:`, `chore:` …). Never commit `.env`,
   `.dev.vars` or other secrets.
4. Push to a branch (`<type>/<short-name>`, or the prefix for where you run from the org rules'
   Who did it). Never push to the default branch, never force-push.
5. Open the PR with `gh pr create`: **What**, **Why**, **How verified** (the verify table),
   **Needs owner** (anything only Raghav can do). Link the issue: `Closes setkernel/<repo>#N`.
   End with your signature line if Who did it gives you one.
6. Once the PR is open and its checks are running, ask two seats to review it: run
   `sh "${CLAUDE_PLUGIN_ROOT}/skills/request-review/request-review.sh" <owner>/<repo> <n>` and
   report its output (who was asked, or why it stopped), as the `request-review` skill says.
   Inside an sk-agent run it refuses, since sk-agent asks its own peers: say so and go on.
7. Watch CI (`gh pr checks --watch`); fix failures you caused. Do not merge.
8. After each push that answers a change request, run the same script again and report its output:
   it asks again every seat whose change request stands on an older commit, since the gate holds
   the PR until that seat reviews the new head.
