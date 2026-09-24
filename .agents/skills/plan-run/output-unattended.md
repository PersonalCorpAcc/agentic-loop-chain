# Output procedure (unattended mode)

This mode ends with a report and nothing else. It performs no branch operation, no stash, no fetch, no pull, no merge, no push and no deletion. Never load the shipping capability in this mode. Commits already made in earlier phases stay exactly where they are, on the current HEAD.

## Postconditions

Before printing the report, require `verify` and `archive` ticked, no active change directory, an archive directory for `{change-id}`, and no uncommitted change on any path this run wrote. Check only the paths the run wrote; the working tree may legitimately hold other parties' modifications (the caller's configuration merge, for one), and those are not yours to stage, revert or judge:

```bash
git status --porcelain -- {paths this run wrote}
```

If that prints anything, stage and commit those paths with a message naming the phase; if a listed path was modified by someone else before the run started, stop with `reason=dirty-path` naming it instead.

Count the commits this run made:

```bash
git log --oneline "$START_HEAD..HEAD" | wc -l
```

## External gate

The caller owns what happens next: it verifies `openspec list --json` is empty and runs the repository's lint and type checks before any later git operation. Say so in the report.

## Final report

Print the report, then the outcome line from [outcome-line.md](outcome-line.md) as the very last line.

```text
Goal: {title}
Change ID: {change-id}
Scope classification: focused | standard | complex
Functional outcome: {one-sentence result}
HEAD: {branch name or "detached at <sha>"}
Tasks: {completed}/{total}
Acceptance criteria: {passed}/{total}
Commits: {proposal, apply, archive}
Verification: passed | failed
Archived: yes | no
Archive path: {path or none}
Output mode: unattended
Caller's gate: confirm no active change remains; run lint and type checks before any later git operation
outcome=succeeded phase=report change={change-id} commits={n} reason=-
```

On failure the report is the one the failure policy describes, and the outcome line carries `failed` with the phase and reason.
