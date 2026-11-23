#!/usr/bin/env bash
# Managed by @software-factory-dev/cli@0.5.1. Source: loops/actions/authorize-actor/authorize-actor.sh. Profile digest: ccaabc0b4a1d. Update with `workflows update --force`; consumer edits may be overwritten.
#
# May the actor of this event start an agent? Public repositories must ask before an event can
# start a model. Writes `trusted` and `is_outside_collaborator` (`true` or `false`) to
# GITHUB_OUTPUT.
#
#   no human actor (schedule, workflow_run, workflow_dispatch)   trusted
#   the workflow token's bot, or the profile's App               trusted
#   write, maintain or admin, and an organisation member         trusted
#   write, maintain or admin, not a member                       trusted, outside collaborator
#   read                                                         not trusted, outside collaborator
#   anything else, or a permission that cannot be read           not trusted
#
# An outside collaborator is what the triage route is for.
#
# Environment: GH_TOKEN, ACTOR, EVENT, BOT_LOGIN (the profile's App login), GITHUB_REPOSITORY,
# GITHUB_OUTPUT.

set -euo pipefail

verdict() {
  {
    echo "trusted=$1"
    echo "is_outside_collaborator=$2"
  } >> "$GITHUB_OUTPUT"
}

# Events with no human actor. `schedule` and `workflow_run` are the fleet triggering itself;
# `workflow_dispatch` is already restricted by GitHub to write and above.
case "$EVENT" in
  schedule | workflow_run | workflow_dispatch)
    verdict true false
    echo "::notice::$EVENT has no untrusted actor."
    exit 0
    ;;
esac

# The bot App owns Safe Outputs. Its label changes must be able to start the follow-on worker,
# even though GitHub does not report it as a repository collaborator.
if [ "$ACTOR" = "github-actions[bot]" ] || [ "$ACTOR" = "$BOT_LOGIN" ]; then
  verdict true false
  exit 0
fi

permission=$(gh api "repos/$GITHUB_REPOSITORY/collaborators/$ACTOR/permission" \
  --jq '.permission' 2>/dev/null || echo "none")

# Outside collaborators can have write or maintain permission on a repository without being
# organisation members, and a non-member with write access is still outside.
org=$(echo "$GITHUB_REPOSITORY" | cut -d/ -f1)
is_member=false
if gh api "orgs/$org/members/$ACTOR" >/dev/null 2>&1; then
  is_member=true
fi

case "$permission" in
  admin | maintain | write)
    if [ "$is_member" = "true" ]; then
      verdict true false
      echo "::notice::$ACTOR has $permission permission and is an org member."
    else
      verdict true true
      echo "::notice::$ACTOR has $permission permission but is NOT an org member (outside collaborator). Triage route eligible."
    fi
    ;;
  read)
    verdict false true
    echo "::notice::$ACTOR is an outside collaborator (read permission). Triage route eligible."
    ;;
  *)
    verdict false false
    echo "::notice::$ACTOR has '$permission' permission on this repository. No agent will run."
    ;;
esac
