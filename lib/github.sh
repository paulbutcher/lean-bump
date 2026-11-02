# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

API=${GITHUB_API_URL:-https://api.github.com}
body_file=$(mktemp)
header_file=$(mktemp)
trap 'rm -f "$body_file" "$header_file"' EXIT

die() { echo "$(basename "$0"): $*" >&2; exit 1; }

# header NAME: prints the value of response header NAME from the last api call.
header() { grep -i "^$1:" "$header_file" | tail -n1 | cut -d: -f2- | tr -d ' \r' || true; }

# rate_limit_wait CODE ATTEMPT: prints how many seconds to wait before retrying a rate-limited
# request, following GitHub's guidance, or fails if the request was not rate limited.
rate_limit_wait() {
  local retry reset now
  [[ $1 == 403 || $1 == 429 ]] || return 1
  retry=$(header retry-after)
  if [[ -n $retry ]]; then echo "$retry"
  elif [[ $(header x-ratelimit-remaining) == 0 ]]; then
    reset=$(header x-ratelimit-reset) now=$(date +%s)
    echo $(( reset > now ? reset - now + 1 : 1 ))
  elif [[ $1 == 429 ]] || jq -e '.message // "" | test("rate limit"; "i")' "$body_file" > /dev/null 2>&1; then
    echo $(( 60 << $2 ))
  else return 1; fi
}

# api METHOD PATH [JSON]: prints the HTTP status and leaves the response body in $body_file.
# Writes are spaced a second apart, and a rate-limited request is retried after the wait GitHub
# asks for, up to four times. So is a read that hits a transient server error; a write is not,
# since it may have taken effect.
api() {
  local args=(-sS -o "$body_file" -D "$header_file" -w '%{http_code}' -X "$1" -H "Accept: application/vnd.github+json")
  local code attempt wait read=false
  [[ -n ${GITHUB_TOKEN:-} ]] && args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  (( $# >= 3 )) && args+=(-d "$3")
  [[ $1 == GET || $2 == graphql ]] && read=true || sleep 1
  for attempt in 0 1 2 3 4; do
    code=$(curl "${args[@]}" "$API/$2")
    if (( attempt == 4 )); then break
    elif wait=$(rate_limit_wait "$code" "$attempt"); then
      echo "rate limited on $1 $2 (HTTP $code), retrying in ${wait}s" >&2
    elif [[ $read == true && $code == 50[234] ]]; then
      wait=$(( 5 << attempt ))
      echo "server error on $1 $2 (HTTP $code), retrying in ${wait}s" >&2
    else break; fi
    sleep "$wait"
  done
  printf '%s' "$code"
}

# error_message: prints the message in the last api call's error response, if any.
error_message() { jq -r '.message // empty' "$body_file" 2>/dev/null || true; }

# Fills LAKE_REPOS with the owner's non-archived, non-fork repositories that have a root
# lake-manifest.json. Searched rather than listed, so private repositories the token can see
# are included, and in one GraphQL query per 100 repositories rather than a request for each.
find_lake_repos() {
  local query after=null code repo
  query='query($q: String!, $after: String) {
    search(query: $q, type: REPOSITORY, first: 100, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes { ... on Repository { nameWithOwner manifest: object(expression: "HEAD:lake-manifest.json") { __typename } } }
    }
  }'
  LAKE_REPOS=()
  while :; do
    code=$(api POST graphql "$(jq -cn --arg query "$query" --arg q "user:$1 archived:false fork:false" \
             --argjson after "$after" '{query: $query, variables: {q: $q, after: $after}}')")
    [[ $code == 200 ]] && ! jq -e .errors "$body_file" > /dev/null \
      || die "repository search failed (HTTP $code): $(cat "$body_file")"
    for repo in $(jq -r '.data.search.nodes[] | select(.manifest) | .nameWithOwner' "$body_file"); do
      LAKE_REPOS+=("$repo")
    done
    jq -e .data.search.pageInfo.hasNextPage "$body_file" > /dev/null || break
    after=$(jq -c .data.search.pageInfo.endCursor "$body_file")
  done
}

# dispatch REPO EVENT_TYPE SOURCE: returns non-zero if the event was not accepted.
dispatch() {
  local code
  code=$(api POST "repos/$1/dispatches" "$(jq -cn --arg e "$2" --arg s "$3" --arg r "${GITHUB_REF_NAME:-}" \
           '{event_type: $e, client_payload: {source: $s, ref: $r}}')")
  [[ $code == 204 ]] || { echo "could not notify $1 (HTTP $code): $(error_message)" >&2; return 1; }
  echo "notified $1"
}
