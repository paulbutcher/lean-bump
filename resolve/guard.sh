#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Decides what resolve does about a finished CI run, and sets action to one of:
#   skip       nothing to do: not the bump PR, an older commit, or already handled
#   fix        CI failed: the agent fixes the build or explains the decision it needs
#   give-up    CI failed again after MAX_ATTEMPTS fixes
#   changelog  CI passed on a library with no changelog entry: the agent writes one
#   release    CI passed on a library with its changelog entry: merge and tag
#   merge      CI passed on an application: merge
# Also sets pr and base, and leaves the PR description and failed CI logs in CONTEXT_DIR.

set -euo pipefail
source "$(dirname "$0")/../lib/github.sh"

: "${REPO:?}" "${OWNER:?}" "${RUN_ID:?}" "${HEAD_SHA:?}" "${HEAD_REPO:?}" "${HEAD_BRANCH:?}" "${CONCLUSION:?}"
: "${CONTEXT_DIR:?}"
BRANCH=${BRANCH:-lean-bump}
MAX_ATTEMPTS=${MAX_ATTEMPTS:-3}
LABEL=${LABEL:-lean-bump: needs decision}
GITHUB_OUTPUT=${GITHUB_OUTPUT:-/dev/null}

out() { echo "$1=$2" >> "$GITHUB_OUTPUT"; }
result() { echo "resolve: $2"; out action "$1"; exit 0; }

[[ $HEAD_BRANCH == "$BRANCH" && $HEAD_REPO == "$REPO" ]] || result skip "not a $BRANCH run in $REPO"
[[ $CONCLUSION == success || $CONCLUSION == failure ]] || result skip "CI concluded $CONCLUSION"

code=$(api GET "repos/$REPO/pulls?head=$OWNER:$BRANCH&state=open")
[[ $code == 200 ]] || die "could not list pull requests (HTTP $code): $(error_message)"
jq -e 'length > 0' "$body_file" > /dev/null || result skip "no open PR from $BRANCH"
pr=$(jq -r '.[0].number' "$body_file")
base=$(jq -r '.[0].base.ref' "$body_file")
out pr "$pr"
out base "$base"
[[ $(jq -r '.[0].head.sha' "$body_file") == "$HEAD_SHA" ]] || result skip "PR #$pr has moved on from $HEAD_SHA"
# Only the bump itself: opened by the owner's token or an App, never by someone else.
jq -e --arg o "$OWNER" '.[0].user | .login == $o or .type == "Bot"' "$body_file" > /dev/null \
  || result skip "PR #$pr was not opened by $OWNER or an App"
jq -e --arg l "$LABEL" '.[0].labels | any(.name == $l)' "$body_file" > /dev/null \
  && result skip "PR #$pr is waiting for a decision"
jq -r '.[0].body // ""' "$body_file" > "$CONTEXT_DIR/pr-description.md"

# Each run leaves a comment marked with the commit it acted on, so the second of the CI runs that
# a push and its pull_request event start finds the first one's and does nothing.
code=$(api GET "repos/$REPO/issues/$pr/comments?per_page=100")
[[ $code == 200 ]] || die "could not read comments on #$pr (HTTP $code): $(error_message)"
jq -e --arg m "<!-- lean-bump-resolve $HEAD_SHA -->" 'any(.body | contains($m))' "$body_file" > /dev/null \
  && result skip "PR #$pr was already handled at $HEAD_SHA"

if [[ $CONCLUSION == failure ]]; then
  code=$(api GET "repos/$REPO/pulls/$pr/commits?per_page=100")
  [[ $code == 200 ]] || die "could not list commits on #$pr (HTTP $code): $(error_message)"
  attempts=$(jq '[.[] | select(.commit.message | split("\n") | any(. == "Lean-Bump-Resolve: fix"))] | length' "$body_file")
  out attempts "$attempts"
  (( attempts < MAX_ATTEMPTS )) || result give-up "PR #$pr still fails after $attempts fixes"

  code=$(api GET "repos/$REPO/actions/runs/$RUN_ID/jobs?per_page=100")
  [[ $code == 200 ]] || die "could not list jobs of run $RUN_ID (HTTP $code): $(error_message)"
  : > "$CONTEXT_DIR/ci.log"
  # The log endpoint redirects to the log itself, which api does not follow.
  jq -r '.jobs[] | select(.conclusion == "failure") | "\(.id)\t\(.name)"' "$body_file" |
    while IFS=$'\t' read -r job name; do
      echo "=== job: $name" >> "$CONTEXT_DIR/ci.log"
      if curl -sSfL -o "$CONTEXT_DIR/job.log" -H "Authorization: Bearer $GITHUB_TOKEN" "$API/repos/$REPO/actions/jobs/$job/logs"
      then tail -n 3000 "$CONTEXT_DIR/job.log" >> "$CONTEXT_DIR/ci.log"
      else echo "(log unavailable)" >> "$CONTEXT_DIR/ci.log"; fi
    done
  result fix "CI failed on PR #$pr"
fi

# A push and its pull_request event each run CI. Act once every run on the commit has passed.
code=$(api GET "repos/$REPO/commits/$HEAD_SHA/check-runs?per_page=100")
[[ $code == 200 ]] || die "could not list checks on $HEAD_SHA (HTTP $code): $(error_message)"
jq -e '.check_runs | all(.status == "completed")' "$body_file" > /dev/null \
  || result skip "checks on $HEAD_SHA are still running"
jq -e '.check_runs | all(.conclusion | IN("success", "neutral", "skipped"))' "$body_file" > /dev/null \
  || result skip "another check on $HEAD_SHA failed"

[[ -f .github/workflows/lean_bump_notify.yml ]] || result merge "PR #$pr passed, and this is an application"
git fetch -q origin "refs/heads/$base"
git diff --quiet FETCH_HEAD...HEAD -- CHANGELOG.md || result release "PR #$pr passed with its changelog entry"
result changelog "PR #$pr passed and needs a changelog entry"
