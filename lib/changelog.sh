# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# changelog_version FILE: prints the version of the newest entry in changelog FILE, or nothing if
# it has none. An entry's heading is `## [x.y.z]` or `## x.y.z`, either optionally followed by a
# space and more, such as the date.
changelog_version() {
  sed -nE -e 's/^## \[([0-9]+\.[0-9]+\.[0-9]+)\]( .*)?$/\1/p' \
          -e 's/^## ([0-9]+\.[0-9]+\.[0-9]+)( .*)?$/\1/p' "$1" | head -n1
}
