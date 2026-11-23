---
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/workflows/agent-merge-gate.md. Profile digest: ccaabc0b4a1d. Update with `workflows update --force`; consumer edits may be overwritten.
env:
  VERIFY_COMMANDS: "pnpm install --frozen-lockfile && pnpm run build && pnpm run test"
  REPO_RULES: "Install with the lockfile frozen; an install that resolves a different tree is not reproducing the change under review. Run scripts through pnpm rather than npx, or a second package manager's lockfile appears in the diff."
  PROTECTED_FILES: (^\.|^opencode\.jsonc$|^package\.json$|^pnpm-lock\.yaml$|^pnpm-workspace\.yaml$|^AGENTS\.md$|^ARCHITECTURE\.md$)
  # What a test file is and what disables one, composed from the stack packs. Empty turns the
  # test-integrity check off; the installer fills both from the declared packs (007 X06).
  TEST_FILES: "([.](test|spec)[.][cm]?[jt]sx?$|(^|/)__tests__/)"
  TEST_SKIP_MARKERS: "((^|[^A-Za-z0-9_.])(it|test|describe)[.](skip|only|todo)[(]|(^|[^A-Za-z0-9_.])(xit|xtest|xdescribe)[(])"
  VERIFY_COMMANDS_SCOPED: "pnpm run lint"
  LINT_FIX_COMMAND: "pnpm run lint --fix"
  REPO_VERIFY_COMMAND: repo-verify
  WORKING_LABEL: bot-working
  IMPLEMENT_LABEL: implement
  REVIEW_LABEL: review
  PR_PENDING_LABEL: pr-pending
  # How the forge merges here. A profile value, because a rebase repository and a squash
  # repository disagree about what a merge even is (FR-026).
  MERGE_METHOD: "rebase"
  # What happens to a conflict. Under `merge-target` the agent merges the base in and
  # resolves, which is all it can do: its push applies a bundle fast-forward only, so a
  # rebase would be computed, refused and lost. Under `human` it does not try at all
  # (FR-027, FR-028).
  CONFLICT_RESOLUTION: "human"
  # Which label an issue must carry for the gate to act, per stage the pull request could
  # target: `stage=label`, comma separated. The first stage requires the implement label,
  # because the change has only just been implemented; every later stage requires the
  # previous stage's label, because that is what says it got there honestly. Empty under a
  # strategy with no chain, where `require-label` answers on its own (FR-030).
  STAGE_LABELS: "dev=implement,test=merged-dev,main=merged-test"
  # Whether this repository merges a pull request without a person, and into which branches.
  # Off unless a profile turns it on, so by default the gate assesses, says so, and stops:
  # a human gate is branch protection plus somebody's judgement, not a sentence in a prompt
  # (FR-035, FR-036).
  AUTO_MERGE_MODE: "always"
  AUTO_MERGE_TARGETS: "dev,test"
  GATE_MARKER: "<!-- agent-merge-gate -->"
  # Whether a person's pull request is assessed too, advise-only: one comment carrying
  # `<!-- agent-merge-gate-advisory: <verdict> -->` and the findings, and nothing else -- no
  # label, push, merge or approval (feature 007 X11, FR-027). Off unless a profile turns it on.
  SHADOW_HUMAN_PULL_REQUESTS: "false"
  # What the gate does with a change that needs work (feature 007 X08, FR-024). `fix`: it fixes a
  # failed CI run or a conflict itself and pushes. `review`: it never pushes; it requests the
  # changes as a pull-request review with severity-ranked findings, apply-review makes them, and
  # the gate reviews again on the next CI run. The marker is how apply-review and the next gate
  # run tell the gate's own change request from a person's.
  GATE_MODE: "fix"
  GATE_REVIEW_MARKER: "<!-- agent-merge-gate-review -->"
  ATTEMPT_MARKER: "<!-- agent-merge-gate-attempt -->"
  MAX_ATTEMPTS: "6"
  PARK_AT_ATTEMPT: "5"
  INCOMPLETE_COMMENT: "Automated CI failure remediation ended without an outcome. The issue remains for a retry."
  ISSUE_CONTEXT_PATH: /tmp/gh-aw/agent/issue-context.json
  GH_AW_ALLOWED_BOTS: "personalcorpacc-agentic-loop[bot],github-actions[bot]"
  GIT_AUTHOR_NAME: "personalcorpacc-agentic-loop[bot]"
  GIT_AUTHOR_EMAIL: "personalcorpacc-agentic-loop[bot]@users.noreply.github.com"
  GIT_COMMITTER_NAME: "personalcorpacc-agentic-loop[bot]"
  GIT_COMMITTER_EMAIL: "personalcorpacc-agentic-loop[bot]@users.noreply.github.com"
description: |
  Decides what happens to a bot-authored pull request once CI has reported: merge when the
  risk assessment is clean, hand to a human when it is not, fix CI when it failed. Called by
  the Work Router; does not trigger on public events.

  The router supplies the CI conclusion and run ID as facts, so there is no polling and no
  timeout branch. The conclusion is read from the inputs instead of filtered at the trigger.

  Two profile choices (feature 007): `gate.mode: review` makes it a reviewer that never pushes --
  severity-ranked findings become a change request apply-review answers, and the gate reviews
  again (X08, FR-024); `gate.shadowHumanPullRequests` has it advise, without changing anything,
  on pull requests people open (X11, FR-027).

name: "Agent: Merge Gate"

# Router-only worker. The Work Router owns triggers, classification, and rung 1-2 checks.
# This workflow receives the classified inputs and runs rung 3+.
imports:
  - shared/platform-defaults.md
  - shared/stack-node-pnpm.md
on:
  workflow_call:
    inputs:
      pr-number:
        description: Pull request number to gate.
        required: true
        type: string
      linked-issue:
        description: Issue number the pull request closes. May be empty.
        required: false
        type: string
      ci-conclusion:
        description: CI conclusion (success, failure, action_required, cancelled, etc.).
        required: true
        type: string
      ci-run-id:
        description: CI workflow run ID for fetching failing logs.
        required: false
        type: string
      attempts_so_far:
        description: Failed gate attempts already made against this CI verdict. Parked when it reaches the cap.
        required: false
        type: string
        default: '0'
      human-only:
        description: >-
          'true' when the router sent this run for a person's pull request only (the green-CI
          shadow route, FR-027). A bot pull request is then refused: its verdict reaches the
          gate through CI's own dispatch.
        required: false
        type: string
        default: 'false'
  # gh-aw folds the top-level `if:` below into the generated activation job but does not carry
  # the jobs that `if:` reads into activation's `needs`: only prompt-referenced custom jobs with
  # no `needs:` of their own are hoisted (subject). protected_changes needs subject, so without
  # this entry activation read needs.protected_changes.outputs.requires_review before
  # protected_changes had started; the value was '' and the clause was always true
  # (Pliny-Bot run 34042143350: activation finished 18 s before protected_changes began).
  needs: [protected_changes, reserve]

# Rung 4. Router has classified the event; identify-gate-subject validates PR ownership,
# resolves the closing issue, and confirms the CI verdict.
# A custom job, not `on.steps`, because the prompt and the precompute step need these
# values and `on.steps` outputs do not reach the agent job.
jobs:
  subject:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      issues: read
      pull-requests: read
      actions: read
    outputs:
      found: ${{ steps.subject.outputs.found }}
      why_not: ${{ steps.subject.outputs.why-not }}
      base: ${{ steps.subject.outputs.base }}
      pr: ${{ steps.subject.outputs.pr }}
      issue: ${{ steps.subject.outputs.issue }}
      # A promotion pull request under `env-promotion` carries several issues rather than
      # one, so the gate's subject is a set. `issue` stays as the first of them, for the
      # sentences that name one; `comment_target` is where this run's assessment belongs,
      # which is the pull request when there is no single issue it is about (FR-056).
      issues: ${{ steps.subject.outputs.issues }}
      promotion: ${{ steps.subject.outputs.promotion }}
      comment_target: ${{ steps.subject.outputs.comment-target }}
      # What the prompt is told it is looking at. Computed here rather than written as a
      # conditional in the prompt body, because gh-aw validates the expressions in a runtime
      # import against a safe list and a ternary is not on it: one in the prompt fails the
      # whole workflow at `activation`, before the model runs (the same trap `verdict_word`
      # was written for).
      subject_clause: ${{ steps.phrasing.outputs.subject_clause }}
      promotion_note: ${{ steps.phrasing.outputs.promotion_note }}
      context_instruction: ${{ steps.phrasing.outputs.context_instruction }}
      handover: ${{ steps.subject.outputs.handover }}
      conclusion: ${{ steps.subject.outputs.conclusion }}
      run-id: ${{ steps.subject.outputs.run-id }}
      review_blocked: ${{ steps.review.outputs.review_blocked }}
      auto_merge: ${{ steps.policy.outputs.auto_merge }}
      # The same decision as a word and as a sentence, because the prompt may only read a
      # plain output. gh-aw validates the expressions in a runtime import against a safe
      # list, and a ternary is not on it: `auto_merge == 'true' && 'merge' || 'approve'` in
      # the prompt body fails the whole workflow at `activation`, before the model runs.
      # That is latent until a repository turns auto-merge on, because with `off` the
      # prompt path is never rendered -- so the first adopter to enable the feature finds
      # the gate cannot start at all (17/09/2026, canary PRs #7 and #9).
      #
      # Deciding here rather than in the prompt is also the right shape: which word the
      # agent is asked for is policy, and policy belongs in a deterministic job.
      verdict_word: ${{ steps.policy.outputs.verdict_word }}
      verdict_sentence: ${{ steps.policy.outputs.verdict_sentence }}
      # A person's pull request assessed in shadow (feature 007 X11, FR-027): every job that
      # writes asks this first, and the prompt is told so in `advise_note`.
      advise: ${{ steps.subject.outputs.advise }}
      advise_note: ${{ steps.phrasing.outputs.advise_note }}
      # What review mode asks of the agent instead of a fix; empty under `fix` (FR-024).
      mode_note: ${{ steps.phrasing.outputs.mode_note }}
      checked_note: ${{ steps.phrasing.outputs.checked_note }}
    steps:
      - name: Checkout workflow actions
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: Identify the pull request, its issue, and the CI verdict
        id: subject
        uses: ./.github/actions/identify-gate-subject
        with:
          token: ${{ github.token }}
          pr-number: ${{ inputs.pr-number }}
          ci-conclusion: ${{ inputs.ci-conclusion }}
          # Declared since the route was written and passed to nothing until 19/09/2026
          # (T247). Without it the failing logs are never fetched.
          ci-run-id: ${{ inputs.ci-run-id }}
          linked-issue: ${{ inputs.linked-issue }}
          require-label: ${{ env.IMPLEMENT_LABEL }}
          stage-labels: ${{ env.STAGE_LABELS }}
          shadow-human-pull-requests: ${{ env.SHADOW_HUMAN_PULL_REQUESTS }}
          human-only: ${{ inputs.human-only || 'false' }}
      # Answered here, beside the base it depends on, because three readers need the same
      # answer: the prompt, which must not ask the agent for a verdict this repository will
      # not act on; the merge step; and the outcome line. Three derivations of one policy
      # are three chances to disagree about whether this pull request merges itself.
      - name: Decide whether this base merges unattended
        id: policy
        env:
          BASE: ${{ steps.subject.outputs.base }}
          AUTO_MERGE_MODE: ${{ env.AUTO_MERGE_MODE }}
          AUTO_MERGE_TARGETS: ${{ env.AUTO_MERGE_TARGETS }}
          ADVISE: ${{ steps.subject.outputs.advise }}
        run: bash ./.github/actions/merge-gate/decide-auto-merge.sh
      - name: Block a pull request with requested changes
        id: review
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          PR: ${{ steps.subject.outputs.pr }}
          GATE_REVIEW_MARKER: ${{ env.GATE_REVIEW_MARKER }}
        # A person's change request holds the pull request; the gate's own, made in review mode
        # for apply-review to answer, does not (feature 007 X08). A transient API failure must
        # not kill the gate: three tries, then not blocked, as before.
        run: bash ./.github/actions/gate-review/review-blocked.sh
      - name: Say what this run is assessing
        id: phrasing
        env:
          PROMOTION: ${{ steps.subject.outputs.promotion }}
          ADVISE: ${{ steps.subject.outputs.advise }}
          PR: ${{ steps.subject.outputs.pr }}
          ISSUE: ${{ steps.subject.outputs.issue }}
          ISSUE_CONTEXT_PATH: ${{ env.ISSUE_CONTEXT_PATH }}
          VERIFY_COMMAND: ${{ env.REPO_VERIFY_COMMAND }}
          IMPLEMENT_LABEL: ${{ env.IMPLEMENT_LABEL }}
          GATE_MODE: ${{ env.GATE_MODE }}
          BASE: ${{ steps.subject.outputs.base }}
          VERDICT_WORD: ${{ steps.policy.outputs.verdict_word }}
        run: bash ./.github/actions/merge-gate/phrase-assessment.sh
      - name: Record the outcome
        if: always()
        uses: ./.github/actions/record-outcome
        with:
          outcome: ${{ steps.subject.outputs.found == 'true' && 'acted' || 'no-action' }}
          reason: ${{ steps.subject.outputs.found == 'true' && 'clear-to-proceed' || 'no-eligible-change' }}
          route: merge-gate
          subject: ${{ steps.subject.outputs.pr && format('#{0}', steps.subject.outputs.pr) || '-' }}
          # The reason this pull request is not a subject, as the check that refused it put it.
          # The old line listed three conditions and let the reader guess, which for a
          # back-propagation pull request -- opened by this loop, carrying no issue because
          # what arrived outside the loop had none -- amounted to denying the loop had opened
          # it (FR-084).
          detail: "${{ steps.subject.outputs.found == 'true' && 'This pull request is open, bot-authored and carries the required label, so the gate may run.' || format('Nothing to gate: {0}', steps.subject.outputs.why-not || 'this pull request is not one the gate assesses.') }}"

  # A promotion the gate cannot assess is a person's, and saying so is the whole job.
  #
  # `found=false` is the ordinary answer for a pull request the gate has no business with,
  # and it is silent by design: a repository's human pull requests would otherwise each
  # collect a comment explaining that the loop is not going to gate them. A promotion whose
  # carried issues do not all carry the stage below's label is the opposite case -- this loop
  # opened it, it is carrying real work, and nothing else is going to notice. Its own job,
  # rather than a write permission on `subject`, so the common path keeps read-only
  # (FR-056, FR-084).
  #
  # `if: always()` with every step conditioned, which is the shape `review_required` uses and
  # is not a style choice. gh-aw hoists every custom job into the agent job's `needs`, and a
  # job whose `needs` contains a **skipped** job is itself skipped -- so a custom job that
  # skips in the ordinary case silently disables the agent for every pull request, not just
  # the ones it was written for. The first version of this job had `if: needs.subject.outputs
  # .handover == 'true'` and did exactly that: the gate stopped assessing anything, and the
  # compile, the route matrix and the whole suite stayed green. Only a live run showed it
  # (canary PR #100, 21/09/2026).
  handover:
    needs: subject
    if: always()
    runs-on: ubuntu-24.04
    permissions:
      # The checkout below needs it: an exhaustive permissions map leaves contents at none,
      # which a public repository forgives and a private one answers with "Repository not
      # found" (release canary, 21/11/2026: five implement attempts read as an outage).
      contents: read
      pull-requests: write
    steps:
      - name: Checkout workflow actions
        if: needs.subject.outputs.handover == 'true'
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: Say on the pull request why the gate did not run
        if: needs.subject.outputs.handover == 'true'
        uses: ./.github/actions/create-issue-comment
        with:
          token: ${{ github.token }}
          issue-number: ${{ needs.subject.outputs.pr }}
          # The attempt marker, not the gate marker.
          #
          # A hand-over is a gate run that reached no verdict, which is exactly what the
          # attempt marker means, and reusing it buys the whole belt for free: the reconcile
          # sweep counts this against the six-attempt budget and stops re-dispatching once it
          # is spent, so a promotion nobody fixes collects six comments rather than one every
          # half hour for the rest of the week. The gate marker is reserved for a verdict --
          # the route matrix pins its count at four, and that invariant is what keeps "the
          # gate decided" distinguishable from "the gate ran".
          body: |
            ${{ env.ATTEMPT_MARKER }}
            The merge gate did not assess this pull request: ${{ needs.subject.outputs.why_not }}

            Nothing has been changed and no label has moved. A promotion is a snapshot of the
            stage below and cannot leave one of its changes behind, so this is a person's to
            resolve -- by labelling the change that is missing its stage label, or by closing
            this pull request, which holds every change it carries until somebody says
            otherwise.
      - name: Record the outcome
        if: needs.subject.outputs.handover == 'true'
        uses: ./.github/actions/record-outcome
        with:
          outcome: handed-to-human
          reason: missing-required-label
          route: merge-gate
          subject: ${{ format('#{0}', needs.subject.outputs.pr) }}
          detail: "${{ needs.subject.outputs.why_not }}"

  protected_changes:
    needs: subject
    if: needs.subject.outputs.found == 'true'
    runs-on: ubuntu-24.04
    permissions:
      # An exhaustive block leaves `contents` at none, and the checkout below needs it on a
      # private repository.
      contents: read
      pull-requests: read
    outputs:
      requires_review: ${{ steps.files.outputs.requires_review }}
      files: ${{ steps.files.outputs.files }}
    steps:
      - name: Checkout workflow actions
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: Require review for protected pull request files
        id: protected
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          PR: ${{ needs.subject.outputs.pr }}
          BASE: ${{ needs.subject.outputs.base }}
          # Composed by the installer from the engine baseline, the declared packs'
          # manifests and lockfiles, and the profile's documents (FR-022).
          PROTECTED_FILES: ${{ env.PROTECTED_FILES }}
        run: bash ./.github/actions/merge-gate/list-protected-changes.sh
      # A change that deletes a test, renames one away or adds a skip marker hands the pull
      # request to a person, as a protected file does: the agent must not be able to make a
      # failing test disappear (007 X06). Decided here, deterministically, not by the model.
      - name: Check test integrity
        id: integrity
        uses: ./.github/actions/check-test-integrity
        with:
          compare-file: ${{ steps.protected.outputs.compare_file }}
          test-files: ${{ env.TEST_FILES }}
          skip-markers: ${{ env.TEST_SKIP_MARKERS }}
      - name: Decide whether a person must review
        id: files
        env:
          PROTECTED: ${{ steps.protected.outputs.files }}
          FINDINGS: ${{ steps.integrity.outputs.findings }}
        run: bash ./.github/actions/merge-gate/decide-person-review.sh

  review_required:
    needs: [subject, protected_changes]
    # gh-aw makes the agent depend on custom jobs. Keep this job successful when
    # there are no protected files instead of skipping it and blocking remediation.
    if: always() && needs.subject.outputs.found == 'true'
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      issues: write
    steps:
      - name: Checkout workflow actions
        if: needs.subject.outputs.advise != 'true' && ((needs.protected_changes.outputs.requires_review == 'true' && needs.subject.outputs.conclusion != 'failure') || needs.subject.outputs.review_blocked == 'true')
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: Create bot token
        if: needs.subject.outputs.advise != 'true' && needs.protected_changes.outputs.requires_review == 'true' && needs.subject.outputs.conclusion != 'failure'
        id: app-token
        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
        with:
          client-id: ${{ secrets.BOT_APP_ID }}
          private-key: ${{ secrets.BOT_PRIVATE_KEY }}
          owner: ${{ github.repository_owner }}
          repositories: ${{ github.event.repository.name }}
          permission-contents: write
          permission-issues: write
          permission-pull-requests: write
          permission-actions: write
          permission-workflows: write
      # Only the reservation comes off. pr-pending says a pull request for this issue is open
      # and waiting, which is still true when the gate hands it to a human, so taking it off
      # here left a board where three issues with three open pull requests looked like they
      # had none. The merge path is the one place the label stops being true.
      - name: Release the issue
        if: needs.subject.outputs.advise != 'true' && needs.subject.outputs.promotion != 'true' && (needs.protected_changes.outputs.requires_review == 'true' && needs.subject.outputs.conclusion != 'failure')
        uses: ./.github/actions/remove-issue-labels
        with:
          token: ${{ steps.app-token.outputs.token }}
          issue-number: ${{ needs.subject.outputs.issue }}
          labels: ${{ env.WORKING_LABEL }}
      - name: Flag human review
        if: needs.subject.outputs.advise != 'true' && needs.subject.outputs.promotion != 'true' && (needs.protected_changes.outputs.requires_review == 'true' && needs.subject.outputs.conclusion != 'failure')
        uses: ./.github/actions/add-issue-labels
        with:
          token: ${{ steps.app-token.outputs.token }}
          issue-number: ${{ needs.subject.outputs.issue }}
          labels: ${{ env.REVIEW_LABEL }}
      - name: Explain the merge hold
        if: needs.subject.outputs.advise != 'true' && needs.protected_changes.outputs.requires_review == 'true' && needs.subject.outputs.conclusion != 'failure'
        uses: ./.github/actions/create-issue-comment
        with:
          token: ${{ steps.app-token.outputs.token }}
          issue-number: ${{ needs.subject.outputs.comment_target }}
          body: |
            ${{ env.GATE_MARKER }}
            PR #${{ needs.subject.outputs.pr }} changes protected files and cannot be auto-merged.
            The `review` label is set: a human must merge this PR manually.

            Protected files:
            ${{ needs.protected_changes.outputs.files }}

            **Verdict:** review
      # The loop is waiting for a person, which is a state, not a failure. Recorded where
      # every other verdict is recorded, so the run reads the same way as any other (T246).
      - name: Say that a reviewer has this pull request
        if: needs.subject.outputs.advise != 'true' && needs.subject.outputs.review_blocked == 'true'
        uses: ./.github/actions/record-outcome
        with:
          outcome: handed-to-human
          reason: changes-requested
          route: merge-gate
          subject: ${{ format('#{0}', needs.subject.outputs.pr) }}
          detail: "A reviewer has requested changes on this pull request, so the gate leaves it alone until those threads are resolved. Answering a review is apply-review's job, not the gate's."

  reserve:
    needs: subject
    if: needs.subject.outputs.found == 'true'
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      issues: write
      pull-requests: read
    outputs:
      has_conflicts: ${{ steps.conflicts.outputs.has_conflicts || 'false' }}
      conflict_blocked: ${{ steps.conflict-mode.outputs.blocked || 'false' }}
    steps:
      - name: Checkout workflow actions
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: Create bot token
        id: app-token
        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
        with:
          client-id: ${{ secrets.BOT_APP_ID }}
          private-key: ${{ secrets.BOT_PRIVATE_KEY }}
          owner: ${{ github.repository_owner }}
          repositories: ${{ github.event.repository.name }}
          permission-contents: write
          permission-issues: write
          permission-pull-requests: write
          permission-actions: write
          permission-workflows: write
      - name: Check for merge conflicts
        id: conflicts
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
          REPO: ${{ github.repository }}
          PR: ${{ needs.subject.outputs.pr }}
        run: bash ./.github/actions/merge-gate/check-merge-conflicts.sh
      # First attempt only. Retries are recorded by the incomplete job's attempt comment, and
      # every App comment is a router event: one issue collected sixteen of these in a day.
      # Under `human` the agent never sees the conflict: it is told nothing, runs nothing,
      # and the pull request goes to a person with the reason on the issue. The other two
      # values are decided elsewhere -- `merge-target` is what the prompt below does, and
      # `rebase-deterministic` is refused by `profile validate` naming the feature that
      # implements it -- so this is the whole of the branch (FR-027, FR-028).
      - name: Decide whether a conflict is the agent's to resolve
        id: conflict-mode
        if: steps.conflicts.outputs.has_conflicts == 'true' && env.CONFLICT_RESOLUTION != 'merge-target'
        run: |
          set -euo pipefail
          echo "blocked=true" >> "$GITHUB_OUTPUT"
          echo "PR #${{ needs.subject.outputs.pr }} conflicts and this repository resolves conflicts by ${CONFLICT_RESOLUTION}; the agent will not be started."
      - name: Hand the conflict to a human
        if: needs.subject.outputs.advise != 'true' && needs.subject.outputs.promotion != 'true' && (steps.conflict-mode.outputs.blocked == 'true')
        uses: ./.github/actions/add-issue-labels
        with:
          token: ${{ steps.app-token.outputs.token }}
          issue-number: ${{ needs.subject.outputs.issue }}
          labels: ${{ env.REVIEW_LABEL }}
      - name: Say why the conflict was not resolved
        if: needs.subject.outputs.advise != 'true' && steps.conflict-mode.outputs.blocked == 'true'
        uses: ./.github/actions/create-issue-comment
        with:
          token: ${{ steps.app-token.outputs.token }}
          issue-number: ${{ needs.subject.outputs.comment_target }}
          body: |
            ${{ env.GATE_MARKER }}
            PR #${{ needs.subject.outputs.pr }} conflicts with its base, and this repository
            resolves conflicts by `${{ env.CONFLICT_RESOLUTION }}`, so the gate did not attempt it.
            A resolution here would have to be a merge commit: the agent's push applies a bundle
            fast-forward only, so a rebase is computed, refused and lost.

            **Verdict:** review
      - name: Comment on issue - problems found, solving them
        if: needs.subject.outputs.advise != 'true' && needs.subject.outputs.conclusion == 'failure' && (inputs.attempts_so_far || '0') == '0'
        uses: ./.github/actions/create-issue-comment
        with:
          token: ${{ steps.app-token.outputs.token }}
          issue-number: ${{ needs.subject.outputs.comment_target }}
          body: |
            Problems found in PR #${{ needs.subject.outputs.pr }}. ${{ steps.conflicts.outputs.has_conflicts == 'true' && 'Merge conflicts detected.' || 'CI failed.' }}
            ${{ env.GATE_MODE == 'review' && 'The merge gate is reviewing it and will request the changes it needs.' || 'Bot is working on fixing it.' }}
  validate_output:
    needs: [activation, subject, reserve, agent, safe_outputs]
    if: >
      always() &&
      needs.agent.result == 'success' &&
      needs.safe_outputs.result == 'success'
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      # Review mode counts the change requests the gate has already made (FR-024).
      pull-requests: read
    outputs:
      # Review mode's decision where there is one, the validator's otherwise: the review step is
      # installed only under `gate.mode: review` (feature 007 X08).
      valid: ${{ steps.decide.outputs.valid || steps.validate.outputs.valid }}
      outcome: ${{ steps.decide.outputs.outcome || steps.validate.outputs.outcome }}
      round: ${{ steps.decide.outputs.round }}
    steps:
      - name: Checkout workflow actions
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: Download agent output
        id: output
        uses: ./.github/actions/download-agent-output
        with:
          artifact-name: ${{ needs.activation.outputs.artifact_prefix }}agent
      - name: Validate merge-gate outcome
        id: validate
        uses: ./.github/actions/validate-merge-gate-output
        with:
          output-file: ${{ steps.output.outputs.output-file }}
          # Where the agent was told to post, which on a promotion is the pull request. The
          # validator reads the comment it finds there; pointed at an issue that never
          # received one it would report the gate reached no verdict (FR-056).
          issue-number: ${{ needs.subject.outputs.comment_target }}
          ci-conclusion: ${{ needs.subject.outputs.conclusion }}
          # Step 4b pushes a merge of the base on green CI and says `remediated`; the validator
          # accepts that only when the gate saw a conflict (review WF-04).
          has-conflicts: ${{ needs.reserve.outputs.has_conflicts || 'false' }}
          # A verdict addressed to the pull request is the same answer on the wrong page;
          # conclude posts it on comment_target either way.
          pr-number: ${{ needs.subject.outputs.pr }}
          # Under review the gate never pushes and `changes` is its request for changes.
          gate-mode: ${{ needs.subject.outputs.advise == 'true' && 'fix' || env.GATE_MODE }}
      # Only blockers and majors request changes, a promotion is not changed by apply-review, and
      # the rounds are capped at the attempt budget's park point (feature 007 X08, FR-024).
      # Installed in every mode and skipped outside review: other steps read its outputs, and a
      # step projected away leaves those references pointing at nothing, which actionlint rejects.
      - name: Decide the review-mode verdict
        id: decide
        if: env.GATE_MODE == 'review' && needs.subject.outputs.advise != 'true'
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          PR: ${{ needs.subject.outputs.pr }}
          COMMENT_TARGET: ${{ needs.subject.outputs.comment_target }}
          PROMOTION: ${{ needs.subject.outputs.promotion }}
          OUTCOME: ${{ steps.validate.outputs.outcome }}
          OUTPUT_FILE: ${{ steps.output.outputs.output-file }}
          MAX_ROUNDS: ${{ env.PARK_AT_ATTEMPT }}
          GATE_REVIEW_MARKER: ${{ env.GATE_REVIEW_MARKER }}
        run: bash ./.github/actions/gate-review/decide-review-outcome.sh
  conclude:
    needs: [activation, subject, protected_changes, agent, safe_outputs, validate_output]
    if: >
       needs.subject.outputs.advise != 'true' &&
       needs.agent.result == 'success' &&
        needs.safe_outputs.result == 'success' &&
        needs.validate_output.outputs.valid == 'true' &&
       (needs.protected_changes.outputs.requires_review != 'true' || needs.validate_output.outputs.outcome != 'merge')
    runs-on: ubuntu-24.04
    permissions:
      contents: write
      issues: write
      pull-requests: write
    steps:
      - name: Create bot token
        id: app-token
        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
        with:
          client-id: ${{ secrets.BOT_APP_ID }}
          private-key: ${{ secrets.BOT_PRIVATE_KEY }}
          owner: ${{ github.repository_owner }}
          repositories: ${{ github.event.repository.name }}
          permission-contents: write
          permission-issues: write
          permission-pull-requests: write
          permission-actions: write
          permission-workflows: write
      - name: Checkout repository
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          token: ${{ steps.app-token.outputs.token }}
          fetch-depth: 0
      # A promotion closes nothing on its own: the changes it carries are already linked
      # to their own pull requests, and FR-051 closes them when the promotion reaches the
      # closing stage.
      - name: Verify pull request closes the source issue
        if: needs.subject.outputs.promotion != 'true'
        continue-on-error: true
        uses: ./.github/actions/link-pr-to-issue
        with:
          token: ${{ steps.app-token.outputs.token }}
          pr-number: ${{ needs.subject.outputs.pr }}
          issue-number: ${{ needs.subject.outputs.issue }}
      - name: Apply agent output
        uses: ./.github/actions/apply-agent-output
        with:
          artifact-name: ${{ needs.activation.outputs.artifact_prefix }}agent
          token: ${{ steps.app-token.outputs.token }}
          push-to-branch: 'true'
          pr-number: ${{ needs.subject.outputs.pr }}
          apply-labels: 'false'
          # The assessment has one right place. `add-comment` is `target: "*"`, so the agent
          # picks the number, and picking the pull request it is gating is a natural slip.
          comment-target: ${{ needs.subject.outputs.comment_target }}
      # GITHUB_TOKEN on purpose: an App-token comment on a pull request is an issue_comment
      # event, and GITHUB_TOKEN raises none. The full assessment lives on the issue, where the
      # lifecycle is; this is what a reviewer opening the pull request sees. Carrying the
      # marker and the Verdict line makes the router's verdict detection independent of
      # whether the model remembered the marker.
      - name: Show the verdict on the pull request
        uses: ./.github/actions/create-issue-comment
        with:
          token: ${{ github.token }}
          issue-number: ${{ needs.subject.outputs.pr }}
          body: |
            ${{ env.GATE_MARKER }}
            **Verdict:** ${{ needs.validate_output.outputs.outcome }} (CI concluded ${{ needs.subject.outputs.conclusion }}).
            Full assessment: ${{ needs.subject.outputs.promotion == 'true' && 'above, on this pull request' || format('on the linked issue #{0}', needs.subject.outputs.issue) }}. [View this workflow run](${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }})
      # Review mode (feature 007 X08, FR-024). The findings go to the pull request as a change
      # request, with the App token so the review is an event: the router sends it to
      # apply-review, which makes the change. A forge that refuses the review -- the App may not
      # review a pull request it opened itself -- hands the change to a person instead.
      - name: Request the changes as a review
        id: request
        if: env.GATE_MODE == 'review' && needs.validate_output.outputs.outcome == 'changes'
        continue-on-error: true
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
          REPO: ${{ github.repository }}
          PR: ${{ needs.subject.outputs.pr }}
          COMMENT_TARGET: ${{ needs.subject.outputs.comment_target }}
          OUTPUT_FILE: ${{ github.workspace }}/agent-artifact/agent_output.json
          GATE_REVIEW_MARKER: ${{ env.GATE_REVIEW_MARKER }}
          ROUND: ${{ needs.validate_output.outputs.round }}
          MAX_ROUNDS: ${{ env.PARK_AT_ATTEMPT }}
          RUN_URL: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
        run: bash ./.github/actions/gate-review/post-gate-review.sh
      # The reservation comes off either way: apply-review reserves the issue for itself, and a
      # refused review is a person's.
      # Clean: the gate's own change requests are done with. Dismissed before anything merges,
      # never approved over -- an App approval could count towards a rule that wants a person's.
      # The forge is asked before anything is attempted: a pull request it will refuse is a
      # review with a sentence, not a red run that says neither which pull request nor what
      # to do about it (FR-068).
      # A pull request body can be neutralised after the fact; a commit message cannot.
      # The forge closes an issue on a keyword in any commit merged into the default branch,
      # and under rebase every commit message lands on every stage, so one `Fixes #12` in a
      # commit closes the issue at the first stage no matter what the body says. Under squash
      # or merge the forge writes the merge commit's message itself, so only rebase carries
      # them through (FR-030).
      - name: Refuse a rebase merge whose commits close the issue
        if: needs.validate_output.outputs.outcome == 'merge' && needs.subject.outputs.auto_merge == 'true' && env.MERGE_METHOD == 'rebase'
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
          REPO: ${{ github.repository }}
          PR: ${{ needs.subject.outputs.pr }}
        run: bash ./.github/actions/merge-gate/refuse-closing-commits.sh
      - name: Check the forge will take the merge
        id: preconditions
        if: needs.validate_output.outputs.outcome == 'merge' && needs.subject.outputs.auto_merge == 'true'
        uses: ./.github/actions/check-merge-preconditions
        with:
          token: ${{ steps.app-token.outputs.token }}
          pr-number: ${{ needs.subject.outputs.pr }}
      - name: Merge approved pull request
        if: needs.validate_output.outputs.outcome == 'merge' && needs.subject.outputs.auto_merge == 'true' && steps.preconditions.outputs.mergeable == 'true'
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
          REPO: ${{ github.repository }}
          PR: ${{ needs.subject.outputs.pr }}
          MERGE_METHOD: ${{ env.MERGE_METHOD }}
        run: |
          set -euo pipefail
          head_sha=$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq '.headRefOid')
          gh pr merge "$PR" --repo "$REPO" "--${MERGE_METHOD}" --match-head-commit "$head_sha"
      # A rule is holding it, and a rule can still be satisfied (FR-080). This is the case
      # protection produces on every pull request into a branch whose owner wants a person on
      # it, so it must not read as a failure: the gate marks the pull request ready and the
      # forge merges it when the required review or check arrives. That is GitHub's own
      # documented pattern for a bot landing its own pull requests, and it is the reason this
      # loop needs no bypass permission -- with one, the pull request would still report
      # `BLOCKED` and we would be merging past the adopter's own rules, which is the opposite
      # of what turning protection on asks for (D8, D9).
      #
      # No label moves and nothing is cleared, exactly as an approval moves nothing: the
      # change has not landed, the issue is still reserved, and `pr-pending` is still true.
      - name: Arm auto-merge when a rule is holding it
        id: arm
        if: needs.validate_output.outputs.outcome == 'merge' && needs.subject.outputs.auto_merge == 'true' && steps.preconditions.outputs.deferrable == 'true'
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
          REPO: ${{ github.repository }}
          PR: ${{ needs.subject.outputs.pr }}
          MERGE_METHOD: ${{ env.MERGE_METHOD }}
          REFUSAL: ${{ steps.preconditions.outputs.refusal }}
        run: bash ./.github/actions/merge-gate/arm-auto-merge.sh
      - name: Hand the merge to a human when the forge refuses it
        if: needs.validate_output.outputs.outcome == 'merge' && needs.subject.outputs.auto_merge == 'true' && steps.preconditions.outputs.mergeable != 'true' && (steps.preconditions.outputs.deferrable != 'true' || steps.arm.outputs.armed != 'true')
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
          REPO: ${{ github.repository }}
          PR: ${{ needs.subject.outputs.pr }}
          REFUSAL: ${{ steps.preconditions.outputs.refusal }}
          ARMED: ${{ steps.arm.outputs.armed }}
          ARM_ERROR: ${{ steps.arm.outputs.arm_error }}
          DEFERRABLE: ${{ steps.preconditions.outputs.deferrable }}
        run: bash ./.github/actions/merge-gate/explain-refused-merge.sh
      - name: Flag the refused merge for review
        if: needs.subject.outputs.promotion != 'true' && (needs.validate_output.outputs.outcome == 'merge' && needs.subject.outputs.auto_merge == 'true' && steps.preconditions.outputs.mergeable != 'true' && (steps.preconditions.outputs.deferrable != 'true' || steps.arm.outputs.armed != 'true'))
        uses: ./.github/actions/add-issue-labels
        with:
          token: ${{ steps.app-token.outputs.token }}
          issue-number: ${{ needs.subject.outputs.issue }}
          labels: ${{ env.REVIEW_LABEL }}
      - name: Release remediated issue
        if: needs.subject.outputs.promotion != 'true' && (needs.validate_output.outputs.outcome == 'remediated')
        uses: ./.github/actions/remove-issue-labels
        with:
          token: ${{ steps.app-token.outputs.token }}
          issue-number: ${{ needs.subject.outputs.issue }}
          labels: ${{ env.WORKING_LABEL }}
      - name: Flag review outcome
        if: needs.subject.outputs.promotion != 'true' && (needs.validate_output.outputs.outcome == 'review')
        uses: ./.github/actions/add-issue-labels
        with:
          token: ${{ steps.app-token.outputs.token }}
          issue-number: ${{ needs.subject.outputs.issue }}
          labels: ${{ env.REVIEW_LABEL }}
      # The reservation only. The pull request is still open and still waiting, so pr-pending
      # stays until the merge path below retires it.
      - name: Release review outcome
        if: needs.subject.outputs.promotion != 'true' && (needs.validate_output.outputs.outcome == 'review')
        uses: ./.github/actions/remove-issue-labels
        with:
          token: ${{ steps.app-token.outputs.token }}
          issue-number: ${{ needs.subject.outputs.issue }}
          labels: ${{ env.WORKING_LABEL }}
      # An approval is a verdict and nothing else: the pull request stays open, keeps its
      # labels, and waits for a person. Clearing anything here would retire the reservation
      # of a change that has not landed, break the require-label check on the next run, and
      # retire `pr-pending` while the pull request is still pending (FR-035).
      - name: Say the gate approved but did not merge
        if: needs.validate_output.outputs.outcome == 'approve' || (needs.validate_output.outputs.outcome == 'merge' && needs.subject.outputs.auto_merge != 'true')
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          PR: ${{ needs.subject.outputs.pr }}
          BASE: ${{ needs.subject.outputs.base }}
        run: |
          set -euo pipefail
          gh pr comment "$PR" --repo "$REPO" --body "The merge gate found nothing to stop this pull request. It has not been merged: this repository does not merge into \`${BASE}\` unattended, so a person merges it. Nothing about the issue has changed -- it is still reserved and still pending."
      # No label clearing here at all. Every post-merge transition belongs to the stage-merge
      # route, which sees the bot's own App-token merge as the same `closed` event a person's
      # merge raises: a transition with two owners is a transition that happens twice or not
      # at all (FR-035, FR-051).
      - name: Record the outcome
        if: always()
        uses: ./.github/actions/record-outcome
        with:
          outcome: ${{ (needs.validate_output.outputs.outcome == 'changes' && steps.request.outcome == 'failure') && 'handed-to-human' || (needs.validate_output.outputs.outcome == 'merge' && needs.subject.outputs.auto_merge == 'true') && 'acted' || needs.validate_output.outputs.outcome == 'review' && 'handed-to-human' || needs.validate_output.outputs.outcome == 'invalid' && 'no-action' || 'acted' }}
          reason: ${{ (needs.validate_output.outputs.outcome == 'changes' && steps.request.outcome == 'failure') && 'review-requested' || needs.validate_output.outputs.outcome == 'changes' && 'changes-requested' || steps.arm.outputs.armed == 'true' && 'merge-armed' || (needs.validate_output.outputs.outcome == 'merge' && needs.subject.outputs.auto_merge == 'true') && 'merged' || needs.validate_output.outputs.outcome == 'review' && 'review-requested' || needs.validate_output.outputs.outcome == 'remediated' && 'acted' || needs.validate_output.outputs.outcome == 'invalid' && 'nothing-to-sweep' || 'approved' }}
          route: merge-gate
          subject: ${{ needs.subject.outputs.pr && format('#{0}', needs.subject.outputs.pr) || '-' }}
          detail: "${{ (needs.validate_output.outputs.outcome == 'changes' && steps.request.outcome == 'failure') && 'The gate asked for changes and the forge refused its review, so a person has the change.' || needs.validate_output.outputs.outcome == 'changes' && 'The gate requested changes as a review; apply-review makes them and the gate reviews again.' || steps.arm.outputs.armed == 'true' && 'The pull request is marked ready; the forge merges it when the rule holding it is satisfied.' || (needs.validate_output.outputs.outcome == 'merge' && needs.subject.outputs.auto_merge == 'true') && 'The pull request was merged.' || needs.validate_output.outputs.outcome == 'review' && 'The gate asked for a human; the assessment is on the issue.' || needs.validate_output.outputs.outcome == 'invalid' && 'The gate reached no verdict on this run.' || 'The gate approved the pull request; this repository does not merge into that branch unattended, so it waits for a person.' }}"
  incomplete:
    needs: [activation, subject, protected_changes, agent, safe_outputs, validate_output]
    # A pull request a reviewer has asked to change is not an incomplete run: the agent was
    # never meant to start. Saying so here would be four "ended without an outcome" comments
    # in four minutes, one per CI event, with an attempt counter that stays at 0 because the
    # job that increments it never runs -- so the park-at-5 safety could never fire either
    # (T246). review_required says the true thing instead.
    if: >
       always() &&
       needs.subject.outputs.found == 'true' &&
       needs.subject.outputs.advise != 'true' &&
       needs.subject.outputs.review_blocked != 'true' &&
       (needs.protected_changes.outputs.requires_review != 'true' || needs.subject.outputs.conclusion == 'failure') &&
       (
         needs.agent.result != 'success' ||
         needs.safe_outputs.result != 'success' ||
         needs.validate_output.outputs.valid != 'true'
       )
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      issues: write
    steps:
      - name: Checkout workflow actions
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: Create bot token
        id: app-token
        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
        with:
          client-id: ${{ secrets.BOT_APP_ID }}
          private-key: ${{ secrets.BOT_PRIVATE_KEY }}
          owner: ${{ github.repository_owner }}
          repositories: ${{ github.event.repository.name }}
          permission-contents: write
          permission-issues: write
          permission-pull-requests: write
          permission-actions: write
          permission-workflows: write
      # The attempt record comes first. The belt bounds its retries by counting attempt comments
      # newer than the CI verdict, not by labels; releasing the labels before the record existed
      # meant a failure in either step below un-reserved the issue with nothing to count, and the
      # belt re-dispatched the same crash every cycle. The steps stay sequential on purpose: an
      # always() release after a failed park would strip bot-working from an issue that was
      # meant to be parked with review.
      # attempts_so_far is a workflow_call input and arrives as '' when the caller passes an
      # empty expression, declared default or not; fromJson('') is a hard failure, so the empty
      # case reads as 0.
      - name: Report the failed attempt
        if: fromJson(inputs.attempts_so_far || '0') < fromJson(env.PARK_AT_ATTEMPT)
        uses: ./.github/actions/create-issue-comment
        with:
          token: ${{ steps.app-token.outputs.token }}
          issue-number: ${{ needs.subject.outputs.comment_target }}
          body: |
            ${{ env.ATTEMPT_MARKER }}
            Attempt ${{ inputs.attempts_so_far || '0' }} of ${{ env.MAX_ATTEMPTS }} on PR #${{ needs.subject.outputs.pr }} ended without an outcome.
            ${{ needs.activation.outputs.daily_ai_credits_exceeded == 'true' && format('The agent did not start: this repository has used its daily AI-credit allowance ({0} of {1}; the `GH_AW_DEFAULT_MAX_DAILY_AI_CREDITS` repository variable sets it). Work resumes once the day''s usage is back under it; raise the variable to allow more.', needs.activation.outputs.daily_ai_credits_total, needs.activation.outputs.daily_ai_credits_threshold) || '' }}
            The issue keeps `implement`; the merge belt will retry.
            [View this workflow run](${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }})
      - name: Report the exhausted attempt budget
        if: fromJson(inputs.attempts_so_far || '0') >= fromJson(env.PARK_AT_ATTEMPT)
        uses: ./.github/actions/create-issue-comment
        with:
          token: ${{ steps.app-token.outputs.token }}
          issue-number: ${{ needs.subject.outputs.comment_target }}
          body: |
            ${{ env.ATTEMPT_MARKER }}
            Attempt ${{ inputs.attempts_so_far || '0' }} of ${{ env.MAX_ATTEMPTS }} on PR #${{ needs.subject.outputs.pr }} ended without an outcome.
            ${{ needs.activation.outputs.daily_ai_credits_exceeded == 'true' && format('The agent did not start: this repository has used its daily AI-credit allowance ({0} of {1}; the `GH_AW_DEFAULT_MAX_DAILY_AI_CREDITS` repository variable sets it). Work resumes once the day''s usage is back under it; raise the variable to allow more.', needs.activation.outputs.daily_ai_credits_total, needs.activation.outputs.daily_ai_credits_threshold) || '' }}
            The attempt budget for this CI verdict is exhausted. The review label is set: a human must take over.
            [View this workflow run](${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }})
      - name: Park the issue for a human
        if: needs.subject.outputs.promotion != 'true' && (fromJson(inputs.attempts_so_far || '0') >= fromJson(env.PARK_AT_ATTEMPT))
        uses: ./.github/actions/add-issue-labels
        with:
          token: ${{ steps.app-token.outputs.token }}
          issue-number: ${{ needs.subject.outputs.issue }}
          labels: ${{ env.REVIEW_LABEL }}
      # The reservation only. A failed attempt does not close the pull request, so pr-pending
      # is still true and the board should keep saying so.
      - name: Release the issue
        if: needs.subject.outputs.advise != 'true' && needs.subject.outputs.promotion != 'true'
        uses: ./.github/actions/remove-issue-labels
        with:
          token: ${{ steps.app-token.outputs.token }}
          issue-number: ${{ needs.subject.outputs.issue }}
          labels: ${{ env.WORKING_LABEL }}

  # Shadow mode's only write (feature 007 X11, FR-027). A person's pull request gets one
  # comment: the verdict in a marker the comparison reads, `<!-- agent-merge-gate-advisory:
  # <verdict> -->`, and the findings. Its own job rather than a path through conclude, so the
  # jobs that label, merge and push keep one shape and each of them simply does not run here.
  # The workflow token, so the comment raises no event. The verdict is the rule's where a rule
  # decides without the agent (a protected file, a change request, a conflict handed to a
  # person), and the agent's otherwise; a verdict the agent could not give is recorded, not
  # posted.
  agent:
    # The top-level guard reads both outputs. GitHub Actions does not make a
    # dependency's dependencies available through `needs` transitively.
    needs: [subject, protected_changes]
    if: always() && (needs.protected_changes.outputs.requires_review != 'true' || needs.subject.outputs.conclusion == 'failure') && needs.subject.outputs.review_blocked != 'true'

if: always() && needs.subject.outputs.found == 'true' && (needs.protected_changes.outputs.requires_review != 'true' || needs.subject.outputs.conclusion == 'failure') && needs.subject.outputs.review_blocked != 'true' && needs.reserve.outputs.conflict_blocked != 'true'

runs-on: ubuntu-24.04
runs-on-slim: ubuntu-24.04

engine:
  id: claude
  # The agent job's own concurrency group, per pull request. The compiler's default is one group per
  # workflow, which serialised this worker across the whole repository whatever the router
  # allowed; the router's caller job owns the real limit (review WF-06).
  concurrency:
    group: "gh-aw-merge-gate-${{ inputs.pr-number }}"
    cancel-in-progress: false
model: claude-sonnet-5

max-turns: 300
max-turn-cache-misses: 3000
max-ai-credits: 5000

permissions: read-all

# push-to-pull-request-branch with target "*" cannot reach a branch the shallow clone
# does not have.
checkout:
  fetch: ["*"]
  fetch-depth: 0

# Rung 3. The diff is what the risk assessment reads, and the failing logs are what a fix
# starts from. Both are known from the inputs, so neither costs the agent a turn.
steps:
  # gh-aw checks out the router's ref. Its own "Checkout PR branch" step runs only when the event
  # carries a pull request, which a router dispatch does not, so the agent would start on main.
  # apply-agent-output fast-forwards origin/<branch> to the bundle tip and refuses anything else,
  # and gh-aw builds that bundle from what the agent committed on top of the checkout; both need
  # the agent to start on the branch it pushes to.
  - name: Check out the pull request branch
    env:
      GH_TOKEN: ${{ github.token }}
      REPO: ${{ github.repository }}
      PR: ${{ needs.subject.outputs.pr }}
    run: |
      set -euo pipefail
      branch=$(gh pr view "$PR" --repo "$REPO" --json headRefName --jq '.headRefName')
      git switch --track "origin/$branch" 2>/dev/null || git switch "$branch"
      echo "On $(git branch --show-current) at $(git rev-parse --short HEAD)"
  # A promotion has no single issue whose acceptance criteria are the thing to check, so
  # the first of several would be a context that is wrong about the rest. What it is assessed
  # against is the diff and CI, which the next step fetches (FR-056).
  - name: Load the issue context
    if: needs.subject.outputs.promotion != 'true' && needs.subject.outputs.issue != ''
    uses: ./.github/actions/load-issue-context
    with:
      token: ${{ github.token }}
      issue-number: ${{ needs.subject.outputs.issue }}
      output-path: ${{ env.ISSUE_CONTEXT_PATH }}
  - name: Fetch the diff and any failing job logs
    env:
      GH_TOKEN: ${{ github.token }}
      REPO: ${{ github.repository }}
      PR: ${{ needs.subject.outputs.pr }}
      RUN_ID: ${{ needs.subject.outputs.run-id }}
      CONCLUSION: ${{ needs.subject.outputs.conclusion }}
    run: bash ./.github/actions/merge-gate/fetch-gate-context.sh

# Each run's OpenTelemetry GenAI spans -- duration, tokens, model, outcome; never prompt or
# response content -- go to the profile's OTLP endpoint (feature 007 X14, FR-074).
safe-outputs:
  # Path B. Without this, gh-aw's own safe_outputs job writes as well as the conclude job, and
  # it runs first: it pushed a flattened, single-parent commit with GITHUB_TOKEN while conclude
  # was still waiting, so the agent's merge commit was lost, the pull request stayed
  # conflicting, and GITHUB_TOKEN raises no events, so no CI ran on the new head and the belt
  # stalled (Pliny-Bot run 34051821011). Staged runs everything and writes nothing; conclude
  # applies the bundle and the comment with the App token, which does start CI.
  staged: true
  # A failed run is already a red run. An issue per failure buries the real backlog
  # under noise nobody closes.
  report-failure-as-issue: false
  threat-detection: false
  # target "*" because these workers are dispatched, not triggered by the pull request:
  # the default "triggering" target has no pull request in context and rejects the push
  # with "requires pull request context", so the agent's fix is computed and discarded.
  push-to-pull-request-branch:
    target: "*"
    required-title-prefix: "[bot] "
    # A failed bot PR may already contain protected files. Permit a verified repair push,
    # but protected_changes still prevents the later green-CI cycle from auto-merging it.
    protected-files: allowed
  add-comment:
    target: "*"

timeout-minutes: 60
---

1. You are gating pull request **#${{ needs.subject.outputs.pr }}**, which ${{ needs.subject.outputs.subject_clause }}.
   CI concluded **${{ needs.subject.outputs.conclusion }}**.

   ${{ needs.subject.outputs.advise_note }}

   ${{ needs.subject.outputs.mode_note }}

   ${{ needs.subject.outputs.promotion_note }}

   ${{ needs.subject.outputs.checked_note }}

   **You are on the head branch, not on the merge of the head and its base.** CI ran on the
   merge of the two, which is also what will land. Read `/tmp/gh-aw/agent/base-state.txt`: it
   names the base and how many commits this branch is missing from it. If you run a build or a
   type check here and it fails while the conclusion above is `success`, the tree you are
   standing in is missing what the base supplies -- a dependency, a path alias, a generated
   file -- and **CI is right and you are not**. Say what you observed if it is useful, and do
   not turn it into a verdict. A local failure is evidence of a merge result only when the
   branch is missing nothing from its base.

   You are on the pull request branch. Never rebase, reset, amend or otherwise rewrite
   history: the workflow applies your commits as a bundle with a fast-forward-only push and
   discards anything that is not a descendant of the branch tip. The
   `push_to_pull_request_branch` tool's own description recommends rebasing; in this
   repository that advice is wrong. Merge, commit, and let the workflow push.

2. ${{ needs.subject.outputs.context_instruction }}

3. Branch on the conclusion.

   First check the issue context for `<!-- complexity: trivial -->`.

   **If the trivial marker is present AND CI conclusion is success:**
   Skip the full assessment (step 5). Emit a minimal assessment table with all checks marked
   ✅ and the note "Trivial change, CI green — deep risk review skipped." Then proceed directly
   to step 8 (merge verdict).

   **If the trivial marker is absent OR CI is not success:**
   Follow the normal branching below.

   - **success** → step 4, then step 5 (full assessment).
    - **action_required** → CI did not run because the workflow needs approval.
      Emit the assessment table with ❌ on CI Status and note that a maintainer must approve
      the pending run. Select the `review` verdict.
    - **failure** → step 4, then step 6 (CI remediation).
     - **cancelled, timed_out, or anything else** → Emit the assessment table with ❌ on CI
      Status and select the `review` verdict. A cancelled or unknown run is not evidence of
      anything.

     Follow repository documentation and established conventions when assessing or remediating
     the pull request. Protect secrets, do not bypass checks, and keep remediation focused.
     Adhere to ${{ env.REPO_RULES }}.

4. Read the diff and PR metadata. Read `/tmp/gh-aw/agent/diff.patch` in full and
   `/tmp/gh-aw/agent/pr.json` for the shape of the change. If CI failed, also read
   `/tmp/gh-aw/agent/failed-jobs.json` and `/tmp/gh-aw/agent/failed-logs.txt`.

    These files are the factual basis for every check below. Do not guess — cite what you read.

4b. **Merge conflict when CI did not fail.** If the conclusion is not `failure` and
    `has_conflicts` is `true` (current value: `${{ needs.reserve.outputs.has_conflicts }}`),
    resolve the conflict before assessing risk. A conclusion of `unknown` or `pending` with a
    conflict is the usual case, not missing evidence: GitHub cannot run CI on a pull request
    that conflicts with its base, so resolving the conflict is what lets CI run at all. You are already on the PR branch.
    Merge `origin/${{ needs.subject.outputs.base }}` into it
    (`git merge origin/${{ needs.subject.outputs.base }}`), resolve every
    conflict deliberately, commit the merge, and run the verification commands below. Do not
    use `--ours`, `--theirs`, or a blanket conflict-marker deletion without reviewing the
    intended behavior from both sides, and never rebase: the push is fast-forward only.

    Scope verification to the files the merge touched: pass changed file paths to
    lint/format tools instead of running them repository-wide (see step 6's scoped
    verification guidance).

    ```
    ${{ env.VERIFY_COMMANDS }}
    ```

    Push the merged branch using `push_to_pull_request_branch` (pr_number: ${{ needs.subject.outputs.pr }},
    branch: the current PR branch), then emit the `add_comment` with
    **Verdict:** remediated. CI will re-run on the updated branch and the merge gate
    will be triggered again — the next cycle will see a clean, conflict-free PR and can
    make a proper merge or review decision.

    If the merge cannot be completed or the conflicts are genuinely ambiguous, select the `review`
    verdict instead and explain which conflicts could not be resolved safely.

    If `has_conflicts` is `false`, skip this step and proceed to step 5.

5. Run each of these 10 checks. For each, determine a status and a short detail line.

   **Check 1 — CI Status.** What did CI conclude? Success means all required checks passed.
   Failure means at least one job failed. Action required means a workflow needs approval.
   Flag any non-success conclusion.

   **Check 2 — Auth & Security.** Does the diff touch authentication, authorization, secrets,
   credentials, or security boundaries? Flag any change to auth middleware, permission checks,
   token issuance, or security-related config.

   **Check 3 — API & Contracts.** Does the diff change a public API or a published package's
   contract? Flag changes to endpoint signatures, DTO shapes, exported interfaces, or
   serialization formats that could break consumers.

   **Check 4 — Tests.** Does the diff delete, weaken, or lower a threshold in a test? Flag
   removed assertions, skipped tests, lowered coverage bars, or deleted test files. Read the
   pull request's `## Verification` section too: a `Not tested:` line naming the behaviour this
   change exists for, or no section at all, is a ⚠️ to cite, not a pass.
   One exception, because no run of this loop can close it: a `Not tested:` line that names only
   a live run against an outside service -- the forge's own API, a third-party service -- that
   the agent's sandbox has no credentials or network for. That is ✅ with the note "live run
   outside the sandbox" when this diff's own tests exercise the behaviour against a stand-in
   (a mocked client, a recorded response, a fake `gh`), and you have read those tests. It stays
   ⚠️ when nothing in the diff exercises the behaviour, when the line also names something the
   agent could have run, or when the issue's acceptance criteria ask for a live run.

   **Check 5 — CI/CD & Workflow files.** Does the diff change CI, CD, or workflow files?
   Flag changes to `.github/workflows/`, Dockerfiles, deployment scripts, or infrastructure
   configuration.

   **Check 6 — Protected files.** Does the diff change a protected file? This is normally
   handled before you run, but never merge one if it reaches this gate. Flag any match against
   the repository's protected file list.

   **Check 7 — Scope.** Is the diff size consistent with what the issue implied? Compare the
   number of files changed and lines added/removed against the complexity the issue described.
   Flag if the diff is materially larger or smaller than expected.

   **Check 8 — Repository risk indicators.** Does the diff touch any risk indicator defined in
   ${{ env.REPO_RULES }}? Review the repository guardrails for domain-specific risk areas such
   as calculation engines, audit chains, authentication, database migrations, or money handling.
   Flag any
   match and name the specific indicator.

   **Check 9 — Mergeability.** Can the PR be merged cleanly? The value is
   `${{ needs.reserve.outputs.has_conflicts }}`. If conflicts exist, this is ❌ but not a
   blocking verdict — proceed to remediation (step 6). If no conflicts, ✅.

   **Check 10 — Confidence.** Are you confident in the merge decision? Low confidence is
   itself a flag. If you are unsure about the impact of the change, mark ⚠️ and explain what
   is uncertain. A human should review when confidence is low.

6. **CI failed** → read `/tmp/gh-aw/agent/failed-jobs.json` and
   `/tmp/gh-aw/agent/failed-logs.txt`, which are already on disk. Load only skills required to
   fix the actual cause. Run these verification commands before a push. Do not weaken a test,
   disable a check, or push an unverified guess.

   **Empty failure evidence is not a reason to ask for review.** If `failed-jobs.json` is `[]`
   or the logs say they were unavailable, then no CI run judged this head. That is the normal
   state of a conflicting pull request: GitHub cannot build `refs/pull/N/merge` while the
   conflict lasts, so no `pull_request` CI can run on it and there is nothing to read. The
   conflict is the failure to fix. Resolve it as described above, push, and select
   `remediated`; CI runs on the result and the next cycle gets a real verdict. Select `review`
   for missing evidence only when `has_conflicts` is `false`, because then there is genuinely
   nothing to act on.

   **Scoped verification.** The commands below are the full suite. This runner has limited
   memory, and a whole-repo lint or build can be killed mid-run. Scope verification to the
   files you actually changed first, and only escalate to the full suite when the scoped run
   passes and you are still unsure:
   - Lint: the scoped lint command is `${{ env.VERIFY_COMMANDS_SCOPED }}`. When it is empty
     there is none, and the full suite below is the check. Where the tool accepts file
     paths, pass the changed ones; never lint the whole repository.
   - Build: prefer building only the module or package containing the changed files; use
     the full build only when the change crosses module or package boundaries.
   - Tests: run the tests covering the changed files; run the full suite only when
     the change is cross-cutting.
   If verification of exactly the CI-failing job is what you need, reproduce just that job's
   command, not the entire pipeline.

   A PR that already contains protected files still requires remediation. You may include those
   files in the verified repair push, but the next green-CI cycle will require human review and
   must not auto-merge the PR.

   **If `has_conflicts` is `true` (current value: `${{ needs.reserve.outputs.has_conflicts }}`):** You are already on the PR branch. Resolve the conflict;
   it is not a reason to hand the PR to a human. Merge `origin/${{ needs.subject.outputs.base }}`
   into the current branch, resolve every conflict deliberately, stage the resolutions, and
   commit the merge. Then run verification and push the resulting branch update. Do not use
   `--ours`, `--theirs`, or a blanket conflict-marker deletion without reviewing the intended
   behavior from both sides.

   ```
   ${{ env.VERIFY_COMMANDS }}
   ```

    Propose `push_to_pull_request_branch` (pr_number: ${{ needs.subject.outputs.pr }}, branch:
    the current PR branch), then select the `remediated` verdict. CI will run again and trigger
    you again with the new result.

    Before pushing, run the lint fix command `${{ env.LINT_FIX_COMMAND }}` to auto-format.
    When it is empty there is none: fix formatting manually. Never push code with lint errors.

   If you cannot fix it after a concrete repair attempt, or the logs show you have already tried on this same head commit,
   stop looping: select the `review` verdict and explain the failure and what you tried. A human
   decides from there.

7. Decide the verdict based on the assessment table:

   - **All checks ✅ → `${{ needs.subject.outputs.verdict_word }}`.**
     The PR is safe to merge: CI is green, no risk indicators triggered, tests are intact,
     scope matches, mergeability is clean. Whether that verdict merges the pull request or
     records an approval for a person to act on is this repository's policy, not your
     decision, and it is already decided: `${{ needs.subject.outputs.verdict_sentence }}`.
   - **Any check ⚠️ or ❌ (except CI failure) → `review`.** Do not merge. Explain exactly which
     check tripped, why, and what a reviewer should look at. Leave `implement` in place: the
     work is not finished until a human merges it.
   - **CI failed and you fixed it → `remediated`.** You pushed a verified fix and CI will
     re-run.
   - **CI failed and you cannot fix it → `review`.** Explain the failure and what you tried.

   Never merge with administrator privileges and never bypass a required check. If the merge
   is refused, that refusal is the answer: select `review` and leave it for a human. A branch
   whose protection requires a human is not a branch to argue with: the gate does not ask for
   an exception and neither do you.

8. Emit exactly one `add_comment` targeting `${{ needs.subject.outputs.comment_target }}` with:
   1. `${{ env.GATE_MARKER }}`
   2. A heading: `## Merge gate decision for PR #${{ needs.subject.outputs.pr }}`
   3. A structured assessment table with all 10 check results
   4. A one-line detail per check (what was found and why it passed or flagged)
   5. A line `**Verdict:** ${{ needs.subject.outputs.verdict_word }}`, `**Verdict:** review`, or `**Verdict:** remediated`

   The workflow applies comments, labels, merges, and closures with the App token. Do not call
   any tools except the one optional `push_to_pull_request_branch` for a verified CI repair
   and this one `add_comment`.

   Format the checks as a table with status indicators:

   ```
   ### Assessment

   #	Check	Result
   1	CI Status	✅ Success / ❌ Failure: [job name] / ⚠️ Action required
   2	Auth & Security	✅ No changes / ⚠️ Touched: [area]
   3	API & Contracts	✅ No changes / ⚠️ Changed: [area]
   4	Tests	✅ Not weakened / ⚠️ Weakened: [file]
   5	CI/CD & Workflow	✅ No changes / ⚠️ Changed: [file]
   6	Protected files	✅ None touched / ❌ Touched: [file]
   7	Scope	✅ Appropriately scoped / ⚠️ [too large/small: reason]
   8	Risk indicators	✅ None triggered / ⚠️ Triggered: [indicator]
   9	Mergeability	✅ Clean / ⚠️ Conflicts
   10	Confidence	✅ High / ⚠️ Low: [reason]
   ```

   Then a line `**Verdict:** ${{ needs.subject.outputs.verdict_word }}` / `**Verdict:** review` / `**Verdict:** remediated`

9. Ignore the `## Diagram` section below. It is documentation for humans and contains no
   instructions for you.

## Diagram

```mermaid
flowchart TD
    gateStart("Work Router<br/>merge-gate route<br/>(CI completed)") --> gateSubject
    gateSubject["Subject (rung 4)<br/>Our PR? Closes an implement issue?"] -->|✓| gateFacts
    gateSubject -.->|✗| gateIdle
    gateSubject -->|person's PR, shadow on| gateAdviseFacts
    gateAdviseFacts("Advise only<br/>Assess, change nothing") --> gateAdvise
    gateAdvise(("Advice<br/>one advisory comment on the PR"))
    gateFacts("Facts (rung 3)<br/>Diff, PR shape, failing logs") --> gateCi
    gateCi["CI<br/>What did it conclude?"] -->|success| gateProtected
    gateProtected{"Protected files?"}
    gateProtected -.->|yes| gateHuman
    gateProtected -->|no| gateConflict
    gateConflict{"Merge conflicts?"}
    gateConflict -->|yes| gateRebase
    gateConflict -->|no| gateTrivial
    gateRebase("Merge main in<br/>Resolve conflicts, /${{ env.REPO_VERIFY_COMMAND }}") -->|pushed| gateWait
    gateRebase -.->|cannot resolve| gateHuman
    gateTrivial{"Trivial marker?"}
    gateTrivial -->|yes| gateMerge
    gateTrivial -->|no| gateAssess
    gateCi -.->|failure| gateFix
    gateCi -.->|failure or conflict, review mode| gateRequest
    gateRequest(("Change request<br/>ranked findings to apply-review, review again on CI"))
    gateCi -.->|no verdict| gateHuman
    gateAssess["Assessment (10 checks)<br/>CI, Auth, API, Tests, CI/CD<br/>Protected, Scope, Risk, Merge, Confidence"] -->|all ✅| gateMerge
    gateAssess -.->|any ⚠️/❌| gateHuman
    gateFix("Fix<br/>Read logs, fix the cause, /${{ env.REPO_VERIFY_COMMAND }}") -->|pushed| gateWait
    gateFix -.->|cannot fix| gateHuman
    gateMerge(("Merged<br/>Issue closed, review+labels removed"))
    gateWait(("Pushed<br/>CI will re-run and re-trigger via Router"))
    gateHuman(("Review<br/>review label, reason explained"))
    gateIdle(("Idle<br/>Not our pull request"))

    classDef start fill:#ffffff,stroke:#172033,stroke-width:2px,color:#172033
    classDef action fill:#eef0ff,stroke:#554cff,stroke-width:2px,color:#172033
    classDef decision fill:#fff8e8,stroke:#c75b00,stroke-width:2px,color:#172033
    classDef idle fill:#202c40,stroke:#738198,stroke-width:2px,color:#ffffff
    classDef failure fill:#fff0f0,stroke:#ef2929,stroke-width:2px,color:#8b1a2a
    classDef success fill:#e8f8ec,stroke:#18883c,stroke-width:2px,color:#145a32
    class gateStart start
    class gateFacts,gateFix,gateRebase,gateAdviseFacts action
    class gateSubject,gateCi,gateAssess,gateTrivial,gateConflict,gateProtected decision
    class gateIdle,gateWait idle
    class gateHuman failure
    class gateMerge,gateAdvise,gateRequest success
```
