#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Sets open=true if a PR from BRANCH is open. When the bump has nothing to push, create-pull-request
# still runs for such a PR, and closes it: the base already has everything it changes.

set -euo pipefail
source "$(dirname "$0")/lib/github.sh"

: "${REPO:?}" "${BRANCH:?}" "${GITHUB_TOKEN:?}"
GITHUB_OUTPUT=${GITHUB_OUTPUT:-/dev/null}

code=$(api GET "repos/$REPO/pulls?head=${REPO%%/*}:$BRANCH&state=open")
[[ $code == 200 ]] || die "could not list pull requests (HTTP $code): $(error_message)"
if jq -e 'length > 0' "$body_file" > /dev/null; then
  echo "bump: closing #$(jq -r '.[0].number' "$body_file"), since the base already has everything it changes"
  echo "open=true" >> "$GITHUB_OUTPUT"
else echo "open=false" >> "$GITHUB_OUTPUT"; fi
