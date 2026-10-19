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

top=$PWD
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

# The latest stable Lean release, if it is newer than the project's toolchain. A toolchain that
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
    }' "$lakefile" > "$work/lakefile" || die "no rev for require '$1' in $where$lakefile"
  mv "$work/lakefile" "$lakefile"
}

set_rev_lean() {
  N=$1 R=$2 perl -CSD -Mutf8 -0777 -ne '
    my $n = qr/(?:«\Q$ENV{N}\E»|"\Q$ENV{N}\E"|\Q$ENV{N}\E)/;
    s/(require\s+(?:"[^"]*"\s*\/\s*)?$n\s+from\s+git\s+"[^"]*"\s*@\s*")[^"]*(")/$1$ENV{R}$2/
      or exit 3;
    print' "$lakefile" > "$work/lakefile" || die "no 'require $1 from git ... @ \"rev\"' in $where$lakefile"
  mv "$work/lakefile" "$lakefile"
}

# Every Lake project in the tree, such as a root package with test or example packages beside it.
mapfile -t found < <(find . \( -name .lake -o -name .git \) -prune -o -name lake-manifest.json -print \
  | sed 's|/lake-manifest.json$||; s|^\./||' | LC_ALL=C sort)
(( ${#found[@]} )) || die "no lake-manifest.json in $PWD"

# Ordered so that each project comes after the projects in the tree that it requires by path,
# whose updated manifests it then follows.
declare -A path_deps=()
for p in "${found[@]}"; do
  path_deps[$p]=$(cd "$p" && jq -r '.packages[] | select(.type == "path" and .inherited == false) | .dir' \
    lake-manifest.json | while IFS= read -r d; do realpath -m --relative-to="$top" "$d"; done)
done
projects=()
declare -A placed=()
while (( ${#projects[@]} < ${#found[@]} )); do
  progress=0
  for p in "${found[@]}"; do
    [[ -z ${placed[$p]:-} ]] || continue
    ready=1
    while IFS= read -r d; do
      if [[ -n $d && -n ${path_deps[$d]+x} && -z ${placed[$d]:-} ]]; then ready=0; fi
    done <<< "${path_deps[$p]}"
    if (( ready )); then projects+=("$p"); placed[$p]=1; progress=1; fi
  done
  (( progress )) || die "projects require each other by path: ${found[*]}"
done

# name -> rev for each git package a project's update moved, so that a project
# requiring that one by path moves it too, even though only the dependency's lakefile names it.
declare -A moved=()
bumped=()
summaries=()
skipped_all=()
toolchain_changed=false

bump_project() {
  local p=$1 name url rev inputRev subDir latest tag tc head s toolchain_before toolchain_target toolchain_after
  local -A requested=() followed=()
  local skipped=()
  cd "$top/$p"
  if [[ $p == . ]]; then where=""; else where=$p/; fi
  if [[ -f lakefile.toml ]]; then lakefile=lakefile.toml
  elif [[ -f lakefile.lean ]]; then lakefile=lakefile.lean
  else die "no lakefile in $PWD"; fi

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
      if [[ -n $head && $head != "$rev" ]]; then requested[$name]=$inputRev; fi
    fi
  done < <(jq -r '.packages[] | select(.type == "git" and .inherited == false)
                  | [(.name | ltrimstr("«") | rtrimstr("»")), .url, .rev, .inputRev, (.subDir // "")] | @tsv' lake-manifest.json)

  # Packages an earlier project moved, which this one has at another rev. They are named to lake
  # update but are not requests of this project's own, so the summary lists them as also changed.
  while IFS=$'\t' read -r name rev; do
    if [[ -z ${requested[$name]:-} && -n ${moved[$name]:-} && ${moved[$name]} != "$rev" ]]; then
      followed[$name]=1
    fi
  done < <(jq -r '.packages[] | select(.type == "git") | [(.name | ltrimstr("«") | rtrimstr("»")), .rev] | @tsv' \
             lake-manifest.json)

  toolchain_before=$(cat lean-toolchain 2>/dev/null || true)
  toolchain_target=$(newer_toolchain)
  for s in "${skipped[@]}"; do skipped_all+=("$s${where:+ (in $where)}"); done
  if (( ${#requested[@]} + ${#followed[@]} == 0 )) && [[ -z $toolchain_target ]]; then return 0; fi

  cp lake-manifest.json "$work/before.json"
  # Set before lake update, so it runs on the new toolchain and moves it again only if a dependency needs newer.
  if [[ -n $toolchain_target ]]; then echo "$toolchain_target" > lean-toolchain; fi
  if (( ${#requested[@]} + ${#followed[@]} )); then
    # Not --keep-toolchain: in that mode a dependency's manifest can override the root's own pins.
    lake update "${!requested[@]}" "${!followed[@]}"
  fi

  while IFS=$'\t' read -r name rev; do moved[$name]=$rev; done < <(
    jq -rn --slurpfile a "$work/before.json" --slurpfile b lake-manifest.json '
      def unq: map(.name |= (ltrimstr("«") | rtrimstr("»")));
      (($a[0].packages | unq) | map({key: .name, value: .rev}) | from_entries) as $old
      | $b[0].packages | unq | .[] | select(.type == "git" and $old[.name] != .rev)
      | [.name, .rev] | @tsv')
  bumped+=("${!requested[@]}")

  req_json=$(for n in "${!requested[@]}"; do printf '%s\t%s\n' "$n" "${requested[$n]}"; done \
    | jq -Rn '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries')

  {
    if (( ${#projects[@]} > 1 )); then
      echo
      if [[ -n $where ]]; then echo "## \`$where\`"; else echo "## Root package"; fi
    fi
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
      toolchain_changed=true
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
  } > "$work/summary"
  summaries+=("$(cat "$work/summary")")
}

for p in "${projects[@]}"; do bump_project "$p"; done
cd "$top"
projects_json=$(printf '%s\n' "${projects[@]}" | jq -Rnc '[inputs]')

if (( ${#summaries[@]} == 0 )); then
  echo "changed=false" >> "$GITHUB_OUTPUT"
  echo "bump: nothing to update"
  (( ${#skipped_all[@]} )) && printf 'bump: skipped %s\n' "${skipped_all[@]}"
  exit 0
fi

{
  echo "Updated by [lean-bump](https://github.com/paulbutcher/lean-bump)."
  printf '%s\n' "${summaries[@]}"
} > "$SUMMARY_FILE"

{
  echo "changed=true"
  echo "bumped=$( { (( ${#bumped[@]} == 0 )) || printf '%s\n' "${bumped[@]}" | LC_ALL=C sort -u
                   [[ $toolchain_changed == false ]] || echo lean-toolchain; } | paste -sd' ')"
  echo "projects=$projects_json"
} >> "$GITHUB_OUTPUT"
cat "$SUMMARY_FILE"
