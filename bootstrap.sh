#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

set -euo pipefail
here=$(dirname "$0")
source "$here/lib/github.sh"

: "${OWNER:?set OWNER to the account to bootstrap}"
EVENT_TYPE=${EVENT_TYPE:-lean-dependency-released}
DRY_RUN=${DRY_RUN:-false}
workflow=.github/workflows/lean-bump.yml
branch=lean-bump-install

install() {
  local repo=$1 code base sha
  code=$(api GET "repos/$repo/git/ref/heads/$branch")
  if [[ $code == 200 ]]; then echo "install PR pending for $repo"; return; fi
  if [[ $DRY_RUN == true ]]; then echo "would open install PR for $repo"; return; fi

  code=$(api GET "repos/$repo")
  [[ $code == 200 ]] || { echo "could not read $repo (HTTP $code)" >&2; return 1; }
  base=$(jq -r .default_branch "$body_file")
  code=$(api GET "repos/$repo/git/ref/heads/$base")
  [[ $code == 200 ]] || { echo "could not read $repo $base (HTTP $code)" >&2; return 1; }
  sha=$(jq -r .object.sha "$body_file")

  code=$(api POST "repos/$repo/git/refs" "$(jq -cn --arg r "refs/heads/$branch" --arg s "$sha" '{ref: $r, sha: $s}')")
  [[ $code == 201 ]] || { echo "could not create $branch in $repo (HTTP $code)" >&2; return 1; }
  code=$(api PUT "repos/$repo/contents/$workflow" "$(jq -cn --arg b "$branch" \
           --arg c "$(base64 < "$here/templates/lean-bump.yml" | tr -d '\n')" \
           '{message: "Add lean-bump workflow", content: $c, branch: $b}')")
  [[ $code == 201 ]] || { echo "could not add $workflow to $repo (HTTP $code)" >&2; return 1; }
  code=$(api POST "repos/$repo/pulls" "$(jq -cn --arg h "$branch" --arg b "$base" \
           '{title: "Add lean-bump workflow", head: $h, base: $b,
             body: "Keeps this package'\''s dependencies on its sibling packages current. See [lean-bump](https://github.com/paulbutcher/lean-bump)."}')")
  [[ $code == 201 ]] || { echo "could not open install PR in $repo (HTTP $code)" >&2; return 1; }
  echo "opened install PR: $(jq -r .html_url "$body_file")"
}

find_lake_repos "$OWNER"
status=$LAKE_REPOS_FAILED
for repo in "${LAKE_REPOS[@]}"; do
  code=$(api GET "repos/$repo/contents/$workflow")
  case $code in
    200)
      if [[ $DRY_RUN == true ]]; then echo "would notify $repo"
      else dispatch "$repo" "$EVENT_TYPE" bootstrap || status=1; fi ;;
    404) install "$repo" || status=1 ;;
    *) echo "could not check $repo (HTTP $code)" >&2; status=1 ;;
  esac
done
exit "$status"
