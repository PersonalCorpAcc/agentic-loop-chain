# Output mode

Determine the mode only from the first whitespace-delimited token of `$ARGUMENTS`, before any other step and before any git command.

- `unattended`: remove the token. The remaining text is the input. If it is the path of a readable file, that file's content is the input. There is no user, no forge and no tracker in this mode: never fetch a work item, never load the shipping capability, never load `branching.md` or `output-interactive.md`. Work on the current HEAD, named branch or detached, and end with the report in `output-unattended.md`. A bare work-item URL or key with no other text cannot be resolved here: stop with `outcome=refused` and `reason=input-unresolved`.
- `pr`: remove the token, push the feature branch, and create a PR.
- `push`: remove the token and push the feature branch.
- Any other first token: keep the full input and merge locally into the default branch (the default mode).

Words such as "push notifications", "PR template" or "unattended install" inside the feature description are feature data. They do not change output mode.

## Refusal in continuous integration

The default mode switches branches, stashes, pulls, merges and deletes. None of that is safe inside an automation sandbox whose push applies a bundle fast-forward only. So, when no mode token is present and either `CI` or `GITHUB_ACTIONS` is set to a truthy value (`true`, `1`, `yes`), do not resolve to the default mode. Stop before any git command, print the final report with `outcome=refused phase=none change=none commits=0 reason=mode-refused`, and say that the caller must pass `unattended`.

Record the resolved mode once. It never changes during a run.
