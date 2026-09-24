# Failure policy

`/plan-run` never asks for input, but must halt instead of shipping broken or incoherent work.

Use the failure policy when (the reason token for the outcome line follows each cause):

- exploration cannot produce a safe and coherent functional interpretation after its one retry, or determines the goal is infeasible or outside the repository's feasible responsibility: `explore-infeasible`
- the proposal produces no actionable tasks: `no-tasks`
- the proposal materially contradicts the exploration brief: `propose-contradiction`
- a task wave stalls because tasks remain but none are eligible: `wave-stalled`
- a task exhausts its single retry: `task-retry-exhausted`
- tests, lint, build, type checks or required verification fail and cannot be cleared by re-waving, or any verification command exits non-zero after the apply phase and re-waving does not clear it: `verification-failed`
- archive verification still prints `ARCHIVE_FAILED` after one retry: `archive-failed`
- required repository state is missing or inconsistent before output: `state-inconsistent`
- a merge conflict cannot be resolved cleanly and automatically (interactive modes only): `state-inconsistent`
- a precondition fails in unattended mode: `missing-tool`, `identity-missing`, `dirty-path`

## On failure in unattended mode

1. Stop the pipeline.
2. Perform no git operation other than aborting an incomplete operation of this run's own (for example a half-applied archive). No stash, no switch, no restore, no branch operation, no merge, no push.
3. Leave every commit this run made in place on HEAD. Never amend, squash or reset them.
4. Report: the failed phase, the exact failed postcondition, commands or verification that failed, retry attempts, current HEAD, repository state, completed commits, archive state, and the safest manual next step for the caller.
5. Print the final report and end with the outcome line: `outcome=failed phase=<last completed phase> change=<id|none> commits=<n> reason=<token>`.

## On failure in interactive modes

1. Stop the pipeline.
2. Do not merge.
3. Do not push the default branch.
4. Leave `$BRANCH` intact whenever it exists.
5. Abort any incomplete merge.
6. Restore the Phase 1 goal stash on `$START_BRANCH`.
7. If stash restoration conflicts, preserve the stash and report its reference.
8. Report: the failed phase, the exact failed postcondition, commands or verification that failed, retry attempts, current branch, repository state, completed commits, archive state, and the safest manual next step.
9. End with the outcome line as above.

For loop-engineering, a clean failure with the work preserved is the correct outcome. Never merge or ship unverified work.
