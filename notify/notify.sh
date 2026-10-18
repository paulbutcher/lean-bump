#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

set -euo pipefail
source "$(dirname "$0")/../lib/github.sh"

: "${OWNER:?set OWNER to the account whose repositories are notified}"
SOURCE=${SOURCE:-}
EVENT_TYPE=${EVENT_TYPE:-lean-dependency-released}
DRY_RUN=${DRY_RUN:-false}

find_lake_repos "$OWNER"
status=$LAKE_REPOS_FAILED
for repo in "${LAKE_REPOS[@]}"; do
  [[ $repo != "$SOURCE" ]] || continue
  if [[ $DRY_RUN == true ]]; then echo "would notify $repo"
  else dispatch "$repo" "$EVENT_TYPE" "$SOURCE" || status=1; fi
done
exit "$status"
