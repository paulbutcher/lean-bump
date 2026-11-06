#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

set -euo pipefail
here=$(dirname "$0")
source "$here/lib/github.sh"

: "${OWNER:?set OWNER to the account to bootstrap}"
EVENT_TYPE=${EVENT_TYPE:-lean-dependency-released}
DRY_RUN=${DRY_RUN:-false}
workflows=.github/workflows
branch=lean-bump-install

# stale REPO: prints "NAME SHA" for each workflow in templates/ that the repository's default branch
# lacks or has a different copy of, SHA being the blob to replace or - for a new file. Every package
# gets the bump and resolve workflows. Notify is only updated, never added: it marks a library, which
# is for the package to say.
stale() {
  local repo=$1 name code
  for name in lean-bump.yml lean-bump-resolve.yml lean_bump_notify.yml; do
    code=$(api GET "repos/$repo/contents/$workflows/$name")
    case $code in
      200) jq -r .content "$body_file" | base64 -d | cmp -s - "$here/templates/$name" \
             || echo "$name $(jq -r .sha "$body_file")" ;;
      404) [[ $name == lean_bump_notify.yml ]] || echo "$name -" ;;
      *) echo "could not check $repo (HTTP $code)" >&2; return 1 ;;
    esac
  done
}

# install REPO STALE: opens one PR adding or updating every workflow in STALE.
install() {
  local repo=$1 stale=$2 code base sha name blob
  code=$(api GET "repos/$repo/git/ref/heads/$branch")
  if [[ $code == 200 ]]; then echo "install PR pending for $repo"; return; fi
  if [[ $DRY_RUN == true ]]; then echo "would open install PR for $repo:" $(cut -d' ' -f1 <<< "$stale"); return; fi

  code=$(api GET "repos/$repo")
  [[ $code == 200 ]] || { echo "could not read $repo (HTTP $code)" >&2; return 1; }
  base=$(jq -r .default_branch "$body_file")
  code=$(api GET "repos/$repo/git/ref/heads/$base")
  [[ $code == 200 ]] || { echo "could not read $repo $base (HTTP $code)" >&2; return 1; }
  sha=$(jq -r .object.sha "$body_file")

  code=$(api POST "repos/$repo/git/refs" "$(jq -cn --arg r "refs/heads/$branch" --arg s "$sha" '{ref: $r, sha: $s}')")
  [[ $code == 201 ]] || { echo "could not create $branch in $repo (HTTP $code)" >&2; return 1; }
  while read -r name blob; do
    code=$(api PUT "repos/$repo/contents/$workflows/$name" "$(jq -cn --arg b "$branch" --arg n "$name" --arg s "$blob" \
             --arg c "$(base64 < "$here/templates/$name" | tr -d '\n')" \
             '{message: ((if $s == "-" then "Add " else "Update " end) + $n), content: $c, branch: $b}
              + (if $s == "-" then {} else {sha: $s} end)')")
    [[ $code == 200 || $code == 201 ]] || { echo "could not write $name in $repo (HTTP $code)" >&2; return 1; }
  done <<< "$stale"
  code=$(api POST "repos/$repo/pulls" "$(jq -cn --arg h "$branch" --arg b "$base" --arg f "$(cut -d' ' -f1 <<< "$stale")" \
           '{title: "Install lean-bump workflows", head: $h, base: $b,
             body: ("Adds or updates the workflows that keep this package'\''s dependencies on its sibling packages current. See [lean-bump](https://github.com/paulbutcher/lean-bump).\n\n"
                    + ($f | split("\n") | map("- `\(.)`") | join("\n")))}')")
  [[ $code == 201 ]] || { echo "could not open install PR in $repo (HTTP $code)" >&2; return 1; }
  echo "opened install PR: $(jq -r .html_url "$body_file")"
}

find_lake_repos "$OWNER"
status=0
for repo in "${LAKE_REPOS[@]}"; do
  stale=$(stale "$repo") || { status=1; continue; }
  # A package whose bump workflow is installed, even an older copy, can be notified now.
  if ! grep -qx 'lean-bump.yml -' <<< "$stale"; then
    if [[ $DRY_RUN == true ]]; then echo "would notify $repo"
    else dispatch "$repo" "$EVENT_TYPE" bootstrap || status=1; fi
  fi
  [[ -z $stale ]] || install "$repo" "$stale" || status=1
done
exit "$status"
