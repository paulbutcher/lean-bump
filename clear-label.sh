#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Removes resolve's needs-decision label from a bump PR that this run has pushed new changes to.
# The decision was about what the PR held before, and resolve skips a labelled PR, so without this
# the new changes would never be merged. Resolve labels the PR again if they need a decision too.
# A failure only warns: the PR is already updated.

set -euo pipefail
source "$(dirname "$0")/lib/github.sh"
REPORT_RATE_LIMIT=true

: "${REPO:?}" "${PR:?}" "${GITHUB_TOKEN:?}"
LABEL=${LABEL:-lean-bump: needs decision}

code=$(api DELETE "repos/$REPO/issues/$PR/labels/$(jq -rn --arg l "$LABEL" '$l | @uri')")
case $code in
  200) echo "bump: removed \`$LABEL\` from #$PR" ;;
  404) ;; # The PR does not have the label.
  *) echo "::warning::could not remove \`$LABEL\` from #$PR (HTTP $code): $(error_message)" ;;
esac
