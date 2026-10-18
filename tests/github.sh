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

cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=/dev/null method=GET data=
while (( $# > 1 )); do
  case $1 in
    -o) out=$2; shift ;;
    -X) method=$2; shift ;;
    -d) data=$2; shift ;;
    -w|-H) shift ;;
  esac
  shift
done
path=${1#http://fake/}
re='[?&]page=([0-9]+)'
[[ $path =~ $re ]] && page=${BASH_REMATCH[1]} || page=
path=${path%%\?*}
echo "$method $path $data" >> "$FAKE_API/requests"
fixture=$FAKE_API/$method:${path//\//%}
[[ -n $page && -f $fixture@$page ]] && fixture=$fixture@$page
if [[ -f $fixture ]]; then code=$(head -n1 "$fixture"); tail -n +2 "$fixture" > "$out"
elif [[ $method == POST && $path == */dispatches ]]; then code=204; : > "$out"
elif [[ $method != GET ]]; then code=201; echo '{"html_url": "https://example/pr"}' > "$out"
else code=404; echo '{}' > "$out"; fi
printf '%s' "$code"
EOF
chmod +x "$T/bin/curl"

fixture() { local f=${1/\//:}; f=${f//\//%}; printf '%s\n%s\n' "$2" "${3:-{\}}" > "$T/api/$f"; }
fixture GET/search/repositories 200 \
  '{"items": [{"full_name": "o/done"}, {"full_name": "o/new"}, {"full_name": "o/pending"}, {"full_name": "o/other"}]}'
for r in done new pending; do fixture "GET/repos/o/$r/contents/lake-manifest.json" 200; done
fixture GET/repos/o/done/contents/.github/workflows/lean-bump.yml 200
fixture GET/repos/o/pending/git/ref/heads/lean-bump-install 200
fixture GET/repos/o/new 200 '{"default_branch": "main"}'
fixture GET/repos/o/new/git/ref/heads/main 200 '{"object": {"sha": "abc123"}}'

failures=0
check() {
  if [[ $2 == "$3" ]]; then echo "ok   $1"
  else printf 'FAIL %s:\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"; failures=$((failures + 1)); fi
}
run() { : > "$T/api/requests"; PATH="$T/bin:$PATH" FAKE_API=$T/api GITHUB_API_URL=http://fake OWNER=o "$@" 2>&1; }
writes() { grep -v '^GET ' "$T/api/requests" | cut -d' ' -f1,2 | paste -sd';' || true; }

out=$(run env SOURCE=o/done "$root/notify/notify.sh")
check "notify dispatches to every other Lake package" "$(writes)" \
  "POST repos/o/new/dispatches;POST repos/o/pending/dispatches"
check "notify reports each dispatch" "$(grep -c '^notified' <<< "$out")" 2

out=$(run env DRY_RUN=true "$root/bootstrap.sh")
check "a bootstrap dry run writes nothing" "$(writes)" ""
check "a bootstrap dry run reports the plan" "$out" \
  $'would notify o/done\nwould open install PR for o/new\ninstall PR pending for o/pending'

out=$(run "$root/bootstrap.sh")
check "bootstrap notifies installed packages and installs the workflow elsewhere" "$(writes)" \
  "POST repos/o/done/dispatches;POST repos/o/new/git/refs;PUT repos/o/new/contents/.github/workflows/lean-bump.yml;POST repos/o/new/pulls"
check "the install branch starts at the default branch head" \
  "$(grep '^POST repos/o/new/git/refs' "$T/api/requests" | cut -d' ' -f3- | jq -c .)" \
  '{"ref":"refs/heads/lean-bump-install","sha":"abc123"}'
check "the installed workflow is the template" \
  "$(grep '^PUT ' "$T/api/requests" | cut -d' ' -f3- | jq -r .content | base64 -d)" \
  "$(cat "$root/templates/lean-bump.yml")"

fixture GET/search/repositories@1 200 "$(jq -cn '{items: [range(100) | {full_name: "o/r\(.)"}]}')"
fixture GET/search/repositories@2 200 '{"items": [{"full_name": "o/last"}]}'
fixture GET/repos/o/last/contents/lake-manifest.json 200
out=$(run "$root/notify/notify.sh")
check "notify follows search results past the first page" "$(writes)" "POST repos/o/last/dispatches"
rm "$T"/api/*@*

fixture GET/repos/o/new/contents/lake-manifest.json 500
out=$(run "$root/bootstrap.sh") && status=0 || status=$?
check "an unreadable repository fails the run" "$status" 1

(( failures == 0 )) || { echo "$failures failed"; exit 1; }
