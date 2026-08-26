#!/usr/bin/env sh
#
# Print the version this checkout releases as: the upstream GDAL version, plus
# the Unix timestamp of the current commit as a build revision.
#
# The timestamp comes from the commit rather than from the clock for two
# reasons. The three platform jobs finish up to twenty minutes apart, so a
# build-time clock would stamp three different versions onto one release and
# none of them would resolve. And deriving it from the commit keeps a tag
# reproducible: re-running it yields the same version, where a hand-written
# revision could be set wrong or forgotten.
#
# Ordering works out because the upstream components come first: a 3.13.3 built
# from an older commit still sorts above a later 3.13.2 rebuild.
set -eu

here="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
. "$here/versions.env"

ts="$(git -C "$here" log -1 --format=%ct 2>/dev/null || true)"
if [ -z "$ts" ]; then
  echo "dist-version.sh: no commit timestamp available (not a git checkout?)" >&2
  exit 1
fi

printf '%s.%s\n' "$GDAL_VERSION" "$ts"
