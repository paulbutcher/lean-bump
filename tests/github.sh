#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Runs notify, bootstrap, protect, clear-label and resolve's guard against a fake curl serving a
# fixed account, and checks how a changelog's version is read:
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
for r in done new; do fixture "GET/repos/o/$r/pulls?head=o:lean-bump-install&state=open" 200 '[]'; done
fixture 'GET/repos/o/pending/pulls?head=o:lean-bump-install&state=open' 200 '[{"number": 1}]'
fixture GET/repos/o/new 200 '{"default_branch": "main"}'
fixture GET/repos/o/new/git/ref/heads/main 200 '{"object": {"sha": "abc123"}}'
# manifest URL INHERITED: a Lake manifest with one git package.
manifest() { jq -cn --arg u "$1" --argjson i "$2" '{version: "1.1.0", packages: [{type: "git", url: $u, inherited: $i}]}'; }
# files REPO PATH=MANIFEST...: REPO's default branch holds a README and those manifests.
files() {
  local repo=$1 tree='[{"path": "README.md", "type": "blob", "sha": "readme"}]' i=0 m; shift
  for m in "$@"; do
    i=$((i + 1))
    tree=$(jq -c --arg p "${m%%=*}" --arg s "m$i" '. + [{path: $p, type: "blob", sha: $s}]' <<< "$tree")
    fixture "GET/repos/$repo/git/blobs/m$i" 200 "$(jq -cn --arg c "$(printf '%s' "${m#*=}" | base64)" '{content: $c}')"
  done
  fixture "GET/repos/$repo/git/trees/HEAD?recursive=1" 200 "$(jq -cn --argjson t "$tree" '{tree: $t, truncated: false}')"
}
# o/new requires o/done from its root project, o/pending only from a test project.
files o/new "lake-manifest.json=$(manifest https://github.com/o/done.git false)"
files o/pending "lake-manifest.json=$(manifest https://github.com/o/new true)" \
  "test/lake-manifest.json=$(manifest https://github.com/O/Done false)"

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
check "notify finds Lake packages with a single search" "$(grep -c '^POST graphql' "$T/api/requests")" 1
check "notify spaces dispatches a second apart" "$(sleeps)" "1 1"

files o/pending "lake-manifest.json=$(manifest https://github.com/o/done true)" \
  ".lake/packages/x/lake-manifest.json=$(manifest https://github.com/o/done false)" \
  "test/lake-manifest.json=$(manifest https://github.com/o/done-extra false)"
out=$(run env SOURCE=o/done "$root/notify/notify.sh")
check "notify skips a package that requires the release only indirectly, or not at all" "$(writes);$(grep '^skipping' <<< "$out")" \
  "POST repos/o/new/dispatches;skipping o/pending: nothing in it requires o/done"
fixture GET/repos/o/new/git/trees/HEAD?recursive=1 404 '{"message": "Not Found"}'
fixture GET/repos/o/pending/git/blobs/m3 200 '{"content": "bm90IGpzb24="}'
out=$(run env SOURCE=o/done "$root/notify/notify.sh")
check "notify notifies a package it cannot read" "$(writes);$(grep 'anyway' <<< "$out")" \
  $'POST repos/o/new/dispatches;POST repos/o/pending/dispatches;could not list o/new\'s files (HTTP 404): notifying it anyway\ncould not parse o/pending\'s test/lake-manifest.json: notifying it anyway'
files o/new "lake-manifest.json=$(manifest https://github.com/o/done.git false)"
files o/pending "lake-manifest.json=$(manifest https://github.com/o/new true)" \
  "test/lake-manifest.json=$(manifest https://github.com/O/Done false)"

out=$(run env DRY_RUN=true "$root/bootstrap.sh")
check "a bootstrap dry run writes nothing" "$(writes)" ""
check "a bootstrap dry run reports the plan" "$out" \
  $'would notify o/done\nwould open install PR for o/new: lean-bump.yml lean-bump-resolve.yml\ninstall PR pending for o/pending'
out=$(run env DRY_RUN=true REPOS='new, o/PENDING' "$root/bootstrap.sh")
check "bootstrap limited to named repositories leaves the others alone" "$out" \
  $'would open install PR for o/new: lean-bump.yml lean-bump-resolve.yml\ninstall PR pending for o/pending'
out=$(run env DRY_RUN=true REPOS='new other' "$root/bootstrap.sh") && status=0 || status=$?
check "bootstrap refuses a name that is not a Lake package" "$status;$out" \
  "1;bootstrap.sh: o/other is not a Lake package in o"

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
# Left behind by an earlier install PR, merged without deleting it.
fixture GET/repos/o/done/git/ref/heads/lean-bump-install 200
fixture DELETE/repos/o/done/git/refs/heads/lean-bump-install 204
out=$(run "$root/bootstrap.sh")
check "bootstrap replaces an install branch left behind by a merged PR" "$(grep -c "^install PR pending for o/done" <<< "$out")" 0
check "bootstrap updates outdated workflows and adds missing ones, notify included" \
  "$(writes | tr ';' '\n' | grep o/done | paste -sd';')" \
  "POST repos/o/done/dispatches;DELETE repos/o/done/git/refs/heads/lean-bump-install;POST repos/o/done/git/refs;PUT repos/o/done/contents/.github/workflows/lean-bump.yml;PUT repos/o/done/contents/.github/workflows/lean-bump-resolve.yml;PUT repos/o/done/contents/.github/workflows/lean_bump_notify.yml;POST repos/o/done/pulls"
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

fixture POST/graphql 200 "$(search "[$(repo o/done true), $(repo o/new true)]")"
fixture 'GET/repos/o/done/actions/workflows?per_page=100' 200 \
  '{"workflows": [{"id": 8, "name": "Bump dependencies"}, {"id": 7, "name": "Lean Action CI"}]}'
fixture 'GET/repos/o/done/actions/workflows/7/runs?branch=main&status=success&per_page=1' 200 '{"workflow_runs": [{"id": 99}]}'
fixture 'GET/repos/o/done/actions/runs/99/jobs?per_page=100' 200 \
  '{"jobs": [{"name": "build", "conclusion": "success"}, {"name": "docs", "conclusion": "skipped"}]}'
fixture GET/repos/o/done/rulesets 200 '[{"id": 2, "name": "other"}]'
fixture 'GET/repos/o/new/actions/workflows?per_page=100' 200 '{"workflows": []}'
out=$(run env DRY_RUN=true "$root/protect.sh")
check "a protect dry run writes nothing" "$(writes)" ""
check "a protect dry run reports the plan" "$out" \
  $'would create ruleset in o/done requiring: build\nskipping o/new: no Lean Action CI workflow'

out=$(run "$root/protect.sh")
check "protect creates a ruleset where there is none" "$(writes)" "POST repos/o/done/rulesets"
check "the ruleset requires the CI run's passing jobs from GitHub Actions, and admins may bypass it" \
  "$(grep '^POST repos/o/done/rulesets' "$T/api/requests" | cut -d' ' -f3- |
     jq -c '[.conditions.ref_name.include, .bypass_actors, .rules[0].parameters.required_status_checks]')" \
  '[["~DEFAULT_BRANCH"],[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],[{"context":"build","integration_id":15368}]]'

fixture GET/repos/o/done/rulesets 200 '[{"id": 2, "name": "other"}, {"id": 3, "name": "lean-bump"}]'
fixture PUT/repos/o/done/rulesets/3 200
out=$(run "$root/protect.sh")
check "protect updates its own ruleset in place" "$(writes)" "PUT repos/o/done/rulesets/3"

fixture 'GET/repos/o/done/actions/workflows/7/runs?branch=main&status=success&per_page=1' 200 '{"workflow_runs": []}'
out=$(run "$root/protect.sh") && status=0 || status=$?
check "protect skips a package whose CI has never passed" "$status;$(writes);$out" \
  $'0;;skipping o/done: Lean Action CI has never passed on main\nskipping o/new: no Lean Action CI workflow'
fixture POST/graphql 200 "$account"

label_path='DELETE/repos/o/done/issues/5/labels/lean-bump%3A%20needs%20decision'
fixture "$label_path" 200 '[]'
out=$(run env REPO=o/done PR=5 GITHUB_TOKEN=t "$root/clear-label.sh") && status=0 || status=$?
check "clear-label removes the label by its encoded name" "$status;$(writes);$out" \
  '0;DELETE repos/o/done/issues/5/labels/lean-bump%3A%20needs%20decision;bump: removed `lean-bump: needs decision` from #5'
fixture "$label_path" 404 '{"message": "Label does not exist"}'
out=$(run env REPO=o/done PR=5 GITHUB_TOKEN=t "$root/clear-label.sh") && status=0 || status=$?
check "clear-label is quiet when the PR has no label" "$status;$out" "0;"
fixture "$label_path" 403 '{"message": "Resource not accessible by integration"}'
out=$(run env REPO=o/done PR=5 GITHUB_TOKEN=t "$root/clear-label.sh") && status=0 || status=$?
check "clear-label only warns when it cannot remove the label" "$status;$out" \
  '0;::warning::could not remove `lean-bump: needs decision` from #5 (HTTP 403): Resource not accessible by integration'

fixture GET/rate_limit 200 \
  '{"resources": {"core": {"limit": 5000, "remaining": 1000, "reset": 0}, "graphql": {"limit": 5000, "remaining": 4999, "reset": 3600}}}'
out=$(run env REPO=o/done PR=5 GITHUB_TOKEN=t "$root/clear-label.sh") && status=0 || status=$?
check "a script on the App's token reports its rate limit as it exits, and warns when it runs low" "$status;$(tail -n2 <<< "$out")" \
  $'0;rate limit: core 1000/5000 until 1970-01-01T00:00:00Z, graphql 4999/5000 until 1970-01-01T01:00:00Z\n::warning::GitHub rate limit: core has 1000 of 5000 requests left until 1970-01-01T00:00:00Z'
fixture GET/repos/o/new/contents/.github/workflows/lean-bump.yml 500
out=$(run "$root/bootstrap.sh") && status=0 || status=$?
check "the rate limit report keeps a failed run's status" "$status;$(grep -c '^rate limit' <<< "$out")" "1;1"
installed o/new lean-bump.yml
rm "$T/api/GET:rate_limit"

mkdir -p "$T/ctx"
fixture 'GET/repos/o/done/pulls?head=o:lean-bump&state=open' 200 \
  '[{"number": 5, "base": {"ref": "main"}, "head": {"sha": "abc"}, "user": {"login": "o", "type": "User"}, "labels": [], "body": ""}]'
fixture 'GET/repos/o/done/commits/abc/check-runs?per_page=100' 200 '{"check_runs": [{"status": "in_progress"}]}'
# guard CONCLUSION MARKER...: runs guard on a CI run that concluded CONCLUSION at abc, with a comment per MARKER.
guard() {
  local c=$1; shift
  fixture 'GET/repos/o/done/issues/5/comments?per_page=100' 200 \
    "$(printf '%s\n' "$@" | jq -Rsc 'split("\n")[:-1] | map({body: "Done.\n\n\(.)"})')"
  : > "$T/guard.out"
  run env REPO=o/done RUN_ID=1 HEAD_SHA=abc HEAD_REPO=o/done HEAD_BRANCH=lean-bump CONCLUSION="$c" \
    CONTEXT_DIR="$T/ctx" GITHUB_OUTPUT="$T/guard.out" "$root/resolve/guard.sh" | grep '^resolve:'
}
check "guard skips the second CI run of a commit it handled" \
  "$(guard success '<!-- lean-bump-resolve abc success -->')" "resolve: PR #5 was already handled at abc after CI's success"
check "guard marks its comments with the commit and CI's conclusion" \
  "$(grep '^marker=' "$T/guard.out")" "marker=<!-- lean-bump-resolve abc success -->"
check "guard acts when CI passes on a rerun of a commit it handled as a failure" \
  "$(guard success '<!-- lean-bump-resolve abc failure -->')" "resolve: checks on abc are still running"
check "guard counts a marker without a conclusion as a failure's" \
  "$(guard success '<!-- lean-bump-resolve abc -->');$(guard failure '<!-- lean-bump-resolve abc -->')" \
  "resolve: checks on abc are still running;resolve: PR #5 was already handled at abc after CI's failure"
check "guard ignores markers for other commits" \
  "$(guard success '<!-- lean-bump-resolve abcd success -->' '<!-- lean-bump-resolve ab success -->')" \
  "resolve: checks on abc are still running"

source "$root/lib/changelog.sh"
changelog() { printf '# Changelog\n\n%s\n' "$@" > "$T/CHANGELOG.md"; changelog_version "$T/CHANGELOG.md"; }
check "a changelog version is read from a bracketed heading with a date" \
  "$(changelog '## [0.3.0] - 2026-11-23' '- x' '## [0.2.0] - 2026-10-01')" 0.3.0
check "a changelog version is read from a bare heading" "$(changelog '## 0.3.0' '- x' '## 0.2.2')" 0.3.0
check "a changelog version skips headings that are not a release" \
  "$(changelog '## Unreleased' '## [1.0.0-rc1]' '## 1.0.0rc' '## v0.9.0' '## [0.3.0]x' '## 0.2.2 - 2026-10-01')" 0.2.2
check "a changelog with no versioned entry has no version" "$(changelog '## Unreleased')" ""

(( failures == 0 )) || { echo "$failures failed"; exit 1; }
