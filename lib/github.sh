# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

API=${GITHUB_API_URL:-https://api.github.com}
body_file=$(mktemp)
trap 'rm -f "$body_file"' EXIT

die() { echo "$(basename "$0"): $*" >&2; exit 1; }

# api METHOD PATH [JSON]: prints the HTTP status and leaves the response body in $body_file.
api() {
  local args=(-sS -o "$body_file" -w '%{http_code}' -X "$1" -H "Accept: application/vnd.github+json")
  [[ -n ${GITHUB_TOKEN:-} ]] && args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  (( $# >= 3 )) && args+=(-d "$3")
  curl "${args[@]}" "$API/$2"
}

# Fills LAKE_REPOS with the owner's non-archived, non-fork repositories that have a root
# lake-manifest.json. Searched rather than listed, so private repositories the token can see
# are included.
find_lake_repos() {
  local q page=1 code names count repo
  q=$(jq -rn --arg q "user:$1 archived:false fork:false" '$q | @uri')
  LAKE_REPOS=()
  LAKE_REPOS_FAILED=0
  while :; do
    code=$(api GET "search/repositories?q=$q&per_page=100&page=$page")
    [[ $code == 200 ]] || die "repository search failed (HTTP $code): $(cat "$body_file")"
    names=$(jq -r '.items[].full_name' "$body_file")
    count=$(jq '.items | length' "$body_file")
    for repo in $names; do
      code=$(api GET "repos/$repo/contents/lake-manifest.json")
      case $code in
        200) LAKE_REPOS+=("$repo") ;;
        404) ;;
        *) echo "could not check $repo (HTTP $code)" >&2; LAKE_REPOS_FAILED=1 ;;
      esac
    done
    (( count == 100 )) || break
    page=$((page + 1))
  done
}

# dispatch REPO EVENT_TYPE SOURCE: returns non-zero if the event was not accepted.
dispatch() {
  local code
  code=$(api POST "repos/$1/dispatches" "$(jq -cn --arg e "$2" --arg s "$3" --arg r "${GITHUB_REF_NAME:-}" \
           '{event_type: $e, client_payload: {source: $s, ref: $r}}')")
  [[ $code == 204 ]] || { echo "could not notify $1 (HTTP $code)" >&2; return 1; }
  echo "notified $1"
}
