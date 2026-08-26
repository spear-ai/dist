#!/usr/bin/env bash
#
# Build a self-contained, relocatable GDAL toolchain.
#
# The shape of the output is the whole point: PROJ, GEOS and SQLite are
# compiled as static archives and linked *into* a shared libgdal, so the
# result depends on nothing but the platform's own C/C++ runtime. There is
# no dependency closure to ship, relocate, or keep in sync.
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
  RPATH='@loader_path/../lib'
  export MACOSX_DEPLOYMENT_TARGET
  EXTRA_LDFLAGS=""
  SQLITE_LDLIBS="-lm"
  CXXLIB="-lc++"
  # libspatialite's configure link-tests with the C compiler, so the static
  # closure of PROJ (C++, needs sqlite3) has to be spelled out.
  SPATIALITE_LIBS="-lsqlite3 -lc++"
else
  RPATH='$ORIGIN/../lib'
  # Keep the C++ runtime inside our own binaries so the tarball does not
  # require a newer libstdc++ than the host happens to ship.
  EXTRA_LDFLAGS="-static-libstdc++ -static-libgcc"
  SQLITE_LDLIBS="-lm -ldl -lpthread"
  CXXLIB="-lstdc++"
  SPATIALITE_LIBS="-lsqlite3 -lstdc++ -lm -ldl -lpthread"
fi

if command -v ninja >/dev/null 2>&1; then GEN=(-G Ninja); else GEN=(-G "Unix Makefiles"); fi

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
fetch "https://download.osgeo.org/proj/proj-${PROJ_VERSION}.tar.gz" \
      "$PROJ_SHA256" "proj-${PROJ_VERSION}.tar.gz"
fetch "https://download.osgeo.org/geos/geos-${GEOS_VERSION}.tar.bz2" \
      "$GEOS_SHA256" "geos-${GEOS_VERSION}.tar.bz2"
fetch "https://www.gaia-gis.it/gaia-sins/libspatialite-sources/libspatialite-${SPATIALITE_VERSION}.tar.gz" \
      "$SPATIALITE_SHA256" "libspatialite-${SPATIALITE_VERSION}.tar.gz"
fetch "https://github.com/OSGeo/gdal/releases/download/v${GDAL_VERSION}/gdal-${GDAL_VERSION}.tar.gz" \
      "$GDAL_SHA256" "gdal-${GDAL_VERSION}.tar.gz"

extract "sqlite-autoconf-${SQLITE_ARCHIVE_VERSION}.tar.gz" "sqlite-autoconf-${SQLITE_ARCHIVE_VERSION}"
extract "proj-${PROJ_VERSION}.tar.gz"   "proj-${PROJ_VERSION}"
extract "geos-${GEOS_VERSION}.tar.bz2"  "geos-${GEOS_VERSION}"
extract "libspatialite-${SPATIALITE_VERSION}.tar.gz" "libspatialite-${SPATIALITE_VERSION}"
extract "gdal-${GDAL_VERSION}.tar.gz"   "gdal-${GDAL_VERSION}"

# ------------------------------------------------------------------ sqlite --
# Built straight from the amalgamation rather than via configure: two commands,
# no autotools surprises, and full control over the feature defines. RTREE is
# what GeoPackage spatial indexes are built on, so it is not optional for us.
if [ ! -f "$DEPS/lib/libsqlite3.a" ]; then
  log "build sqlite $SQLITE_VERSION (static)"
  mkdir -p "$DEPS/lib" "$DEPS/include" "$DEPS/bin" "$DEPS/lib/pkgconfig"
  sq="$SRC/sqlite-autoconf-${SQLITE_ARCHIVE_VERSION}"
  defs=(-DSQLITE_ENABLE_COLUMN_METADATA=1 -DSQLITE_ENABLE_RTREE=1
        -DSQLITE_ENABLE_MATH_FUNCTIONS=1 -DSQLITE_ENABLE_DBSTAT_VTAB=1
        -DSQLITE_THREADSAFE=1 -DSQLITE_MAX_VARIABLE_NUMBER=250000)
  ( cd "$sq"
    cc -O2 -fPIC "${defs[@]}" -c sqlite3.c -o sqlite3.o
    ar rcs "$DEPS/lib/libsqlite3.a" sqlite3.o
    # PROJ needs the CLI at build time to assemble proj.db from its SQL sources.
    cc -O2 "${defs[@]}" shell.c sqlite3.c -o "$DEPS/bin/sqlite3" $SQLITE_LDLIBS
    cp sqlite3.h sqlite3ext.h "$DEPS/include/" )
  cat > "$DEPS/lib/pkgconfig/sqlite3.pc" <<PC
prefix=$DEPS
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: SQLite
Description: SQL database engine
Version: $SQLITE_VERSION
Libs: -L\${libdir} -lsqlite3
Cflags: -I\${includedir}
PC
fi

# -------------------------------------------------------------------- proj --
# EMBED_RESOURCE_FILES bakes proj.db into the library, which is what frees the
# tarball from needing a PROJ_DATA env var. TIFF and CURL are off because they
# exist only to fetch/read datum-shift grids we do not use; see README.
if [ ! -f "$DEPS/lib/libproj.a" ]; then
  log "build proj $PROJ_VERSION (static, proj.db embedded)"
  cmake -S "$SRC/proj-${PROJ_VERSION}" -B "$WORK/build-proj" "${GEN[@]}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$DEPS" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_PREFIX_PATH="$DEPS" \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_TESTING=OFF \
    -DBUILD_APPS=OFF \
    -DBUILD_PROJSYNC=OFF \
    -DENABLE_TIFF=OFF \
    -DENABLE_CURL=OFF \
    -DEMBED_RESOURCE_FILES=ON \
    -DUSE_ONLY_EMBEDDED_RESOURCE_FILES=ON \
    -DEMBED_PROJ_DATA_PATH=OFF \
    -DPROJ_OBJECT_LIBRARIES_POSITION_INDEPENDENT_CODE=ON \
    -DSQLITE3_INCLUDE_DIR="$DEPS/include" \
    -DSQLITE3_LIBRARY="$DEPS/lib/libsqlite3.a" \
    -DEXE_SQLITE3="$DEPS/bin/sqlite3"
  cmake --build "$WORK/build-proj" -j "$JOBS"
  cmake --install "$WORK/build-proj"
fi

# -------------------------------------------------------------------- geos --
if [ ! -f "$DEPS/lib/libgeos_c.a" ]; then
  log "build geos $GEOS_VERSION (static)"
  cmake -S "$SRC/geos-${GEOS_VERSION}" -B "$WORK/build-geos" "${GEN[@]}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$DEPS" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_TESTING=OFF \
    -DBUILD_DOCUMENTATION=OFF \
    -DBUILD_GEOSOP=OFF
  cmake --build "$WORK/build-geos" -j "$JOBS"
  cmake --install "$WORK/build-geos"
fi

# ------------------------------------------------------------- spatialite --
# GDAL's built-in SQLite dialect implements only a subset of the ST_* functions
# (ST_Area, ST_Buffer, ST_MakeValid) and omits ST_PointOnSurface and
# ST_Centroid, so SQL that places one label point per feature fails at runtime
# with "no such function". SpatiaLite supplies the full set.
if [ ! -f "$DEPS/lib/libspatialite.a" ]; then
  log "build libspatialite $SPATIALITE_VERSION (static)"

  # libspatialite's configure does LIBS="$(geos-config --ldflags)" -- clobbering
  # whatever we pass -- and then link-tests a bare -lgeos_c. GEOS 3.14's
  # --ldflags returns only -L<dir>, which cannot resolve a static libgeos_c.a.
  # A shim returning the full static C link line fixes it without patching
  # upstream sources.
  cat > "$WORK/geos-config-static" <<SHIM
#!/bin/sh
case "\$1" in
  --ldflags) echo "-L$DEPS/lib -lgeos_c -lgeos $CXXLIB -lm" ;;
  *) exec "$DEPS/bin/geos-config" "\$@" ;;
esac
SHIM
  chmod +x "$WORK/geos-config-static"

  # libspatialite 5.1.0 ships config.guess/config.sub stamped 2009-11-20, which
  # predate aarch64 and abort with "cannot guess build type" on ARM Linux.
  # Refresh them from the host's automake copies, as distro packaging does.
  for f in config.guess config.sub; do
    for d in /usr/share/automake-* /usr/share/gnuconfig \
             /usr/share/libtool/build-aux /opt/homebrew/share/automake-*; do
      if [ -f "$d/$f" ]; then
        cp -f "$d/$f" "$SRC/libspatialite-${SPATIALITE_VERSION}/$f"
        break
      fi
    done
  done

  ( cd "$SRC/libspatialite-${SPATIALITE_VERSION}"
    ./configure \
      --prefix="$DEPS" \
      --enable-static --disable-shared \
      --disable-freexl --disable-rttopo --disable-libxml2 \
      --disable-minizip --disable-examples \
      --with-geosconfig="$WORK/geos-config-static" \
      CFLAGS="-fPIC -O2" \
      CPPFLAGS="-I$DEPS/include" \
      LDFLAGS="-L$DEPS/lib" \
      LIBS="$SPATIALITE_LIBS" \
      PKG_CONFIG_PATH="$DEPS/lib/pkgconfig"
    make -j "$JOBS"
    make install )
fi

# -------------------------------------------------------------------- gdal --
# GDAL_USE_EXTERNAL_LIBS=OFF is the flag that makes this build deterministic:
# nothing is picked up merely because it happens to be installed on the runner.
# Everything we want is then named explicitly.
#
# Note the asymmetry with PROJ above: GDAL's EMBED_RESOURCE_FILES is a hard
# error unless the compiler implements C23 #embed (clang >= 19 / gcc >= 15).
# Apple clang and manylinux's gcc-toolset-14 do not, so GDAL's resource files
# ship as share/gdal and are located via GDAL_DATA. PROJ has a non-C23 fallback,
# so proj.db *is* embedded -- which is the half that actually matters, since it
# is the file that silently goes out of sync and drags 774 MB of grids along.
log "build gdal $GDAL_VERSION (shared, deps linked in)"
# FindSPATIALITE reads the version through pkg-config and GDAL requires >= 4.1.2,
# so the .pc directory has to be on PKG_CONFIG_PATH or the check silently fails.
export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
# Configure from scratch: a stale CMake cache silently keeps old option values,
# which makes a rerun disagree with the flags actually written below.
rm -rf "$OUT" "$WORK/build-gdal"; mkdir -p "$OUT"
cmake -S "$SRC/gdal-${GDAL_VERSION}" -B "$WORK/build-gdal" "${GEN[@]}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr/local \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_PREFIX_PATH="$DEPS" \
  -DBUILD_SHARED_LIBS=ON \
  -DCMAKE_INSTALL_RPATH="$RPATH" \
  -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=OFF \
  -DCMAKE_SHARED_LINKER_FLAGS="$EXTRA_LDFLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$EXTRA_LDFLAGS" \
  -DGDAL_USE_EXTERNAL_LIBS=OFF \
  `# iconv is free: a system dylib on macOS, part of glibc on Linux. Without it` \
  `# GDAL cannot recode the non-ASCII names in S-57 cells or shapefile DBFs.` \
  -DGDAL_USE_INTERNAL_LIBS=ON \
  -DGDAL_USE_SQLITE3=ON \
  -DGDAL_USE_GEOS=ON \
  -DGDAL_USE_ICONV=ON \
  -DGDAL_USE_SPATIALITE=ON \
  `# libspatialite calls zlib's crc32. GDAL renames its internal zlib symbols` \
  `# by default, so that reference cannot resolve. Using the standard names` \
  `# keeps zlib inside libgdal -- where -fvisibility=hidden keeps it private --` \
  `# instead of adding an external libz dependency to the tarball.` \
  -DRENAME_INTERNAL_ZLIB_SYMBOLS=OFF \
  -DSQLite3_INCLUDE_DIR="$DEPS/include" \
  -DSQLite3_LIBRARY="$DEPS/lib/libsqlite3.a" \
  -DGDAL_BUILD_OPTIONAL_DRIVERS=OFF \
  -DOGR_BUILD_OPTIONAL_DRIVERS=OFF \
  -DOGR_ENABLE_DRIVER_S57=ON \
  -DOGR_ENABLE_DRIVER_GEOJSON=ON \
  -DOGR_ENABLE_DRIVER_SHAPE=ON \
  -DOGR_ENABLE_DRIVER_FLATGEOBUF=ON \
  -DOGR_ENABLE_DRIVER_SQLITE=ON \
  -DOGR_ENABLE_DRIVER_GPKG=ON \
  -DOGR_ENABLE_DRIVER_MVT=ON \
  -DOGR_ENABLE_DRIVER_PMTILES=ON \
  -DOGR_ENABLE_DRIVER_VRT=ON \
  -DOGR_ENABLE_DRIVER_CSV=ON \
  -DGDAL_ENABLE_DRIVER_GTIFF=ON \
  -DGDAL_ENABLE_DRIVER_VRT=ON \
  -DGDAL_ENABLE_DRIVER_MEM=ON \
  -DGDAL_ENABLE_DRIVER_PNG=ON \
  -DGDAL_ENABLE_DRIVER_JPEG=ON \
  -DBUILD_APPS=ON \
  -DBUILD_PYTHON_BINDINGS=OFF \
  -DBUILD_JAVA_BINDINGS=OFF \
  -DBUILD_CSHARP_BINDINGS=OFF \
  -DBUILD_TESTING=OFF \
  -DBUILD_DOCS=OFF
cmake --build "$WORK/build-gdal" -j "$JOBS"
cmake --install "$WORK/build-gdal" --prefix "$OUT"

# --------------------------------------------------------------- post-fix ---
# CMake writes the build-time prefix into gdal-config and gdal.pc. Both must
# derive their prefix at runtime instead, or the tarball only works in the
# directory it happened to be built in.
log "make gdal-config and gdal.pc relocatable"
cfg="$OUT/bin/gdal-config"
if [ -f "$cfg" ]; then
  python3 - "$cfg" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
here = 'CONFIG_PREFIX="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"'
s = re.sub(r'^CONFIG_PREFIX=.*$', here, s, count=1, flags=re.M)
s = re.sub(r'^CONFIG_LIBS=.*$',   'CONFIG_LIBS="-L$CONFIG_PREFIX/lib -lgdal"', s, count=1, flags=re.M)
s = re.sub(r'^CONFIG_CFLAGS=.*$', 'CONFIG_CFLAGS="-I$CONFIG_PREFIX/include"', s, count=1, flags=re.M)
s = re.sub(r'^CONFIG_DATA=.*$',   'CONFIG_DATA="$CONFIG_PREFIX/share/gdal"', s, count=1, flags=re.M)
# Every dependency is linked inside libgdal, so -lgdal alone is sufficient.
s = re.sub(r'^CONFIG_DEP_LIBS=.*$', 'CONFIG_DEP_LIBS=""', s, count=1, flags=re.M)
s = re.sub(r'^CONFIG_PLUGINDIR=.*$', 'CONFIG_PLUGINDIR="$CONFIG_PREFIX/lib/gdalplugins"', s, count=1, flags=re.M)
open(p, 'w').write(s)
PY
  chmod +x "$cfg"
fi

pc="$OUT/lib/pkgconfig/gdal.pc"
if [ -f "$pc" ]; then
  # Regenerated rather than patched: upstream routes Libs/Cflags through
  # CONFIG_INST_* variables holding absolute build paths, and emits a
  # Libs.private naming our static deps by their build-time -L path. Since
  # every dependency is linked inside libgdal, consumers need none of it.
  cat > "$pc" <<PC
prefix=\${pcfiledir}/../..
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include
datadir=\${prefix}/share/gdal

Name: libgdal
Description: Geospatial Data Abstraction Library
Version: ${GDAL_VERSION}
Libs: -L\${libdir} -lgdal
Cflags: -I\${includedir}
PC
fi

# Component licenses travel with the binaries. GEOS is LGPL-2.1 and is
#    statically linked, which engages the relinking provision of section 6;
#    this repo is the complete corresponding build recipe.
cat > "$OUT/LICENSES.md" <<LIC
# Licenses

This distribution links the following projects into \`lib/libgdal\`:

| Component | Version | License |
| --- | --- | --- |
| GDAL | ${GDAL_VERSION} | MIT |
| PROJ | ${PROJ_VERSION} | MIT |
| GEOS | ${GEOS_VERSION} | LGPL-2.1-or-later |
| SQLite | ${SQLITE_VERSION} | Public domain |

All sources are unmodified upstream releases, pinned by SHA256 in
\`versions.env\`. GEOS is statically linked; \`build.sh\` in the source
repository reproduces this build exactly and is the corresponding source
for the purposes of LGPL-2.1 section 6.
LIC

log "strip binaries"
if [ "$OS" = macos ]; then
  find "$OUT/bin" -type f -perm -u+x -exec strip -x {} \; 2>/dev/null || true
  find "$OUT/lib" -name '*.dylib' -exec strip -x {} \; 2>/dev/null || true
  # Any load-command edit invalidates the ad-hoc signature on arm64.
  find "$OUT/bin" -type f -perm -u+x -exec codesign -f -s - {} \; 2>/dev/null || true
  find "$OUT/lib" -name '*.dylib' -exec codesign -f -s - {} \; 2>/dev/null || true
else
  find "$OUT/bin" -type f -perm -u+x -exec strip --strip-unneeded {} \; 2>/dev/null || true
  find "$OUT/lib" -name '*.so*' -exec strip --strip-unneeded {} \; 2>/dev/null || true
fi

# Static archives of our deps get installed alongside; they are build-time
# artifacts and their code is already inside libgdal.
rm -rf "$OUT/lib"/*.a "$OUT/share/proj" "$OUT/share/doc" "$OUT/share/man" 2>/dev/null || true

# ------------------------------------------------------------------ package --
TARBALL="gdal-${DIST_VERSION}-${PLATFORM}.tar.gz"
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
