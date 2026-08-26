#!/usr/bin/env bash
#
# Build a self-contained, relocatable tippecanoe toolchain.
#
# Same shape as packages/gdal, arrived at far more cheaply: tippecanoe is six
# static executables, so there is no shared library to relocate and no rpath to
# get right. SQLite and zlib are compiled as static archives and linked *into*
# each binary, so the result depends on nothing but the platform's own C/C++
# runtime.
#
#   ./build.sh              build into ./work/out and produce a tarball
#   OUT_DIR=/tmp/x ./build.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/versions.env"

WORK="${WORK_DIR:-$ROOT/work}"
CACHE="${CACHE_DIR:-$WORK/cache}"
SRC="$WORK/src"
DEPS="$WORK/deps"                 # static deps; build-time only, never shipped
OUT="${OUT_DIR:-$WORK/out}"       # exactly what lands in the tarball
DIST="${DIST_DIR:-$WORK/dist}"
JOBS="${JOBS:-$( (command -v nproc >/dev/null && nproc) || sysctl -n hw.ncpu || echo 4 )}"

# Derived from the commit, so every platform job agrees and a tag reproduces.
DIST_VERSION="$("$ROOT/dist-version.sh")"

log() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- platform --
case "$(uname -s)" in
  Darwin) OS=macos ;;
  Linux)  OS=linux ;;
  *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) ARCH=arm64 ;;
  x86_64|amd64)  ARCH=x64 ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac
PLATFORM="$OS-$ARCH"

if [ "$OS" = macos ]; then
  export MACOSX_DEPLOYMENT_TARGET
  EXTRA_LDFLAGS=""
  EXTRA_LDLIBS=""
else
  # Static SQLite calls pthread_* and dl*, and on glibc 2.28 -- manylinux_2_28's
  # floor -- those still live in libpthread.so and libdl.so rather than libc
  # (glibc merged them in 2.34). Five of the six link lines end in -lpthread and
  # happen to work; `tippecanoe-enumerate` ends in a bare -lsqlite3 and does not,
  # so the missing symbols surface on exactly one binary, on exactly Linux.
  # macOS never sees it: pthread and dl are part of libSystem there.
  EXTRA_LDLIBS="-lpthread -ldl"
  # Keep the C++ runtime inside our own binaries, so the tarball does not
  # require a newer libstdc++ than the host happens to ship.
  #
  # packages/gdal deliberately does the opposite, and the difference is not an
  # inconsistency: libgdal is loaded into the same process as the PyPI bindings'
  # _gdal.so, which links libstdc++ dynamically, so a private runtime inside
  # libgdal means two runtimes and exceptions that fail to match across the
  # boundary. tippecanoe ships six standalone executables. Nothing links
  # against them, nothing loads them, so there is no boundary for an exception
  # to cross -- and static is then strictly better, because it removes the
  # libstdc++ version floor from the tarball entirely.
  EXTRA_LDFLAGS="-static-libstdc++ -static-libgcc"
fi

mkdir -p "$CACHE" "$SRC" "$DEPS" "$OUT" "$DIST"

# ------------------------------------------------------------------- fetch --
fetch() { # url sha256 filename
  local url="$1" sha="$2" file="$3" path="$CACHE/$3"
  if [ ! -f "$path" ]; then
    log "fetch $file"
    curl -fsSL --retry 3 -o "$path.tmp" "$url"
    mv "$path.tmp" "$path"
  fi
  local actual
  actual="$( (command -v sha256sum >/dev/null && sha256sum "$path" | cut -d' ' -f1) \
             || shasum -a 256 "$path" | cut -d' ' -f1 )"
  if [ "$actual" != "$sha" ]; then
    echo "checksum mismatch for $file" >&2
    echo "  expected $sha" >&2
    echo "  actual   $actual" >&2
    exit 1
  fi
}

extract() { # file dest-dir-name
  local file="$1" dir="$2"
  [ -d "$SRC/$dir" ] && return 0
  log "extract $file"
  tar -xf "$CACHE/$file" -C "$SRC"
}

fetch "https://www.sqlite.org/${SQLITE_ARCHIVE_YEAR}/sqlite-autoconf-${SQLITE_ARCHIVE_VERSION}.tar.gz" \
      "$SQLITE_SHA256" "sqlite-autoconf-${SQLITE_ARCHIVE_VERSION}.tar.gz"
fetch "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" \
      "$ZLIB_SHA256" "zlib-${ZLIB_VERSION}.tar.gz"

extract "sqlite-autoconf-${SQLITE_ARCHIVE_VERSION}.tar.gz" "sqlite-autoconf-${SQLITE_ARCHIVE_VERSION}"
extract "zlib-${ZLIB_VERSION}.tar.gz" "zlib-${ZLIB_VERSION}"

# -------------------------------------------------------------- tippecanoe --
# felt/tippecanoe attaches no assets to its releases, so the only tarball on
# offer is GitHub's auto-generated archive -- and those are regenerated on
# demand, not stored, so their bytes are not guaranteed stable (GitHub changed
# archive compression in 2023 and invalidated published checksums everywhere).
# A commit SHA is content-addressed by git and cannot drift, so it is the
# stronger pin, and it is what versions.env records. See README.md.
TIP="$SRC/tippecanoe-${TIPPECANOE_VERSION}"
if [ ! -d "$TIP/.git" ]; then
  log "clone tippecanoe $TIPPECANOE_VERSION"
  rm -rf "$TIP"
  # A tag is a mutable pointer; --depth 1 fetches its commit and nothing else,
  # and the check below is what turns the tag into a pin.
  git clone --quiet --depth 1 --branch "$TIPPECANOE_VERSION" \
    https://github.com/felt/tippecanoe.git "$TIP"
fi
head_sha="$(git -C "$TIP" rev-parse HEAD)"
if [ "$head_sha" != "$TIPPECANOE_COMMIT" ]; then
  echo "tippecanoe commit mismatch for tag $TIPPECANOE_VERSION" >&2
  echo "  expected $TIPPECANOE_COMMIT" >&2
  echo "  actual   $head_sha" >&2
  echo "The tag moved, or versions.env is stale. Do not build this." >&2
  exit 1
fi
# Second, independent check: the source declares its own version, so a pin that
# points at the wrong commit is caught even if the SHA above was updated to
# match it. VERSION is "v2.79.0"; TIPPECANOE_VERSION is "2.79.0".
declared="$(sed -n 's/^#define VERSION "v\(.*\)"$/\1/p' "$TIP/version.hpp")"
if [ "$declared" != "$TIPPECANOE_VERSION" ]; then
  echo "version.hpp declares $declared, versions.env says $TIPPECANOE_VERSION" >&2
  exit 1
fi
log "tippecanoe $TIPPECANOE_VERSION @ $head_sha"

# ------------------------------------------------------------------ sqlite --
# Built straight from the amalgamation rather than via configure: two commands,
# no autotools surprises, and full control over the feature defines. These are
# the same defines packages/gdal uses, so one SQLite behaves like the other.
# -fPIC is not optional: tippecanoe compiles itself -fPIE, and on x86-64 a
# non-PIC archive linked into a PIE executable fails with a relocation error
# (aarch64 happens to tolerate it, which is how this hides until linux-x64).
if [ ! -f "$DEPS/lib/libsqlite3.a" ]; then
  log "build sqlite $SQLITE_VERSION (static)"
  mkdir -p "$DEPS/lib" "$DEPS/include"
  sq="$SRC/sqlite-autoconf-${SQLITE_ARCHIVE_VERSION}"
  defs=(-DSQLITE_ENABLE_COLUMN_METADATA=1 -DSQLITE_ENABLE_RTREE=1
        -DSQLITE_ENABLE_MATH_FUNCTIONS=1 -DSQLITE_ENABLE_DBSTAT_VTAB=1
        -DSQLITE_THREADSAFE=1 -DSQLITE_MAX_VARIABLE_NUMBER=250000)
  ( cd "$sq"
    cc -O2 -fPIC "${defs[@]}" -c sqlite3.c -o sqlite3.o
    ar rcs "$DEPS/lib/libsqlite3.a" sqlite3.o
    cp sqlite3.h sqlite3ext.h "$DEPS/include/" )
  # Unlike gdal, nothing here needs the sqlite3 CLI (PROJ used it to assemble
  # proj.db) or a .pc file (tippecanoe's Makefile does not use pkg-config).
fi

# -------------------------------------------------------------------- zlib --
# tippecanoe links -lz for mbtiles/pbf compression. Static, and -fPIC for the
# same PIE reason as sqlite above.
if [ ! -f "$DEPS/lib/libz.a" ]; then
  log "build zlib $ZLIB_VERSION (static)"
  ( cd "$SRC/zlib-${ZLIB_VERSION}"
    # zlib's configure is hand-written, not autotools: it takes no --host and
    # reads CFLAGS from the environment. --static suppresses the shared build,
    # so no libz.so is produced for the linker to find by accident.
    CFLAGS="-O2 -fPIC" ./configure --prefix="$DEPS" --static
    make -j "$JOBS"
    make install )
fi

# -------------------------------------------------------------- tippecanoe --
# Two Makefile variables have to be overridden on the command line, not in the
# environment, because the Makefile assigns them with plain `=`:
#
#   LIBS     = -L/usr/local/lib       would find a Homebrew libsqlite3.dylib
#   INCLUDES = -I/usr/local/include   and, listed before -I., its sqlite3.h
#
# Both point at exactly where Homebrew installs on Intel macOS and where
# /usr/local/lib sits on Linux, so leaving either in place means the build
# quietly links whatever the runner happens to have. INCLUDES must keep `-I.`
# and `-Iclipper2/include` or the sources cannot find their own headers.
#
# CFLAGS/CXXFLAGS go through the *environment* instead, because the Makefile
# appends to them (`CXXFLAGS := $(CXXFLAGS) -std=c++17 -fPIE ...`) -- setting
# them on the command line would replace that and drop -std=c++17.
#
# BUILD_INFO is deliberately left empty: setting it appends to what
# `tippecanoe --version` prints, which smoke-test.sh matches exactly.
log "build tippecanoe $TIPPECANOE_VERSION (static deps linked in)"
rm -rf "$OUT"; mkdir -p "$OUT"
( cd "$TIP"
  # `make install` builds the six shipped binaries as prerequisites; plain
  # `make` would also build `unit`, the test harness, which nothing ships.
  CFLAGS="-O2" CXXFLAGS="-O2" \
  make -j "$JOBS" install \
    PREFIX="$OUT" \
    INCLUDES="-I$DEPS/include -I. -Iclipper2/include" \
    LIBS="-L$DEPS/lib" \
    LDFLAGS="-L$DEPS/lib $EXTRA_LDFLAGS $EXTRA_LDLIBS" )

# Component licenses travel with the binaries. Everything linked in here is
# permissive, so unlike gdal there is no relinking provision to satisfy.
cat > "$OUT/LICENSES.md" <<LIC
# Licenses

This distribution links the following projects into each binary in \`bin/\`:

| Component | Version | License |
| --- | --- | --- |
| tippecanoe | ${TIPPECANOE_VERSION} | BSD-2-Clause |
| SQLite | ${SQLITE_VERSION} | Public domain |
| zlib | ${ZLIB_VERSION} | Zlib |

All sources are unmodified upstream releases. tippecanoe is pinned to commit
${TIPPECANOE_COMMIT}; its dependencies are pinned by SHA256. \`versions.env\`
and \`build.sh\` in the source repository reproduce this build exactly.
LIC

log "strip binaries"
if [ "$OS" = macos ]; then
  find "$OUT/bin" -type f -perm -u+x -exec strip -x {} \; 2>/dev/null || true
  # Any load-command edit invalidates the ad-hoc signature on arm64.
  find "$OUT/bin" -type f -perm -u+x -exec codesign -f -s - {} \; 2>/dev/null || true
else
  find "$OUT/bin" -type f -perm -u+x -exec strip --strip-unneeded {} \; 2>/dev/null || true
fi

# ------------------------------------------------------------------ package --
TARBALL="tippecanoe-${DIST_VERSION}-${PLATFORM}.tar.gz"
log "package $TARBALL"
# Start from an empty dist dir. A rerun after a version or revision change
# otherwise leaves the previous tarball beside the new one, and the release
# workflow uploads everything it finds -- which would attach an asset from a
# different version to the release.
rm -rf "$DIST"
mkdir -p "$DIST"
tar -C "$OUT" -czf "$DIST/$TARBALL" .
( cd "$DIST" && { command -v sha256sum >/dev/null && sha256sum "$TARBALL" || shasum -a 256 "$TARBALL"; } > "$TARBALL.sha256" )

log "done"
echo "  tarball : $DIST/$TARBALL"
echo "  size    : $(du -h "$DIST/$TARBALL" | cut -f1)"
echo "  tree    : $OUT"
