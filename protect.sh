#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Gives each Lake package's default branch a ruleset requiring its CI jobs to pass, so resolve can
# merge nothing CI has not passed. The jobs are read from the CI workflow's latest successful run on
# that branch, and must be reported by GitHub Actions. Repository admins may bypass it, so the owner
# can still push directly; the App cannot. Rerunning updates the ruleset in place.

set -euo pipefail
source "$(dirname "$0")/lib/github.sh"

: "${OWNER:?set OWNER to the account to protect}"
CI_WORKFLOW=${CI_WORKFLOW:-Lean Action CI}
DRY_RUN=${DRY_RUN:-false}
ruleset=lean-bump
github_actions=15368
admin_role=5

# protect REPO: creates or updates the ruleset in REPO, or fails.
protect() {
  local repo=$1 code base workflow run jobs id body
  code=$(api GET "repos/$repo")
  [[ $code == 200 ]] || { echo "could not read $repo (HTTP $code)" >&2; return 1; }
  base=$(jq -r .default_branch "$body_file")

  code=$(api GET "repos/$repo/actions/workflows?per_page=100")
  [[ $code == 200 ]] || { echo "could not list workflows in $repo (HTTP $code)" >&2; return 1; }
  workflow=$(jq -r --arg n "$CI_WORKFLOW" '.workflows[] | select(.name == $n) | .id' "$body_file" | head -n1)
  [[ -n $workflow ]] || { echo "skipping $repo: no $CI_WORKFLOW workflow"; return; }
  code=$(api GET "repos/$repo/actions/workflows/$workflow/runs?branch=$base&status=success&per_page=1")
  [[ $code == 200 ]] || { echo "could not list runs in $repo (HTTP $code)" >&2; return 1; }
  run=$(jq -r '.workflow_runs[0].id // empty' "$body_file")
  [[ -n $run ]] || { echo "skipping $repo: $CI_WORKFLOW has never passed on $base"; return; }
  code=$(api GET "repos/$repo/actions/runs/$run/jobs?per_page=100")
  [[ $code == 200 ]] || { echo "could not list jobs in $repo (HTTP $code)" >&2; return 1; }
  jobs=$(jq -c '[.jobs[] | select(.conclusion == "success") | .name] | unique' "$body_file")
  [[ $jobs != '[]' ]] || { echo "skipping $repo: no passing jobs in run $run"; return; }

  code=$(api GET "repos/$repo/rulesets")
  [[ $code == 200 ]] || { echo "could not list rulesets in $repo (HTTP $code)" >&2; return 1; }
  id=$(jq -r --arg n "$ruleset" '.[] | select(.name == $n) | .id' "$body_file" | head -n1)
  if [[ $DRY_RUN == true ]]; then
    echo "would $([[ -n $id ]] && echo update || echo create) ruleset in $repo requiring: $(jq -r 'join(", ")' <<< "$jobs")"
    return
  fi

  body=$(jq -cn --arg n "$ruleset" --argjson jobs "$jobs" --argjson app "$github_actions" --argjson admin "$admin_role" '{
    name: $n, target: "branch", enforcement: "active",
    conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
    bypass_actors: [{actor_id: $admin, actor_type: "RepositoryRole", bypass_mode: "always"}],
    rules: [{type: "required_status_checks", parameters: {
      strict_required_status_checks_policy: false,
      required_status_checks: [$jobs[] | {context: ., integration_id: $app}]}}]}')
  if [[ -n $id ]]; then
    code=$(api PUT "repos/$repo/rulesets/$id" "$body")
    [[ $code == 200 ]] || { echo "could not update ruleset in $repo (HTTP $code): $(error_message)" >&2; return 1; }
    echo "updated ruleset in $repo requiring: $(jq -r 'join(", ")' <<< "$jobs")"
  else
    code=$(api POST "repos/$repo/rulesets" "$body")
    [[ $code == 201 ]] || { echo "could not create ruleset in $repo (HTTP $code): $(error_message)" >&2; return 1; }
    echo "created ruleset in $repo requiring: $(jq -r 'join(", ")' <<< "$jobs")"
  fi
}

find_lake_repos "$OWNER"
status=0
for repo in "${LAKE_REPOS[@]}"; do
  protect "$repo" || status=1
done
exit "$status"
