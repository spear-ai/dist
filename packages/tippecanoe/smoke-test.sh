#!/usr/bin/env bash
#
# Verify a built tree is actually self-contained and functional.
# Runs against $1 (default ./work/out). Exits non-zero on any failure.
#
#   ./smoke-test.sh
#   ./smoke-test.sh /path/to/tree
#
# Every check captures output into a variable and matches it with `case`.
# Never `cmd | grep -q` here: grep -q exits on the first match, the producer
# takes SIGPIPE, and `pipefail` then reports the pipeline as failed even though
# the match succeeded -- so the check passes on one platform and fails on
# another depending on how much output arrived before grep gave up. That cost
# three CI cycles on packages/gdal.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/versions.env"

TREE="${1:-$ROOT/work/out}"
if [ ! -d "$TREE" ]; then
  echo "no build tree at $TREE - run ./build.sh first" >&2; exit 1
fi
TREE="$(cd "$TREE" && pwd)"

BINS="tippecanoe tippecanoe-enumerate tippecanoe-decode tippecanoe-json-tool tile-join tippecanoe-overzoom"

fails=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fails=$((fails+1)); }
sect() { printf '\n\033[1m%s\033[0m\n' "$*"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Deliberately hostile: no library-path overrides and PATH reduced to the
# platform's own. tippecanoe needs no environment at all -- no resource files,
# no data directory, nothing to point an env var at -- and this is what asserts
# that, so the mise config needs no [env] block the way gdal's does.
run() { env -u DYLD_LIBRARY_PATH -u LD_LIBRARY_PATH PATH=/usr/bin:/bin "$@"; }

# ------------------------------------------------------------------ version --
# `tippecanoe --version` writes to *stderr* and exits 0, so a check that
# captures stdout alone gets an empty string and fails for the wrong reason.
# Matched exactly rather than as a substring: BUILD_INFO, if the build ever set
# it, is appended to this string, and that should be caught rather than ignored.
sect "version"
want="tippecanoe v$TIPPECANOE_VERSION"
got="$(run "$TREE/bin/tippecanoe" --version 2>&1)"
case "$got" in
  "$want") pass "$got" ;;
  *)
    fail "expected '$want', got: ${got:-<nothing>}"
    echo "       (binaries do not run as expected; later checks may cascade)"
    ;;
esac

# ------------------------------------------------------------------- layout --
sect "layout"
missing=""
for b in $BINS; do
  [ -x "$TREE/bin/$b" ] || missing="$missing $b"
done
[ -z "$missing" ] && pass "all six binaries present and executable" \
                  || fail "missing or not executable:$missing"

extra="$(ls "$TREE/bin" 2>/dev/null | while read -r f; do
           case " $BINS " in *" $f "*) ;; *) echo "$f" ;; esac
         done)"
[ -z "$extra" ] && pass "bin/ ships nothing else" \
               || fail "unexpected files in bin/: $(echo "$extra" | tr '\n' ' ')"

# The design claim: six standalone executables, so there is no shared library
# to relocate and no rpath to get right. A lib/ appearing here means something
# started shipping a library and the claim needs revisiting.
if [ ! -d "$TREE/lib" ] && [ ! -d "$TREE/lib64" ]; then
  pass "no lib/ or lib64/ - nothing to relocate"
else
  fail "a library directory appeared; this package is meant to be binaries only"
fi

[ -f "$TREE/share/man/man1/tippecanoe.1" ] \
  && pass "man page ships" \
  || fail "share/man/man1/tippecanoe.1 missing"

# ------------------------------------------------------------- tiling round --
# .mbtiles is a SQLite database holding gzipped vector tiles, so a write-then-
# read round trip exercises both statically linked dependencies in both
# directions. If either failed to link, this is where it shows.
sect "tiling (SQLite + zlib round trip)"
cat > "$tmp/a.geojson" <<'GEOJSON'
{"type":"FeatureCollection","features":[
{"type":"Feature","properties":{"name":"alpha"},"geometry":{"type":"Point","coordinates":[-122.4,37.8]}},
{"type":"Feature","properties":{"name":"area"},"geometry":{"type":"Polygon","coordinates":[[[-122.5,37.7],[-122.5,37.9],[-122.2,37.9],[-122.2,37.7],[-122.5,37.7]]]}}
]}
GEOJSON
cat > "$tmp/b.geojson" <<'GEOJSON'
{"type":"FeatureCollection","features":[
{"type":"Feature","properties":{"name":"beta"},"geometry":{"type":"Point","coordinates":[-122.3,37.7]}}
]}
GEOJSON

out="$(run "$TREE/bin/tippecanoe" -q -f -o "$tmp/a.mbtiles" -Z0 -z5 -l la "$tmp/a.geojson" 2>&1)"
if [ -s "$tmp/a.mbtiles" ]; then
  pass "tippecanoe wrote an .mbtiles"
else
  fail "tippecanoe produced no .mbtiles: ${out:-<no output>}"
fi

# Decoding reads the SQLite tables and inflates each tile, so a feature that
# survives the trip proves the whole chain rather than just the file existing.
decoded="$(run "$TREE/bin/tippecanoe-decode" -x generator "$tmp/a.mbtiles" 2>&1)"
case "$decoded" in
  *'"name": "alpha"'*) pass "tippecanoe-decode reads the features back out" ;;
  *) fail "decode lost the features: $(printf '%s' "$decoded" | tail -1)" ;;
esac

enum="$(run "$TREE/bin/tippecanoe-enumerate" "$tmp/a.mbtiles" 2>&1)"
case "$enum" in
  *"a.mbtiles 0 0 0"*) pass "tippecanoe-enumerate lists tiles" ;;
  *) fail "enumerate returned: ${enum:-<nothing>}" ;;
esac

out="$(run "$TREE/bin/tippecanoe" -q -f -o "$tmp/a.pmtiles" -Z0 -z2 -l la "$tmp/a.geojson" 2>&1)"
[ -s "$tmp/a.pmtiles" ] && pass "tippecanoe writes .pmtiles" \
                        || fail "no .pmtiles produced: ${out:-<no output>}"

# ---------------------------------------------------------------- tile-join --
# The nautical pipeline merges per-layer tilesets with this, so it is not
# optional coverage.
sect "tile-join"
run "$TREE/bin/tippecanoe" -q -f -o "$tmp/b.mbtiles" -Z0 -z5 -l lb "$tmp/b.geojson" >/dev/null 2>&1
out="$(run "$TREE/bin/tile-join" -q -f -o "$tmp/j.mbtiles" "$tmp/a.mbtiles" "$tmp/b.mbtiles" 2>&1)"
if [ -s "$tmp/j.mbtiles" ]; then
  joined="$(run "$TREE/bin/tippecanoe-decode" -x generator "$tmp/j.mbtiles" 2>&1)"
  a=no; b=no
  case "$joined" in *'"name": "alpha"'*) a=yes ;; esac
  case "$joined" in *'"name": "beta"'*)  b=yes ;; esac
  if [ "$a$b" = yesyes ]; then
    pass "tile-join merged both layers and both survive a decode"
  else
    fail "join dropped features (alpha=$a beta=$b)"
  fi
else
  fail "tile-join produced nothing: ${out:-<no output>}"
fi

# --------------------------------------------------------- directory tiles ---
# Loose z/x/y.pbf tiles are gzip members on disk rather than SQLite blobs, so
# this exercises zlib without SQLite in the path, and gives overzoom an input.
sect "directory tiles and overzoom"
run "$TREE/bin/tippecanoe" -q -f -e "$tmp/tiles" -Z0 -z1 -l la "$tmp/a.geojson" >/dev/null 2>&1
if [ -f "$tmp/tiles/0/0/0.pbf" ]; then
  pass "tippecanoe writes a z/x/y tile directory"
else
  fail "no tile directory written"
fi
out="$(run "$TREE/bin/tippecanoe-overzoom" -o "$tmp/oz.pbf.gz" \
           "$tmp/tiles/0/0/0.pbf" 0/0/0 1/0/0 2>&1)"
if [ -s "$tmp/oz.pbf.gz" ]; then
  oz="$(run "$TREE/bin/tippecanoe-decode" -z1 "$tmp/oz.pbf.gz" 1 0 0 2>&1)"
  case "$oz" in
    *'"name": "alpha"'*) pass "tippecanoe-overzoom re-tiles a gzipped tile" ;;
    *) fail "overzoomed tile decodes wrong: $(printf '%s' "$oz" | tail -1)" ;;
  esac
else
  fail "overzoom produced nothing: ${out:-<no output>}"
fi

jt="$(run "$TREE/bin/tippecanoe-json-tool" -w "$tmp/a.geojson" 2>&1)"
case "$jt" in
  *'"name":"alpha"'*) pass "tippecanoe-json-tool streams features" ;;
  *) fail "json-tool returned: $(printf '%s' "$jt" | tail -1)" ;;
esac

# -------------------------------------------------------- self-containment ---
sect "self-containment"
if [ "$(uname -s)" = Darwin ]; then
  # No @rpath or @loader_path here: these are executables with no shared
  # library of their own to find.
  allow='^(/usr/lib/|/System/)'
else
  # DT_NEEDED entries are what the loader will actually demand. libstdc++ is
  # deliberately *not* allowed: this package links the C++ runtime statically
  # (see build.sh), so its appearance means -static-libstdc++ stopped applying.
  allow='^(libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|libgcc_s\.so|ld-linux)'
fi

deps_of() { # binary -> one dependency per line
  if [ "$(uname -s)" = Darwin ]; then
    otool -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}'
  else
    readelf -d "$1" 2>/dev/null | awk '/NEEDED/ {gsub(/[][]/,"",$5); print $5}'
  fi
}

foreign=0; unreadable=0
for b in $BINS; do
  libs="$(deps_of "$TREE/bin/$b")"
  if [ -z "$(printf '%s' "$libs" | tr -d '[:space:]')" ]; then
    echo "      could not read dynamic dependencies of $b (otool/readelf missing?)"
    unreadable=$((unreadable+1))
    continue
  fi
  while read -r l; do
    [ -z "$l" ] && continue
    if ! [[ $l =~ $allow ]]; then
      echo "      $b: unexpected dependency: $l"; foreign=$((foreign+1))
    fi
  done <<< "$libs"
done
[ "$unreadable" -eq 0 ] || fail "$unreadable binary/binaries could not be inspected"
[ "$foreign" -eq 0 ] && pass "all six binaries link only platform libraries" \
                     || fail "$foreign non-platform dependency/dependencies"

# Named explicitly because the allowlist above cannot catch them on macOS:
# /usr/lib/libz.1.dylib is a platform library there, so a libz that failed to
# link statically would sail through as "expected". On Linux libz.so.1 is not
# part of glibc, so the same regression is a hard portability break. One check
# for both, naming the two libraries the Makefile asks for with -lz -lsqlite3.
staticfail=0
for b in $BINS; do
  libs="$(deps_of "$TREE/bin/$b")"
  while read -r l; do
    case "$l" in
      *libz.*|*libsqlite3*)
        echo "      $b depends on $l - it was linked dynamically, not statically"
        staticfail=$((staticfail+1)) ;;
    esac
  done <<< "$libs"
done
[ "$staticfail" -eq 0 ] && pass "zlib and sqlite3 are linked in, not depended on" \
                        || fail "$staticfail dynamic zlib/sqlite3 dependency/dependencies"

# The manylinux_2_28 container exists to hold this floor. Building on a bare
# ubuntu-24.04 runner instead would raise it to glibc 2.39 and the tarball
# would stop running on Ubuntu 20.04, Debian 10 and RHEL 8 -- with nothing
# failing until a consumer tried it.
if [ "$(uname -s)" = Linux ]; then
  syms=""
  for b in $BINS; do
    syms="$syms$(readelf -sW "$TREE/bin/$b" 2>/dev/null)"$'\n'
  done
  refs="$(printf '%s\n' "$syms" | sed -n 's/.*GLIBC_\([0-9][0-9.]*\).*/\1/p' | sort -u -V)"
  worst="$(printf '%s\n' "$refs" | tail -1)"
  if [ -z "$worst" ]; then
    fail "could not read glibc symbol versions"
  elif [ "$(printf '%s\n2.28\n' "$worst" | sort -V | tail -1)" = "2.28" ]; then
    pass "highest glibc requirement is $worst (floor is 2.28)"
  else
    fail "requires glibc $worst - built outside manylinux_2_28?"
  fi
fi

leaked=0
BW="${WORK_DIR:-$ROOT/work}"
for probe in /opt/homebrew /usr/local/Cellar /home/linuxbrew \
             "$BW/deps" "$BW/src" "$BW/out"; do
  hits="$(grep -rla -- "$probe" "$TREE/bin" 2>/dev/null)"
  if [ -n "$hits" ]; then
    echo "$hits" | sed "s|^|      $probe in |"
    leaked=$((leaked+1))
  fi
done
[ "$leaked" -eq 0 ] && pass "no build-time paths embedded in output" \
                    || fail "$leaked build-time path(s) leaked"

# ------------------------------------------------------- relocatability ------
# Trivially true if nothing above embedded a path, which is exactly why it is
# worth asserting rather than assuming.
sect "relocatability"
movedbase="$(mktemp -d)"
mkdir -p "$movedbase/relocated"
moved="$(cd "$movedbase/relocated" && pwd)"
cp -R "$TREE"/* "$moved"/ 2>/dev/null
got="$(run "$moved/bin/tippecanoe" --version 2>&1)"
case "$got" in
  "$want") pass "runs from an unrelated directory" ;;
  *) fail "broken after moving: ${got:-<nothing>}" ;;
esac
out="$(run "$moved/bin/tippecanoe" -q -f -o "$movedbase/m.mbtiles" -Z0 -z2 -l la "$tmp/a.geojson" 2>&1)"
[ -s "$movedbase/m.mbtiles" ] && pass "still tiles from the moved copy" \
                              || fail "tiling failed after moving: ${out:-<no output>}"
rm -rf "$movedbase"

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf '\033[32mall checks passed\033[0m\n'; exit 0
else
  printf '\033[31m%d check(s) failed\033[0m\n' "$fails"; exit 1
fi
