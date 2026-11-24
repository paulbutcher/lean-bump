#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Sends EVENT_TYPE to each Lake package in the account with a project that requires SOURCE, or to
# every one if SOURCE is unset.

set -euo pipefail
source "$(dirname "$0")/../lib/github.sh"
REPORT_RATE_LIMIT=true

: "${OWNER:?set OWNER to the account whose repositories are notified}"
SOURCE=${SOURCE:-}
EVENT_TYPE=${EVENT_TYPE:-lean-dependency-released}
DRY_RUN=${DRY_RUN:-false}

# requires_source REPO: whether a Lake project in REPO requires SOURCE directly, on its default
# branch. Bump moves each project's direct requires, finding projects by every lake-manifest.json
# outside .lake, so every one is read, not only the root's. Where it cannot tell, the answer is yes:
# a needless bump costs less than a missed release.
requires_source() {
  local code manifest sha path status text
  code=$(api GET "repos/$1/git/trees/HEAD?recursive=1")
  [[ $code == 200 ]] || { echo "could not list $1's files (HTTP $code): notifying it anyway" >&2; return 0; }
  ! jq -e .truncated "$body_file" > /dev/null || { echo "$1's file list is truncated: notifying it anyway" >&2; return 0; }
  local manifests
  mapfile -t manifests < <(jq -r '.tree[]
    | select(.type == "blob" and (.path | test("(^|/)lake-manifest\\.json$")) and (.path | test("(^|/)\\.(lake|git)/") | not))
    | "\(.sha)\t\(.path)"' "$body_file")
  for manifest in "${manifests[@]}"; do
    IFS=$'\t' read -r sha path <<< "$manifest"
    code=$(api GET "repos/$1/git/blobs/$sha")
    [[ $code == 200 ]] || { echo "could not read $1's $path (HTTP $code): notifying it anyway" >&2; return 0; }
    status=0
    text=$(jq -r .content "$body_file" | base64 -d 2> /dev/null) || status=2
    (( status )) || jq -e --arg s "${SOURCE,,}" '
      any(.packages[]?; .type == "git" and .inherited == false
        and ((.url // "") | ascii_downcase | [capture("github\\.com[/:](?<r>[^/]+/[^/]+?)(\\.git)?/?$")? | .r]) == [$s])
    ' <<< "$text" > /dev/null 2>&1 || status=$?
    case $status in
      0) return 0 ;;
      1) ;;
      *) echo "could not parse $1's $path: notifying it anyway" >&2; return 0 ;;
    esac
  done
  return 1
}

find_lake_repos "$OWNER"
status=0
for repo in "${LAKE_REPOS[@]}"; do
  [[ $repo != "$SOURCE" ]] || continue
  if [[ -n $SOURCE ]] && ! requires_source "$repo"; then echo "skipping $repo: nothing in it requires $SOURCE"
  elif [[ $DRY_RUN == true ]]; then echo "would notify $repo"
  else dispatch "$repo" "$EVENT_TYPE" "$SOURCE" || status=1; fi
done
exit "$status"
