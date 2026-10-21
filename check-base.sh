#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Sets changed=false if the base branch has picked up the bump since checkout, for example because
# an earlier bump PR was merged during this run. There is then nothing to open a PR for, and
# create-pull-request would fail with no commits between the branches.

set -euo pipefail

GITHUB_OUTPUT=${GITHUB_OUTPUT:-/dev/null}

result() { echo "changed=$1" >> "$GITHUB_OUTPUT"; exit 0; }

cd "$(git rev-parse --show-toplevel)"
# The PR is opened against the checked-out branch. Without one, create-pull-request reports the error.
base=$(git symbolic-ref -q --short HEAD) || result true
git fetch -q --depth 1 origin "refs/heads/$base"

# Whether the working copy of a path matches the base branch, a missing file matching a missing file.
matches() {
  if [[ -e $1 ]]; then [[ $(git hash-object -- "$1") == "$(git rev-parse -q --verify "FETCH_HEAD:$1" || true)" ]]
  else ! git cat-file -e "FETCH_HEAD:$1" 2>/dev/null; fi
}

while IFS= read -r -d '' path; do
  matches "$path" || result true
done < <(git diff -z --name-only HEAD; git ls-files -z --others --exclude-standard)
echo "bump: $base already has these changes"
result false
