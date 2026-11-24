#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Starts the repository's own bump workflow, with the event a release of a dependency sends, so it
# rebuilds the bump PR on its base as it is now.

set -euo pipefail
source "$(dirname "$0")/../lib/github.sh"
REPORT_RATE_LIMIT=true

: "${REPO:?}" "${PR:?}" "${GITHUB_TOKEN:?}"
EVENT_TYPE=${EVENT_TYPE:-lean-dependency-released}
DRY_RUN=${DRY_RUN:-false}

if [[ $DRY_RUN == true ]]; then echo "would rebuild #$PR on its base"
else dispatch "$REPO" "$EVENT_TYPE" resolve; fi
