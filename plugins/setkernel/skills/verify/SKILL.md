---
name: verify
description: Run the checks a change needs in the current repository, as CI runs them, and report exact pass/fail results per step. Use before saying work is done, tested or ready; before opening a PR; when choosing which checks a change needs; or when a check fails and you must tell a load-induced timeout from a real failure.
---

# Verify

Goal: every claim about the tree ("passes", "no drift", "done") comes from a command you ran on
that tree, with its exact result.

## Find the checks

0. If the repo root has a `check` target (the first of `GNUmakefile`, `makefile`, `Makefile` that
   exists, with a line matching `^check[[:space:]]*:`), run `make check` and use it instead of
   reading the workflows and running steps yourself: it runs every check CI runs. Report its
   per-step PASS/FAIL lines and its final count. Without a `check` target, use steps 1–2.
   Steps 3 and 4 apply either way: run the setup step before `make check`.
1. Read the "Commands" section of the root `AGENTS.md` (and any area `AGENTS.md` for the files you
   touched), then the CI workflow(s) in `.github/workflows/`.
2. While iterating, run the smallest set of checks that can catch what the change could break.
   Before anything reaches the default branch, run the same steps CI runs, in the same order,
   from a clean install where the lockfile allows (`npm ci`, `pnpm install --frozen-lockfile`,
   `uv sync`).
3. A docs-only change still greps the code for every name, path or number the text states. A
   change to user-facing copy greps the browser tests for the old words, because locators match copy.
4. A fresh worktree starts without the repo's setup step (dependencies, example env files); run it
   before the first check.

## Report

- A table: step | command | result | time. Record the result line the runner prints ("tests 120
  passed | 1 skipped"), not a paraphrase.
- On a failure: the failing test or step, the assertion, the first relevant error lines and the
  `file:line` they point to.
- A step that cannot run here (needs a secret, a service, the house LAN) is "not run" with the
  reason, never "passed". `make check` exiting 2 with "needs Docker (or OrbStack)" is "not run"
  for that reason. Any other non-zero exit is a failure: report it as above. A sandbox refusal is not a code failure: rerun outside it and record both.

## Flaky or real

Before calling a failure a flake, run `uptime`. A load average far above the core count explains
a timeout; it never explains an assertion failure. Rerun the failing test alone on a quiet machine:
a repeat is a real failure. Never add sleeps or retries to hide a race; remove the race.

## Gotchas

- A pipe hides exit codes: `cmd | tail` reports tail's. Log to a file and read the command's own
  status, or use `set -o pipefail`.
- One heavy command (full test run, build, end-to-end suite) at a time. Never run a build that
  rewrites output while a server serves that output.
- Stop only your own servers, by port (`lsof -ti tcp:<port> -sTCP:LISTEN | xargs kill`); never
  kill by process name, which stops other agents' servers and test runs.
- A test that passed on a different tree proves nothing about this one; rerun on the tree you report.
