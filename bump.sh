#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

set -euo pipefail

: "${OWNER_PATTERN:?set OWNER_PATTERN to a regex matching the git URLs of the packages to bump}"
SUMMARY_FILE=${SUMMARY_FILE:-bump-summary.md}
ALLOW_RC_TOOLCHAIN=${ALLOW_RC_TOOLCHAIN:-false}
GITHUB_OUTPUT=${GITHUB_OUTPUT:-/dev/null}
LEAN_REPO=${LEAN_REPO:-https://github.com/leanprover/lean4}

die() { echo "bump: $*" >&2; exit 1; }

[[ -f lake-manifest.json ]] || die "no lake-manifest.json in $PWD"
if [[ -f lakefile.toml ]]; then lakefile=lakefile.toml
elif [[ -f lakefile.lean ]]; then lakefile=lakefile.lean
else die "no lakefile in $PWD"; fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Release tags newer than the current one, highest first, in the same v-prefixed or bare style.
newer_tags() {
  local prefix=""
  [[ $2 == v* ]] && prefix=v
  git ls-remote --tags --refs "$1" | sed 's|.*refs/tags/||' \
    | { grep -E "^${prefix}[0-9]+\.[0-9]+\.[0-9]+$" || true; } \
    | { cat; echo "$2"; } | sort -Vr | sed "/^$2$/,\$d"
}

toolchain_at() {
  local dir="$work/tc-$RANDOM"
  git init -q "$dir"
  git -C "$dir" fetch -q --depth 1 "$1" "refs/tags/$2"
  git -C "$dir" show "FETCH_HEAD:${3:+$3/}lean-toolchain" 2>/dev/null || true
}

# The latest stable Lean release, if it is newer than the root's toolchain. A toolchain that
# is not a leanprover/lean4 release, such as a nightly, is left alone.
newer_toolchain() {
  local cur base rc latest
  cur=$(cat lean-toolchain 2>/dev/null || true)
  [[ $cur =~ ^leanprover/lean4:(v[0-9]+\.[0-9]+\.[0-9]+)(-rc[0-9]+)?$ ]] || return 0
  base=${BASH_REMATCH[1]} rc=${BASH_REMATCH[2]}
  latest=$(git ls-remote --tags --refs "$LEAN_REPO" | sed 's|.*refs/tags/||' \
    | { grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true; } | sort -V | tail -n 1)
  [[ -n $latest ]] || return 0
  if [[ $latest == "$base" ]]; then [[ -n $rc ]] || return 0
  elif [[ $(printf '%s\n' "$base" "$latest" | sort -V | tail -n 1) != "$latest" ]]; then return 0; fi
  echo "leanprover/lean4:$latest"
}

set_rev_toml() {
  awk -v n="$1" -v r="$2" '
    /^\[/ { start = NR; inreq = ($0 ~ /^\[\[require\]\][[:space:]]*$/) }
    inreq && $0 ~ /^[[:space:]]*name[[:space:]]*=/ {
      v = $0; sub(/^[^"]*"/, "", v); sub(/".*/, "", v)
      if (v == n) target = start
    }
    { line[NR] = $0; block[NR] = start }
    END {
      for (i = 1; i <= NR; i++) {
        if (target && block[i] == target && line[i] ~ /^[[:space:]]*rev[[:space:]]*=/) {
          match(line[i], /^[[:space:]]*/)
          line[i] = substr(line[i], 1, RLENGTH) "rev = \"" r "\""
          done = 1
        }
        print line[i]
      }
      exit !done
    }' "$lakefile" > "$work/lakefile" || die "no rev for require '$1' in $lakefile"
  mv "$work/lakefile" "$lakefile"
}

set_rev_lean() {
  N=$1 R=$2 perl -CSD -Mutf8 -0777 -ne '
    my $n = qr/(?:«\Q$ENV{N}\E»|"\Q$ENV{N}\E"|\Q$ENV{N}\E)/;
    s/(require\s+(?:"[^"]*"\s*\/\s*)?$n\s+from\s+git\s+"[^"]*"\s*@\s*")[^"]*(")/$1$ENV{R}$2/
      or exit 3;
    print' "$lakefile" > "$work/lakefile" || die "no 'require $1 from git ... @ \"rev\"' in $lakefile"
  mv "$work/lakefile" "$lakefile"
}

declare -A requested=()
skipped=()
while IFS=$'\t' read -r name url rev inputRev subDir; do
  [[ $url =~ $OWNER_PATTERN ]] || continue
  if [[ $inputRev =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    latest=""
    for tag in $(newer_tags "$url" "$inputRev"); do
      if [[ $ALLOW_RC_TOOLCHAIN != true ]]; then
        tc=$(toolchain_at "$url" "$tag" "$subDir")
        if [[ $tc == *-rc* ]]; then
          skipped+=("\`$name\` $tag, which uses \`$tc\`")
          continue
        fi
      fi
      latest=$tag
      break
    done
    [[ -n $latest ]] || continue
    if [[ $lakefile == lakefile.toml ]]; then set_rev_toml "$name" "$latest"
    else set_rev_lean "$name" "$latest"; fi
    requested[$name]=$latest
  else
    head=$(git ls-remote "$url" "refs/heads/$inputRev" | cut -f1)
    [[ -n $head && $head != "$rev" ]] && requested[$name]=$inputRev
  fi
done < <(jq -r '.packages[] | select(.type == "git" and .inherited == false)
                | [(.name | ltrimstr("«") | rtrimstr("»")), .url, .rev, .inputRev, (.subDir // "")] | @tsv' lake-manifest.json)

toolchain_before=$(cat lean-toolchain 2>/dev/null || true)
toolchain_target=$(newer_toolchain)

if (( ${#requested[@]} == 0 )) && [[ -z $toolchain_target ]]; then
  echo "changed=false" >> "$GITHUB_OUTPUT"
  echo "bump: nothing to update"
  (( ${#skipped[@]} )) && printf 'bump: skipped %s\n' "${skipped[@]}"
  exit 0
fi

cp lake-manifest.json "$work/before.json"
# Set before lake update, so it runs on the new toolchain and moves it again only if a dependency needs newer.
if [[ -n $toolchain_target ]]; then echo "$toolchain_target" > lean-toolchain; fi
if (( ${#requested[@]} )); then
  # Not --keep-toolchain: in that mode a dependency's manifest can override the root's own pins.
  lake update "${!requested[@]}"
fi

req_json=$(for n in "${!requested[@]}"; do printf '%s\t%s\n' "$n" "${requested[$n]}"; done \
  | jq -Rn '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries')

{
  echo "Updated by [lean-bump](https://github.com/paulbutcher/lean-bump)."
  if (( ${#requested[@]} )); then
    echo
    echo "### Requested"
    echo
    jq -rn --slurpfile a "$work/before.json" --slurpfile b lake-manifest.json --argjson req "$req_json" '
      def unq: map(.name |= (ltrimstr("«") | rtrimstr("»")));
      (($a[0].packages | unq) | map({key: .name, value: .}) | from_entries) as $old
      | $b[0].packages | unq | .[] | select($req[.name] != null)
      | $old[.name] as $o
      | "- `\(.name)`: "
        + (if $o.inputRev == .inputRev then "\(.inputRev) `\($o.rev[0:7])` → `\(.rev[0:7])`"
           else "\($o.inputRev) → \(.inputRev)" end)
        + (if .inputRev != $req[.name] then " **(requested \($req[.name]))**" else "" end)
        + (if .inherited then " **(now inherited)**" else "" end)
        + (if .type != $o.type then " **(now a \(.type) require)**" else "" end)'
  fi

  others=$(jq -rn --slurpfile a "$work/before.json" --slurpfile b lake-manifest.json --argjson req "$req_json" '
    def unq: map(.name |= (ltrimstr("«") | rtrimstr("»")));
    (($a[0].packages | unq) | map({key: .name, value: .}) | from_entries) as $old
    | (($b[0].packages | unq) | map({key: .name, value: .}) | from_entries) as $new
    | ($old + $new | keys[]) as $n | select($req[$n] == null)
    | $old[$n] as $o | $new[$n] as $p
    | select($o == null or $p == null or $o.rev != $p.rev or $o.inherited != $p.inherited or $o.type != $p.type)
    | "- `\($n)`: "
      + (if $o == null then "added at \($p.inputRev)"
         elif $p == null then "removed"
         else "\($o.inputRev) (`\($o.rev[0:7])`) → \($p.inputRev) (`\($p.rev[0:7])`)"
           + (if ($o.inherited | not) and $p.inherited then ", **root require became inherited**" else "" end)
         end)')
  if [[ -n $others ]]; then
    echo
    echo "### Also changed"
    echo
    echo "Not requested; these came from dependency manifests. Check for downgrades."
    echo
    echo "$others"
  fi

  toolchain_after=$(cat lean-toolchain 2>/dev/null || true)
  if [[ $toolchain_after != "$toolchain_before" ]]; then
    echo
    echo "### Toolchain"
    echo
    echo "\`$toolchain_before\` → \`$toolchain_after\`"
  fi

  if (( ${#skipped[@]} )); then
    echo
    echo "### Skipped"
    echo
    printf -- '- %s\n' "${skipped[@]}"
  fi
} > "$SUMMARY_FILE"

{
  echo "changed=true"
  echo "bumped=$( { (( ${#requested[@]} == 0 )) || printf '%s\n' "${!requested[@]}" | LC_ALL=C sort
                   [[ $toolchain_after == "$toolchain_before" ]] || echo lean-toolchain; } | paste -sd' ')"
} >> "$GITHUB_OUTPUT"
cat "$SUMMARY_FILE"
