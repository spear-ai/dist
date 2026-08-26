# gdal

Self-contained GDAL builds for `mise`, published as GitHub releases for
`macos-arm64`, `linux-arm64` and `linux-x64`.

Part of [`spear-ai/dist`](../..); see the root README for the tag and asset
conventions shared by every package here.

## Why this exists

`horizon-cartography` pins `gdal==3.13.2` on PyPI, and that package is a source
distribution: it compiles against whatever `libgdal` it finds via `gdal-config`.
Homebrew can supply one, but it pins only the minor version, drags in 128
formulae, and moves its own dependencies on its own schedule — so the exact
version pinning that the Python side depends on is not achievable.

## The design decision

Everything else follows from one choice: **PROJ, GEOS and SQLite are compiled as
static archives and linked into a shared `libgdal`.**

```
Homebrew         libgdal.dylib ──dynamic──> 188 dylibs at absolute Cellar paths
gdal-dist        libgdal.dylib  [PROJ + GEOS + SQLite compiled in]
                      └────────> libSystem / libc++      (present on every host)
```

A dependency closure that does not exist cannot go stale, cannot need
`install_name` rewriting, and cannot be relocated wrong. The tarball is one
shared library, the command line tools, and headers. Measured on the built
artifacts, that is the entire dependency surface:

```
linux    libdl.so.2  libm.so.6  libpthread.so.0  libc.so.6  ld-linux
macOS    libSystem.B.dylib  libc++.1.dylib  libiconv.2.dylib
```

Two further consequences worth knowing:

- **`GDAL_USE_EXTERNAL_LIBS=OFF`.** Nothing is linked merely because it happened
  to be installed on the build machine. Every dependency is named explicitly, so
  the same tag produces the same build on any runner. This is the single biggest
  difference from the Homebrew formula, which installs 44 libraries and lets
  CMake discover them — which is how Poppler, x265 and Arrow end up inside a
  Homebrew `libgdal`.
- **`proj.db` is compiled into the library.** PROJ's `EMBED_RESOURCE_FILES`
  bakes its CRS database into `libproj`, so nothing needs `PROJ_DATA`, the
  database cannot drift out of sync with the code that reads it, and the 774 MB
  of datum grids that normally accompany it never enter the picture.

  GDAL's own resource files (S-57 object classes, EPSG tables) ship as
  `share/gdal` instead, located via `GDAL_DATA`. GDAL's equivalent option is a
  hard error unless the compiler implements C23 `#embed` — clang >= 19 or
  gcc >= 15 — which neither Apple clang nor manylinux's gcc-toolset-14 provides.
  Requiring a bleeding-edge toolchain on three platforms is a worse trade than
  one environment variable, and GDAL's data search has no relative-to-binary
  fallback to exploit: it checks `.`, then `GDAL_DATA`, then a compile-time
  absolute prefix.

## Consuming it

```toml
# mise.toml
[tool_alias]                       # not [alias] — that spelling is deprecated
gdal = "github:spear-ai/dist"

[tools]
gdal = { version = "3.13.2", version_prefix = "gdal-v", asset_pattern = "gdal-{{ version }}-{{ os() }}-{{ arch() }}.tar.gz" }

[env]
# GDAL's setup.py records no rpath on its extension modules, so without this the
# compiled _gdal.so silently binds to whatever other libgdal the loader can
# reach — or fails outright when there isn't one.
LDFLAGS = { value = "-Wl,-rpath,{{ tools.gdal.path }}/lib", tools = true }
# Where GDAL's resource files live. PROJ needs no equivalent; proj.db is
# compiled into the library.
GDAL_DATA = { value = "{{ tools.gdal.path }}/share/gdal", tools = true }
```

## Building locally

```shell
./build.sh                 # ~15 min cold; writes work/dist/gdal-<ver>-<platform>.tar.gz
                           # macos-arm64: 12 MB packed, 37 MB installed
                           # linux-arm64: 15 MB packed, 48 MB installed
./smoke-test.sh            # structural + functional checks
./smoke-test.sh work/out --python   # also builds the PyPI bindings against it
```

`work/` is disposable; sources are cached in `work/cache` and re-verified
against their checksums on every run.

The smoke test runs with `PROJ_DATA` and the library-path variables unset and
`PATH` reduced to `/usr/bin:/bin`, then copies the tree elsewhere and re-runs it
from there. Reprojection is additionally checked with `GDAL_DATA` unset too, so
a regression in PROJ embedding cannot hide behind a stray environment variable.

## Releasing

1. Bump `GDAL_VERSION` and `GDAL_SHA256` in `versions.env` (the weekly
   `gdal-upstream` workflow opens this PR for you). CI builds and smoke-tests
   the PR on all three platforms, so the bump is proven before it is tagged.
2. Tag the merged commit `gdal-v<version>` and push. The workflow refuses to
   release if the tag and `versions.env` disagree.
3. It then produces all three tarballs, smoke-tests each, attaches
   `SHA256SUMS`, and attests build provenance — which `mise` verifies by default.

Rebuilding the same GDAL version (a toolchain fix, say) gets a fourth version
component: `gdal-v3.13.2.1`. Never re-tag, since the checksums change.

`versions.env` pins every input by version and SHA256, so a tag rebuilds
identically later. Bumping a dependency is a one-line change there.

## What is deliberately not included

Drivers are opted into rather than out of, so the build stays small and
predictable. Currently enabled: **S57, GeoJSON, ESRI Shapefile, FlatGeobuf,
GPKG, SQLite, MVT, PMTiles, CSV, VRT** (vector) and **GTiff, PNG, JPEG, MEM,
VRT** (raster).

**GNM is enabled even though nothing here uses it.** The PyPI `gdal` sdist
compiles `extensions/gnm_wrap.cpp` unconditionally, so a libgdal built with
`ENABLE_GNM=OFF` installs no `gnm_api.h` and the Python bindings fail to
compile against it. Do not "optimize" it back off without also teaching the
sdist to skip that extension.

`iconv` is enabled despite the otherwise-minimal dependency policy: it is a
system library on macOS and part of glibc on Linux, so it costs nothing to
ship, and without it GDAL cannot recode the non-ASCII place names that appear
throughout NOAA ENC cells and Natural Earth shapefiles.

Notable exclusions, and what to do if you need them:

| Excluded | Consequence | To enable |
| --- | --- | --- |
| curl / OpenSSL | No `/vsicurl`, `/vsis3`, `/vsigs`. Local files only. | Build curl static, set `-DGDAL_USE_CURL=ON`; ship a CA bundle and set `GDAL_CURL_CA_BUNDLE` |
| PROJ datum grids | Grid-based datum shifts fall back to less precise transforms. Irrelevant for WGS84 sources like NOAA ENC and Natural Earth. | `-DENABLE_TIFF=ON` for PROJ, ship `share/proj` grids (~774 MB) or fetch on demand |
| Arrow / Parquet | No `.parquet` or Arrow IPC vector I/O. | Add Arrow static, `-DGDAL_USE_ARROW=ON` |
| netCDF / HDF5 | No scientific array formats. | Add the libs, enable the drivers |
| PostgreSQL | No `PG:` connection strings. | Add libpq, `-DGDAL_USE_POSTGRESQL=ON` |
| Python bindings | Built from the PyPI sdist by `uv` instead, against your own pinned Python. | n/a — the Homebrew ones target its Python, not yours |

## Licensing

The tarball links four projects into `libgdal`: GDAL and PROJ (MIT), SQLite
(public domain), and **GEOS (LGPL-2.1-or-later)**. Static linking of GEOS
engages LGPL-2.1 section 6, which requires that recipients be able to relink
against a modified GEOS. This repository is the complete corresponding source
for that purpose — every input pinned by SHA256, every flag in `build.sh`, and
no patches applied to any upstream source. A `LICENSES.md` naming each
component ships inside the tarball.

If you would rather not reason about that at all, two alternatives: build GEOS
shared and ship `libgeos_c` alongside `libgdal`, or set `GDAL_USE_GEOS=OFF` and
lose `MakeValid`, clipping and simplification — which a tile pipeline probably
uses.

## Runner notes

`linux-arm64` uses the `ubuntu-24.04-arm` runner, which is free for public
repositories and requires a paid plan for private ones. The alternative — QEMU
emulation on x64 — turns a 15 minute build into hours.
