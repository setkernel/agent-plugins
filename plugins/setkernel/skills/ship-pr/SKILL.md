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
6. Watch CI (`gh pr checks --watch`); fix failures you caused. Do not merge.
