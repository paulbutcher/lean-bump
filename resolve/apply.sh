#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Acts on what the agent left: pushes its fix or changelog entry to the PR branch, or labels the PR
# as needing a decision, and posts its comment. For give-up, comments and labels without an agent.
# In a dry run, only comments, with what it would have pushed.

set -euo pipefail
source "$(dirname "$0")/../lib/github.sh"

: "${ACTION:?}" "${REPO:?}" "${PR:?}" "${HEAD_SHA:?}" "${CONTEXT_DIR:?}" "${GITHUB_TOKEN:?}"
BRANCH=${BRANCH:-lean-bump}
LABEL=${LABEL:-lean-bump: needs decision}
DRY_RUN=${DRY_RUN:-false}

comment() {
  local code
  code=$(api POST "repos/$REPO/issues/$PR/comments" \
           "$(jq -cn --arg b "$1"$'\n\n'"<!-- lean-bump-resolve $HEAD_SHA -->" '{body: $b}')")
  [[ $code == 201 ]] || die "could not comment on #$PR (HTTP $code): $(error_message)"
}

label() {
  local code
  code=$(api POST "repos/$REPO/issues/$PR/labels" "$(jq -cn --arg l "$LABEL" '{labels: [$l]}')")
  [[ $code == 200 ]] || die "could not label #$PR (HTTP $code): $(error_message)"
}

if [[ $ACTION == give-up ]]; then
  msg="CI still fails after ${ATTEMPTS:-?} attempts to fix it, so this needs a person. The last run is $GITHUB_SERVER_URL/$REPO/actions/runs/$RUN_ID."
  if [[ $DRY_RUN == true ]]; then comment "**Dry run:** would label this \`$LABEL\`."$'\n\n'"$msg"
  else comment "$msg"; label; fi
  exit 0
fi

result=$CONTEXT_DIR/result.json
outcome=$(jq -r '.outcome // empty' "$result")
message=$(jq -r '.commit // empty' "$result")
body=$(jq -r '.comment // empty' "$result")
[[ -n $body ]] || die "the result has no comment"
case $ACTION:$outcome in
  fix:fixed|fix:needs-decision|changelog:changelog|changelog:needs-decision) ;;
  *) die "outcome '$outcome' is not one $ACTION can produce" ;;
esac

git add -A
changed=$(git diff --cached --name-only)
if [[ $outcome == needs-decision ]]; then
  git reset -q --hard
  if [[ $DRY_RUN == true ]]; then comment "**Dry run:** would label this \`$LABEL\`."$'\n\n'"$body"
  else comment "$body"; label; fi
  exit 0
fi

[[ -n $changed ]] || die "the agent reported $outcome but changed nothing"
[[ -n $message ]] || die "the result has no commit message"
! grep -q '^\.github/' <<< "$changed" || die "the agent changed files under .github/: $(grep '^\.github/' <<< "$changed")"
[[ $outcome != changelog || $changed == CHANGELOG.md ]] || die "a changelog result changed more than CHANGELOG.md: $changed"

if [[ $DRY_RUN == true ]]; then
  # A comment holds at most 65536 characters.
  comment "**Dry run:** would push"$'\n\n```diff\n'"$(git diff --cached | head -c 50000)"$'\n```\n\n'"$body"
  exit 0
fi

# Commits as the App's bot user, whose noreply address GitHub links to it by its user ID.
: "${APP_SLUG:?}"
code=$(api GET "users/$APP_SLUG%5Bbot%5D")
[[ $code == 200 ]] || die "could not look up $APP_SLUG[bot] (HTTP $code): $(error_message)"
bot_email="$(jq -r .id "$body_file")+$APP_SLUG[bot]@users.noreply.github.com"
[[ $outcome == fixed ]] && trailer=fix || trailer=changelog
git -c user.name="$APP_SLUG[bot]" -c user.email="$bot_email" \
  commit -q -m "$message" -m "Lean-Bump-Resolve: $trailer"
git push -q "https://x-access-token:$GITHUB_TOKEN@${GITHUB_SERVER_URL#https://}/$REPO.git" "HEAD:refs/heads/$BRANCH"
comment "$body"
