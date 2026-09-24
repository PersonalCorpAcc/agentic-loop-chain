# Outcome line

Every run of this pipeline, in every mode, ends with exactly one machine-readable line. It is the last line printed, after the human report, so a caller can read it without parsing anything else.

```text
outcome=<succeeded|failed|refused> phase=<none|explore|propose|implement|verify|archive|report> change=<id|none> commits=<n> reason=<token|->
```

| Field | Rule |
|---|---|
| `outcome` | `refused` only before any write was made; `failed` after at least the preconditions passed; `succeeded` when every checklist item is ticked |
| `phase` | the last phase whose tick was recorded; `none` when refused |
| `change` | the change identifier once the proposal is committed, else `none` |
| `commits` | commits this run made on HEAD (`git log START_HEAD..HEAD`) |
| `reason` | `-` on `succeeded`; otherwise exactly one token from the list below |

## Reason tokens

The list is closed. Never invent a token; if no token fits, use `state-inconsistent` and explain in the report.

- `verification-failed`: lint, type check, tests or build failed after re-waving
- `no-tasks`: the proposal or the pre-refined issue produced no actionable task
- `missing-tool`: a required command is not on `PATH` (named in the report)
- `dirty-path`: a path this run must write already holds someone else's uncommitted change
- `identity-missing`: no commit identity is configured and none was supplied
- `mode-refused`: no mode token in a continuous-integration environment
- `input-unresolved`: only a work-item reference was supplied in unattended mode
- `archive-failed`: the archive still fails after its retry
- `explore-infeasible`: exploration found the goal infeasible or outside the repository's responsibility
- `propose-contradiction`: the proposal materially contradicts the exploration brief
- `wave-stalled`: tasks remain but none is eligible
- `task-retry-exhausted`: a task failed its single retry
- `state-inconsistent`: required repository state is missing or inconsistent before output

## Examples

```text
outcome=succeeded phase=report change=add-login commits=3 reason=-
outcome=failed phase=verify change=add-login commits=2 reason=verification-failed
outcome=refused phase=none change=none commits=0 reason=mode-refused
```
