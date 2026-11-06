#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Runs Claude Code on the checked-out PR branch, with prompt.md followed by the context of this run.
# It has no GitHub credentials: it leaves its changes in the working tree and its outcome in
# CONTEXT_DIR/result.json, for apply.sh to act on.

set -euo pipefail

: "${ACTION:?}" "${REPO:?}" "${PR:?}" "${BASE:?}" "${CONTEXT_DIR:?}"
BRANCH=${BRANCH:-lean-bump}
ALLOWED_TOOLS=${ALLOWED_TOOLS:-Read Edit Write Glob Grep Bash(lake:*) Bash(git:*)}
here=$(cd "$(dirname "$0")" && pwd)

cp "$here/policy.md" "$CONTEXT_DIR/policy.md"
rm -f "$CONTEXT_DIR/result.json"

{
  cat "$here/prompt.md"
  echo
  echo "## Context"
  echo
  echo "- Repository: $REPO, PR #$PR from \`$BRANCH\` into \`$BASE\`"
  if [[ $ACTION == fix ]]; then
    echo "- CI: failed. The logs of the failed jobs are in \`$CONTEXT_DIR/ci.log\`."
  else
    echo "- CI: passed"
  fi
  echo "- PR description: \`$CONTEXT_DIR/pr-description.md\`"
  echo "- Policy: \`$CONTEXT_DIR/policy.md\`"
  echo "- Result file: \`$CONTEXT_DIR/result.json\`"
} > "$CONTEXT_DIR/prompt.md"

args=(-p --permission-mode acceptEdits --add-dir "$CONTEXT_DIR" --allowedTools "$ALLOWED_TOOLS")
[[ -n ${MODEL:-} ]] && args+=(--model "$MODEL")
claude "${args[@]}" < "$CONTEXT_DIR/prompt.md"

[[ -f $CONTEXT_DIR/result.json ]] || { echo "run: the agent wrote no result" >&2; exit 1; }
