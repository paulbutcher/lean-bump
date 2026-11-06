#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Merges the PR at HEAD_SHA and, for release, tags the merge with the version of the newest
# changelog entry, in the form of the latest release tag. The tag is created with the App's token,
# so it starts the package's notify workflow.

set -euo pipefail
source "$(dirname "$0")/../lib/github.sh"

: "${ACTION:?}" "${REPO:?}" "${PR:?}" "${HEAD_SHA:?}" "${GITHUB_TOKEN:?}"
MERGE_METHOD=${MERGE_METHOD:-merge}
DRY_RUN=${DRY_RUN:-false}

if [[ $ACTION == release ]]; then
  version=$(sed -nE 's/^## \[([0-9]+\.[0-9]+\.[0-9]+)\].*/\1/p' CHANGELOG.md | head -n1)
  [[ -n $version ]] || die "CHANGELOG.md has no entry with a version"
  latest=$(git tag -l | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1 || true)
  [[ $latest == [0-9]* ]] && tag=$version || tag=v$version
  [[ -z $latest || $(printf '%s\n' "${latest#v}" "$version" | sort -V | tail -n1) != "${latest#v}" ]] \
    || die "the changelog's $version is not newer than $latest"
fi

if [[ $DRY_RUN == true ]]; then
  msg="**Dry run:** would merge this"
  [[ $ACTION == release ]] && msg+=" and tag \`$tag\`"
  code=$(api POST "repos/$REPO/issues/$PR/comments" \
           "$(jq -cn --arg b "$msg."$'\n\n'"<!-- lean-bump-resolve $HEAD_SHA -->" '{body: $b}')")
  [[ $code == 201 ]] || die "could not comment on #$PR (HTTP $code): $(error_message)"
  exit 0
fi

# Merging at HEAD_SHA fails if anything was pushed since CI passed, rather than merging it unchecked.
code=$(api PUT "repos/$REPO/pulls/$PR/merge" "$(jq -cn --arg s "$HEAD_SHA" --arg m "$MERGE_METHOD" '{sha: $s, merge_method: $m}')")
[[ $code == 200 ]] || die "could not merge #$PR (HTTP $code): $(error_message)"
merged=$(jq -r .sha "$body_file")
echo "merged #$PR as $merged"
[[ $ACTION == release ]] || exit 0

code=$(api POST "repos/$REPO/git/refs" "$(jq -cn --arg r "refs/tags/$tag" --arg s "$merged" '{ref: $r, sha: $s}')")
[[ $code == 201 ]] || die "could not tag $merged as $tag (HTTP $code): $(error_message)"
echo "tagged $merged as $tag"
