#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Runs notify and bootstrap against a fake curl serving a fixed account:
#   o/done     Lake package with the workflow installed
#   o/new      Lake package without it
#   o/pending  Lake package without it, install PR already open
#   o/other    not a Lake package

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/api"

# A fixture's first line is the status, optionally followed by one response header.
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=/dev/null headers=/dev/null method=GET data=
while (( $# > 1 )); do
  case $1 in
    -o) out=$2; shift ;;
    -D) headers=$2; shift ;;
    -X) method=$2; shift ;;
    -d) data=$2; shift ;;
    -w|-H) shift ;;
  esac
  shift
done
path=${1#http://fake/}
echo "$method $path $data" >> "$FAKE_API/requests"
fixture=$FAKE_API/$method:${path//\//%}
[[ $path == graphql ]] && cursor=$(jq -r '.variables.after // empty' <<< "$data") || cursor=
[[ -n $cursor ]] && fixture=$fixture@$cursor
# A fixture ending in ! answers once, ahead of the plain one.
[[ -f $fixture! ]] && { mv "$fixture!" "$FAKE_API/used"; fixture=$FAKE_API/used; }
if [[ -f $fixture ]]; then
  read -r code header < "$fixture"; printf '%s\n' "$header" > "$headers"; tail -n +2 "$fixture" > "$out"
elif [[ $method == POST && $path == */dispatches ]]; then code=204; : > "$out"
elif [[ $method != GET ]]; then code=201; echo '{"html_url": "https://example/pr"}' > "$out"
else code=404; echo '{}' > "$out"; fi
printf '%s' "$code"
EOF
printf '#!/usr/bin/env bash\necho "$1" >> "$FAKE_API/sleeps"\n' > "$T/bin/sleep"
chmod +x "$T/bin/curl" "$T/bin/sleep"

fixture() { local f=${1/\//:}; f=${f//\//%}; printf '%s\n%s\n' "$2" "${3:-{\}}" > "$T/api/$f"; }
# search NODES [CURSOR]: a GraphQL search page of NODES, with a next page at CURSOR if given.
search() {
  jq -cn --argjson n "$1" --arg c "${2:-}" \
    '{data: {search: {pageInfo: {hasNextPage: ($c != ""), endCursor: (if $c == "" then null else $c end)}, nodes: $n}}}'
}
repo() { jq -cn --arg r "$1" --argjson lake "$2" '{nameWithOwner: $r, manifest: (if $lake then {__typename: "Blob"} else null end)}'; }
account=$(search "[$(repo o/done true), $(repo o/new true), $(repo o/pending true), $(repo o/other false)]")
fixture POST/graphql 200 "$account"
# installed REPO NAME [FILE]: REPO has workflow NAME on its default branch, a copy of FILE or else of its template.
installed() {
  fixture "GET/repos/$1/contents/.github/workflows/$2" 200 \
    "$(jq -cn --arg c "$(base64 < "${3:-$root/templates/$2}")" '{content: $c, sha: "blob"}')"
}
for w in lean-bump.yml lean-bump-resolve.yml lean_bump_notify.yml; do installed o/done "$w"; done
fixture GET/repos/o/pending/git/ref/heads/lean-bump-install 200
fixture GET/repos/o/new 200 '{"default_branch": "main"}'
fixture GET/repos/o/new/git/ref/heads/main 200 '{"object": {"sha": "abc123"}}'

failures=0
check() {
  if [[ $2 == "$3" ]]; then echo "ok   $1"
  else printf 'FAIL %s:\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"; failures=$((failures + 1)); fi
}
run() { : > "$T/api/requests"; : > "$T/api/sleeps"; PATH="$T/bin:$PATH" FAKE_API=$T/api GITHUB_API_URL=http://fake OWNER=o "$@" 2>&1; }
writes() { grep -v -e '^GET ' -e '^POST graphql ' "$T/api/requests" | cut -d' ' -f1,2 | paste -sd';' || true; }
sleeps() { paste -sd' ' "$T/api/sleeps"; }

out=$(run env SOURCE=o/done "$root/notify/notify.sh")
check "notify dispatches to every other Lake package" "$(writes)" \
  "POST repos/o/new/dispatches;POST repos/o/pending/dispatches"
check "notify reports each dispatch" "$(grep -c '^notified' <<< "$out")" 2
check "notify finds Lake packages with a single request" "$(grep -c . "$T/api/requests")" 3
check "notify spaces dispatches a second apart" "$(sleeps)" "1 1"

out=$(run env DRY_RUN=true "$root/bootstrap.sh")
check "a bootstrap dry run writes nothing" "$(writes)" ""
check "a bootstrap dry run reports the plan" "$out" \
  $'would notify o/done\nwould open install PR for o/new: lean-bump.yml lean-bump-resolve.yml\ninstall PR pending for o/pending'

out=$(run "$root/bootstrap.sh")
check "bootstrap notifies installed packages and installs the workflows elsewhere" "$(writes)" \
  "POST repos/o/done/dispatches;POST repos/o/new/git/refs;PUT repos/o/new/contents/.github/workflows/lean-bump.yml;PUT repos/o/new/contents/.github/workflows/lean-bump-resolve.yml;POST repos/o/new/pulls"
check "the install branch starts at the default branch head" \
  "$(grep '^POST repos/o/new/git/refs' "$T/api/requests" | cut -d' ' -f3- | jq -c .)" \
  '{"ref":"refs/heads/lean-bump-install","sha":"abc123"}'
for w in lean-bump.yml lean-bump-resolve.yml; do
  check "the installed $w is the template" \
    "$(grep "^PUT repos/o/new/contents/.github/workflows/$w " "$T/api/requests" | cut -d' ' -f3- | jq -r .content | base64 -d)" \
    "$(cat "$root/templates/$w")"
done
check "the install PR lists the workflows" \
  "$(grep '^POST repos/o/new/pulls' "$T/api/requests" | cut -d' ' -f3- | jq -r .body | tail -n2)" \
  $'- `lean-bump.yml`\n- `lean-bump-resolve.yml`'

printf 'old\n' > "$T/old.yml"
installed o/done lean-bump.yml "$T/old.yml"
installed o/done lean_bump_notify.yml "$T/old.yml"
rm "$T/api/GET:repos%o%done%contents%.github%workflows%lean-bump-resolve.yml"
fixture GET/repos/o/done 200 '{"default_branch": "main"}'
fixture GET/repos/o/done/git/ref/heads/main 200 '{"object": {"sha": "def456"}}'
out=$(run "$root/bootstrap.sh")
check "bootstrap updates outdated workflows and adds missing ones, notify included" \
  "$(writes | tr ';' '\n' | grep o/done | paste -sd';')" \
  "POST repos/o/done/dispatches;POST repos/o/done/git/refs;PUT repos/o/done/contents/.github/workflows/lean-bump.yml;PUT repos/o/done/contents/.github/workflows/lean-bump-resolve.yml;PUT repos/o/done/contents/.github/workflows/lean_bump_notify.yml;POST repos/o/done/pulls"
check "an updated workflow replaces the blob it read, and an added one has none" \
  "$(grep '^PUT repos/o/done/' "$T/api/requests" | cut -d' ' -f3- | jq -c '[.message, .sha]' | paste -sd' ')" \
  '["Update lean-bump.yml","blob"] ["Add lean-bump-resolve.yml",null] ["Update lean_bump_notify.yml","blob"]'
for w in lean-bump.yml lean-bump-resolve.yml lean_bump_notify.yml; do installed o/done "$w"; done

fixture POST/graphql 200 "$(search "$(jq -cn '[range(100) | {nameWithOwner: "o/r\(.)", manifest: null}]')" c2)"
fixture POST/graphql@c2 200 "$(search "[$(repo o/last true)]")"
out=$(run "$root/notify/notify.sh")
check "notify follows search results past the first page" "$(writes)" "POST repos/o/last/dispatches"
rm "$T"/api/*@*
fixture POST/graphql 200 "$account"

fixture 'POST/repos/o/new/dispatches!' '429 retry-after: 7'
out=$(run env SOURCE=o/done "$root/notify/notify.sh") && status=0 || status=$?
check "a rate-limited dispatch is retried after the wait GitHub asks for" "$(sleeps)" "1 7 1"
check "a run that recovers from a rate limit succeeds" "$status;$(writes)" \
  "0;POST repos/o/new/dispatches;POST repos/o/new/dispatches;POST repos/o/pending/dispatches"

fixture 'POST/repos/o/new/dispatches!' 403 '{"message": "You have exceeded a secondary rate limit."}'
out=$(run env SOURCE=o/done "$root/notify/notify.sh") && status=0 || status=$?
check "a secondary rate limit without retry-after waits a minute" "$status;$(sleeps)" "0;1 60 1"

fixture POST/repos/o/new/dispatches 429
out=$(run env SOURCE=o/done "$root/notify/notify.sh") && status=0 || status=$?
check "a persistent rate limit backs off, then gives up" "$status;$(sleeps)" "1;1 60 120 240 480 1"
rm "$T/api/POST:repos%o%new%dispatches"

fixture POST/repos/o/new/dispatches 403 '{"message": "Resource not accessible by personal access token"}'
out=$(run env SOURCE=o/done "$root/notify/notify.sh") && status=0 || status=$?
check "a refused dispatch is not retried, and fails the run" "$status;$(sleeps)" "1;1 1"
check "a refused dispatch reports GitHub's message" "$(grep '^could not' <<< "$out")" \
  "could not notify o/new (HTTP 403): Resource not accessible by personal access token"
rm "$T/api/POST:repos%o%new%dispatches"

fixture 'POST/graphql!' 502 '<html>502 Bad Gateway</html>'
out=$(run env SOURCE=o/done "$root/notify/notify.sh") && status=0 || status=$?
check "a search that hits a gateway error is retried" "$status;$(sleeps);$(writes)" \
  "0;5 1 1;POST repos/o/new/dispatches;POST repos/o/pending/dispatches"

fixture 'POST/repos/o/new/dispatches!' 502
out=$(run env SOURCE=o/done "$root/notify/notify.sh") && status=0 || status=$?
check "a dispatch that hits a gateway error is not retried" "$status;$(sleeps);$(writes)" \
  "1;1 1;POST repos/o/new/dispatches;POST repos/o/pending/dispatches"

fixture POST/graphql 200 '{"errors": [{"message": "boom"}]}'
out=$(run "$root/notify/notify.sh") && status=0 || status=$?
check "a failed search fails the run" "$status;$(writes)" "1;"
fixture POST/graphql 200 "$account"

fixture GET/repos/o/new/contents/.github/workflows/lean-bump.yml 500
out=$(run "$root/bootstrap.sh") && status=0 || status=$?
check "an unreadable repository fails the run" "$status" 1

(( failures == 0 )) || { echo "$failures failed"; exit 1; }
