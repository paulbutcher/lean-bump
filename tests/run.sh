#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

set -euo pipefail

TC=${TEST_TOOLCHAIN:-leanprover/lean4:v4.35.0}
bump=$(cd "$(dirname "$0")/.." && pwd)/bump.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
own=$T/own
mkdir -p "$own" "$T/other"

failures=0
check() {
  if [[ $2 == "$3" ]]; then echo "ok   $1"
  else echo "FAIL $1: expected '$3', got '$2'"; failures=$((failures + 1)); fi
}
g() { git -c user.name=t -c user.email=t@t "$@" >/dev/null; }
rev_of() { jq -r --arg n "$2" '.packages[] | select(.name == $n) | .inputRev' "$1/lake-manifest.json"; }

package() { # dir name [requires...]
  mkdir -p "$1"
  echo "$TC" > "$1/lean-toolchain"
  printf 'name = "%s"\n' "$2" > "$1/lakefile.toml"
  local dir=$1; shift 2
  for r in "$@"; do
    IFS=@ read -r n u v <<< "$r"
    printf '\n[[require]]\nname = "%s"\ngit = "%s"\nrev = "%s"\n' "$n" "$u" "$v" >> "$dir/lakefile.toml"
  done
  if [[ ! -d $dir/.git ]]; then git init -q -b main "$dir"; echo .lake > "$dir/.gitignore"; fi
}
release() { # dir tag
  if grep -q '^\[\[require\]\]' "$1/lakefile.toml"; then (cd "$1" && lake update >/dev/null 2>&1); fi
  g -C "$1" add -A; g -C "$1" commit -q --allow-empty -m "$2"; g -C "$1" tag "$2"
}

# Stands in for leanprover/lean4: the newest stable release is the test toolchain, so bumps that
# run lake update need no other toolchain.
export LEAN_REPO=$T/lean4
git init -q "$LEAN_REPO"
for tag in v4.0.0 "${TC#*:}" v99.0.0-rc1; do g -C "$LEAN_REPO" commit -q --allow-empty -m "$tag"; g -C "$LEAN_REPO" tag "$tag"; done

package "$own/shared" shared
release "$own/shared" v1.0.0
release "$own/shared" v1.1.0

package "$own/liba" liba "shared@$own/shared@v1.0.0"
release "$own/liba" v0.1.0
release "$own/liba" v0.2.0
package "$own/liba" liba "shared@$own/shared@v1.1.0"
release "$own/liba" v0.10.0
release "$own/liba" v0.11.0-rc1
echo "leanprover/lean4:v4.99.0-rc1" > "$own/liba/lean-toolchain"
g -C "$own/liba" commit -qam rc; g -C "$own/liba" tag v0.12.0

package "$own/libc" lib-c
release "$own/libc" start

package "$T/other/foreign" foreign
release "$T/other/foreign" v1.0.0
release "$T/other/foreign" v2.0.0

# name after rev, to check the rewrite is scoped to the block rather than to line order
package "$T/app" app "foreign@$T/other/foreign@v1.0.0" "lib-c@$own/libc@main"
printf '\n[[require]]\nrev = "v0.1.0"\ngit = "%s"\nname = "liba"\n' "$own/liba" >> "$T/app/lakefile.toml"
(cd "$T/app" && lake update >/dev/null 2>&1)
g -C "$own/libc" commit -q --allow-empty -m moved
libc_head=$(git -C "$own/libc" rev-parse HEAD)

out=$T/out
(cd "$T/app" && OWNER_PATTERN="^$own/" SUMMARY_FILE=$T/summary.md GITHUB_OUTPUT=$out "$bump" > "$T/log" 2>&1) \
  || { cat "$T/log"; exit 1; }

check "picks the highest release by version, skipping prereleases and RC toolchains" "$(rev_of "$T/app" liba)" v0.10.0
check "rewrites the lakefile rev" "$(grep -c 'rev = "v0.10.0"' "$T/app/lakefile.toml")" 1
check "leaves packages outside the owner pattern alone" "$(rev_of "$T/app" foreign)" v1.0.0
check "updates a branch-tracking require whose head moved" \
  "$(jq -r '.packages[] | select(.name == "«lib-c»") | .rev' "$T/app/lake-manifest.json")" "$libc_head"
check "reports the transitive change" "$(grep -c '`shared`: v1.0.0' "$T/summary.md")" 1
check "reports the skipped RC tag" "$(grep -c 'v0.12.0, which uses' "$T/summary.md")" 1
check "sets the outputs" "$(cat "$out")" $'changed=true\nbumped=lib-c liba'

: > "$out"
(cd "$T/app" && OWNER_PATTERN="^$own/" SUMMARY_FILE=$T/summary2.md GITHUB_OUTPUT=$out "$bump" > "$T/log" 2>&1)
check "a second run finds nothing to do" "$(cat "$out")" changed=false

mkdir "$T/leanapp"
echo "$TC" > "$T/leanapp/lean-toolchain"
cat > "$T/leanapp/lakefile.lean" <<EOF
import Lake
open Lake DSL

package leanapp

require «liba» from git
  "$own/liba" @ "v0.1.0"
EOF
(cd "$T/leanapp" && lake update >/dev/null 2>&1)
(cd "$T/leanapp" && OWNER_PATTERN="^$own/" SUMMARY_FILE=$T/summary3.md "$bump" > "$T/log" 2>&1) \
  || { cat "$T/log"; exit 1; }
check "rewrites a lakefile.lean require" "$(grep -c '@ "v0.10.0"' "$T/leanapp/lakefile.lean")" 1
check "updates the manifest for a lakefile.lean package" "$(rev_of "$T/leanapp" liba)" v0.10.0

# No requires to bump, so lake never runs and the old toolchains need not be installed.
toolchain_bump() { # starting toolchain
  rm -rf "$T/tcapp"; mkdir "$T/tcapp"
  echo "leanprover/lean4:$1" > "$T/tcapp/lean-toolchain"
  echo 'name = "tcapp"' > "$T/tcapp/lakefile.toml"
  echo '{"version": "1.1.0", "packagesDir": ".lake/packages", "packages": [], "name": "tcapp", "lakeDir": ".lake"}' \
    > "$T/tcapp/lake-manifest.json"
  : > "$out"
  (cd "$T/tcapp" && OWNER_PATTERN="^$own/" SUMMARY_FILE=$T/summary4.md GITHUB_OUTPUT=$out "$bump" > "$T/log" 2>&1) \
    || { cat "$T/log"; exit 1; }
}
toolchain_bump v4.0.0
check "bumps the toolchain to the latest stable release" "$(cat "$T/tcapp/lean-toolchain")" "$TC"
check "names the toolchain in the outputs" "$(cat "$out")" $'changed=true\nbumped=lean-toolchain'
check "reports the toolchain change" "$(grep -c "v4.0.0\` → \`$TC" "$T/summary4.md")" 1
check "omits an empty requested section" "$(grep -c Requested "$T/summary4.md")" 0
toolchain_bump "${TC#*:}-rc1"
check "bumps a release candidate to its release" "$(cat "$T/tcapp/lean-toolchain")" "$TC"
toolchain_bump v99.0.0-rc2
check "never moves the toolchain backwards" "$(cat "$T/tcapp/lean-toolchain")" leanprover/lean4:v99.0.0-rc2
check "a toolchain ahead of the latest release is nothing to do" "$(cat "$out")" changed=false

(( failures == 0 )) || { echo "$failures failed"; exit 1; }
