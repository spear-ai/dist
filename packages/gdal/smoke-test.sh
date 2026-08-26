#!/usr/bin/env bash
#
# Verify a built tree is actually self-contained and functional.
# Runs against $1 (default ./work/out). Exits non-zero on any failure.
#
#   ./smoke-test.sh                 structural + functional checks
#   ./smoke-test.sh <dir> --python  additionally build the PyPI bindings against it
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/versions.env"

TREE="${1:-$ROOT/work/out}"
[ "${1:-}" = "--python" ] && TREE="$ROOT/work/out"
WITH_PYTHON=0
for a in "$@"; do [ "$a" = "--python" ] && WITH_PYTHON=1; done
if [ ! -d "$TREE" ]; then
  echo "no build tree at $TREE - run ./build.sh first" >&2; exit 1
fi
TREE="$(cd "$TREE" && pwd)"

TREEERR="$(mktemp)"
fails=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fails=$((fails+1)); }
sect() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# Deliberately hostile: PROJ_DATA unset (proj.db must be embedded), no
# Homebrew on PATH, no library-path overrides. GDAL_DATA points into the tree,
# which is what the mise config does for consumers.
run() { env -u PROJ_DATA -u DYLD_LIBRARY_PATH -u LD_LIBRARY_PATH \
            GDAL_DATA="$TREE/share/gdal" PATH=/usr/bin:/bin "$@"; }
# Same, but with GDAL_DATA also stripped, to isolate what PROJ provides alone.
run_bare() { env -u PROJ_DATA -u GDAL_DATA -u DYLD_LIBRARY_PATH -u LD_LIBRARY_PATH \
            PATH=/usr/bin:/bin "$@"; }

sect "version"
v="$(run "$TREE/bin/gdalinfo" --version 2>"$TREEERR")"
case "$v" in
  *"$GDAL_VERSION"*) pass "$v" ;;
  *)
    fail "expected GDAL $GDAL_VERSION, got: ${v:-<nothing>}"
    [ -s "$TREEERR" ] && sed 's/^/       /' "$TREEERR" | head -5
    # Everything downstream depends on the binaries running at all.
    echo "       (binaries do not execute; remaining checks will cascade)"
    ;;
esac

sect "drivers required by the cartography pipeline"
vec="$(run "$TREE/bin/ogrinfo" --formats 2>/dev/null)"
ras="$(run "$TREE/bin/gdalinfo" --formats 2>/dev/null)"
for d in S57 GeoJSON "ESRI Shapefile" FlatGeobuf GPKG MVT PMTiles; do
  case "$vec" in *"$d"*) pass "vector: $d" ;; *) fail "vector driver missing: $d" ;; esac
done
for d in GTiff PNG JPEG; do
  case "$ras" in *"$d"*) pass "raster: $d" ;; *) fail "raster driver missing: $d" ;; esac
done

sect "resources"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp" "$TREEERR"' EXIT
echo '{"type":"Feature","properties":{},"geometry":{"type":"Point","coordinates":[-122.4,37.8]}}' > "$tmp/in.geojson"
if run_bare "$TREE/bin/ogr2ogr" -f GeoJSON "$tmp/out.geojson" "$tmp/in.geojson" \
       -s_srs EPSG:4326 -t_srs EPSG:3857 >/dev/null 2>&1; then
  coords="$(grep -o '"coordinates":[^}]*' "$tmp/out.geojson" 2>/dev/null | head -1)"
  case "$coords" in
    *-13625505*) pass "EPSG:4326 -> 3857 with PROJ_DATA unset (proj.db is embedded)" ;;
    *) fail "reprojection produced unexpected output: $coords" ;;
  esac
else
  fail "reprojection failed - proj.db is not embedded in libgdal"
fi

# S-57 needs its object-class tables from share/gdal. Without them the driver
# still advertises itself but cannot actually read a cell, so check both that
# the file ships and that GDAL_DATA resolves it.
if [ -f "$TREE/share/gdal/s57objectclasses.csv" ]; then
  pass "share/gdal ships the S-57 object class tables"
else
  fail "share/gdal/s57objectclasses.csv missing - S-57 cannot be read"
fi
s57="$(run "$TREE/bin/ogrinfo" --format S57 2>/dev/null)"
case "$s57" in
  *Supports:*) pass "S57 driver metadata resolves via GDAL_DATA" ;;
  *)           fail "S57 driver metadata unavailable: ${s57:-<no output>}" ;;
esac

# GDAL's own SQLite dialect implements only a subset of the ST_* functions.
# ST_PointOnSurface and ST_Centroid come from SpatiaLite, and the nautical
# label step fails at runtime without them ("no such function"), so assert the
# exact set the pipeline calls.
sect "SQL functions (SpatiaLite)"
poly="POLYGON((0 0,0 10,10 10,10 0,0 0))"
while IFS='|' read -r name expr expect; do
  [ -z "$name" ] && continue
  out="$(run "$TREE/bin/ogrinfo" -q -dialect SQLITE \
         -sql "SELECT ST_AsText($expr) AS g" "$tmp/in.geojson" 2>&1)"
  case "$out" in
    *"no such function"*) fail "$name unavailable - SpatiaLite not linked in" ;;
    *"$expect"*)          pass "$name" ;;
    *)                    fail "$name: $(echo "$out" | tail -1)" ;;
  esac
done <<SQLCHECKS
ST_PointOnSurface|ST_PointOnSurface(ST_GeomFromText('$poly'))|POINT
ST_Centroid|ST_Centroid(ST_GeomFromText('$poly'))|POINT
ST_MakeValid|ST_MakeValid(ST_GeomFromText('$poly'))|POLYGON
ST_Buffer|ST_Buffer(ST_GeomFromText('$poly'),1)|POLYGON
SQLCHECKS

# A private C++ runtime inside libgdal is invisible to every functional check
# but breaks exceptions and RTTI across the boundary to the Python bindings,
# which link libstdc++ dynamically. Assert one shared runtime.
sect "C++ runtime"
if [ "$(uname -s)" = Darwin ]; then
  if otool -L "$TREE/lib/libgdal.dylib" 2>/dev/null | grep -q "libc++"; then
    pass "libgdal links the platform C++ runtime"
  else
    fail "libgdal does not link libc++ - it may carry a private C++ runtime"
  fi
else
  needed="$(readelf -d "$TREE/lib/libgdal.so" 2>/dev/null)"
  case "$needed" in
    *libstdc++.so.6*) pass "libgdal links libstdc++.so.6 dynamically" ;;
    *) fail "libgdal has no libstdc++ dependency - it carries a private C++ runtime" ;;
  esac
  # operator new / __cxa_throw defined here means a second, private copy.
  dup=0
  for sym in _Znwm _ZdlPv __cxa_throw; do
    if nm -D --defined-only "$TREE/lib/libgdal.so" 2>/dev/null | grep -qw "$sym" \
       || nm -a "$TREE/lib/libgdal.so" 2>/dev/null | grep -qE " [tT] $sym\$"; then
      echo "      libgdal defines its own $sym"; dup=$((dup+1))
    fi
  done
  [ "$dup" -eq 0 ] && pass "no duplicate C++ runtime symbols in libgdal" \
                   || fail "$dup duplicated C++ runtime symbol(s) - exceptions across the binding boundary are unsafe"
fi

sect "layout"
if [ -d "$TREE/lib" ] && [ ! -d "$TREE/lib64" ]; then
  pass "libraries are in lib/ on every platform"
else
  fail "expected lib/ and no lib64/ (GNUInstallDirs picks lib64 on RedHat-family)"
fi

sect "self-containment"
if [ "$(uname -s)" = Darwin ]; then
  ext=dylib
  libs="$(otool -L "$TREE/lib/libgdal.dylib" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -v ':$')"
  allow='^(/usr/lib/|/System/|@rpath/|@loader_path/)'
else
  ext=so
  # DT_NEEDED entries are what the loader will actually demand.
  libs="$(readelf -d "$TREE/lib/libgdal.so" 2>/dev/null \
          | awk '/NEEDED/ {gsub(/[][]/,"",$5); print $5}')"
  allow='^(libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|libgcc_s\.so|libstdc\+\+\.so|ld-linux)'
fi
if [ -z "$(echo "$libs" | tr -d '[:space:]')" ]; then
  fail "could not read dynamic dependencies of libgdal.$ext (otool/readelf missing?)"
fi
foreign=0
while read -r l; do
  [ -z "$l" ] && continue
  if ! [[ $l =~ $allow ]]; then
    echo "      unexpected dependency: $l"; foreign=$((foreign+1))
  fi
done <<< "$libs"
[ "$foreign" -eq 0 ] && pass "libgdal.$ext links only platform libraries" \
                     || fail "$foreign non-system dependencies"

leaked=0
BW="${WORK_DIR:-$ROOT/work}"
for probe in /opt/homebrew /usr/local/Cellar /home/linuxbrew "$BW/deps" "$BW/out"; do
  hits="$(grep -rla -- "$probe" "$TREE/bin" "$TREE/lib" 2>/dev/null)"
  if [ -n "$hits" ]; then
    echo "$hits" | sed "s|^|      $probe in |"
    leaked=$((leaked+1))
  fi
done
[ "$leaked" -eq 0 ] && pass "no build-time paths embedded in output" \
                    || fail "$leaked build-time path(s) leaked"

if command -v pkg-config >/dev/null 2>&1; then
  pcout="$(PKG_CONFIG_PATH="$TREE/lib/pkgconfig" pkg-config --libs --cflags gdal 2>/dev/null)"
  case "$pcout" in
    *"$TREE"*) pass "gdal.pc resolves into the tree" ;;
    "") fail "gdal.pc could not be read by pkg-config" ;;
    *) fail "gdal.pc does not point at this tree: $pcout" ;;
  esac
fi

sect "relocatability"
movedbase="$(mktemp -d)"
mkdir -p "$movedbase/relocated"
moved="$(cd "$movedbase/relocated" && pwd)"
cp -R "$TREE"/* "$moved"/ 2>/dev/null
if env -u PROJ_DATA GDAL_DATA="$moved/share/gdal" PATH=/usr/bin:/bin \
     "$moved/bin/gdalinfo" --version >/dev/null 2>&1; then
  pass "runs from an unrelated directory"
else
  fail "broken after moving - rpath or prefix is absolute"
fi
p="$(run_bare "$moved/bin/gdal-config" --prefix 2>/dev/null)"
[ "$p" = "$moved" ] && pass "gdal-config --prefix follows the tree ($p)" \
                    || fail "gdal-config --prefix reports '$p', expected '$moved'"
rm -rf "$movedbase"

if [ "$WITH_PYTHON" = 1 ]; then
  sect "python bindings build against this tree"
  # Mirror how the consuming project installs: uv with a managed CPython.
  # The `python -m venv` + pip path is only a fallback for hosts without uv,
  # and some system pythons silently drop LDFLAGS when linking extensions,
  # which would make the rpath check below fail for the wrong reason.
  venv=""; installer=""
  if command -v uv >/dev/null 2>&1 \
     && (cd "$tmp" && uv venv --python 3.12 -q) >"$tmp/venv.log" 2>&1; then
    venv="$tmp/.venv"; installer="uv"
    pipcmd() { uv pip install --python "$venv/bin/python" -q --no-cache "$@"; }
  else
    for cand in python3.12 python3 python; do
      c="$(command -v "$cand" 2>/dev/null)" || true
      [ -z "$c" ] && continue
      rm -rf "$tmp/venv"
      if "$c" -m venv "$tmp/venv" >"$tmp/venv.log" 2>&1 && [ -x "$tmp/venv/bin/pip" ]; then
        venv="$tmp/venv"; installer="$c"
        pipcmd() { "$venv/bin/pip" install -q --no-cache-dir "$@"; }
        break
      fi
    done
  fi

  if [ -z "$venv" ]; then
    fail "could not create a virtualenv with a working installer"
    sed 's/^/       /' "$tmp/venv.log" 2>/dev/null | tail -3
  elif (
      # GDAL's setup.py records no rpath of its own, so inject one or the
      # extension binds to whatever other libgdal the loader can reach.
      export PATH="$TREE/bin:$PATH" LDFLAGS="-Wl,-rpath,$TREE/lib"
      pipcmd "gdal==$GDAL_VERSION"
    ) >"$tmp/pip.log" 2>&1; then
    pass "installed gdal==$GDAL_VERSION against this tree (via $installer)"

    if out="$(GDAL_DATA="$TREE/share/gdal" "$venv/bin/python" -c "
from osgeo import gdal, ogr, osr
gdal.UseExceptions()
assert ogr.GetDriverByName('S57'), 'no S57'
assert ogr.GetDriverByName('PMTiles'), 'no PMTiles'
sr = osr.SpatialReference(); sr.ImportFromEPSG(3857)
print(gdal.__version__)
" 2>&1)"; then
      pass "osgeo imports and resolves EPSG:3857 (version $out)"
    else
      fail "import failed: $(echo "$out" | tail -2)"
    fi

    so="$(ls "$venv"/lib/python*/site-packages/osgeo/_gdal.*.so 2>/dev/null | head -1)"
    if [ "$(uname -s)" = Darwin ]; then
      meta="$(otool -l "$so" 2>/dev/null)"
    else
      meta="$(readelf -d "$so" 2>/dev/null)"
    fi
    case "$meta" in
      *"$TREE/lib"*) pass "_gdal extension records an rpath into this tree" ;;
      *) fail "_gdal extension has no rpath into $TREE/lib (may bind to another libgdal)" ;;
    esac
  else
    fail "install failed"
    grep -E "fatal error|error:|Error [0-9]" "$tmp/pip.log" | tail -4 | sed 's/^/       /'
  fi
fi

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf '\033[32mall checks passed\033[0m\n'; exit 0
else
  printf '\033[31m%d check(s) failed\033[0m\n' "$fails"; exit 1
fi
