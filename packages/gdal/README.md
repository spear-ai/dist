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

### Version scheme

A release is `<gdal version>.<commit timestamp>` — the upstream version from
`versions.env`, plus the Unix timestamp of the commit being released.
`./dist-version.sh` prints it, and both `build.sh` and the release workflow call
that one script so they cannot disagree:

```console
$ packages/gdal/dist-version.sh
3.13.2.1787743451
```

The revision is the **commit's** timestamp, not the clock's, for two reasons.
The three platform jobs finish up to twenty minutes apart, so a build-time clock
would stamp three different versions onto a single release and none of them
would resolve. And deriving it from the commit makes a tag reproducible — there
is no number to set wrong or forget to reset when `GDAL_VERSION` moves.

Ordering falls out of the upstream components coming first, so a `3.13.3` built
from an older commit still sorts above a later `3.13.2` rebuild:

```
3.13.2.1787743451 > 3.13.2.1787743019   later rebuild of the same version
3.13.3.1000000000 > 3.13.2.1787743451   upstream bump always wins
3.13.2.1787743019 > 3.13.2              a bare version sorts as .0
```

To release, tag the merged commit with what the script reports:

```shell
git tag "gdal-v$(packages/gdal/dist-version.sh)"
```

The workflow refuses to publish if the tag and the commit disagree. Never re-tag
a published version, since the checksums change.


`versions.env` pins every input by version and SHA256, so a tag rebuilds
identically later. Bumping a dependency is a one-line change there.

## What is deliberately not included

Drivers are opted into rather than out of, so the build stays small and
predictable. Currently enabled: **S57, GeoJSON, ESRI Shapefile, FlatGeobuf,
GPKG, SQLite, MVT, PMTiles, CSV, VRT** (vector) and **GTiff, PNG, JPEG, MEM,
VRT** (raster).

**SpatiaLite is linked in** for its `ST_*` SQL functions. GDAL's own SQLite
dialect implements only a subset — `ST_Area`, `ST_Buffer`, `ST_MakeValid` — and
omits `ST_PointOnSurface` and `ST_Centroid`, so SQL that places one label point
per feature fails at runtime with `no such function: ST_PointOnSurface`.
libspatialite's optional dependencies (freexl, librttopo, libxml2, minizip) are
all disabled; what remains is SQLite, PROJ, GEOS and iconv, which this build
already produces. Costs about 3 MB.

Three upstream quirks are worked around in `build.sh`, each commented there:

- Its `configure` clobbers `LIBS` with `geos-config --ldflags` and then
  link-tests a bare `-lgeos_c`. GEOS 3.14's `--ldflags` returns only `-L<dir>`,
  which cannot resolve a static `libgeos_c.a`, so the build passes a
  `geos-config` shim that returns the full static C link line.
- It calls zlib's `crc32`, which forces `RENAME_INTERNAL_ZLIB_SYMBOLS=OFF` so
  GDAL's internal zlib keeps its standard names. Do not re-enable that rename.
- It ships `config.guess`/`config.sub` stamped 2009-11-20, which predate
  aarch64 and abort with `cannot guess build type` on ARM Linux. The build
  refreshes them from the host's automake copies, as distro packaging does.

**Two threading choices are stated explicitly rather than left to chance.**
`GDAL_USE_OPENMP=OFF` was already the outcome, but only because
`GDAL_USE_EXTERNAL_LIBS=OFF` meant OpenMP was never found — a second threading
runtime should not be enabled or disabled by accident when consumers drive GDAL
from their own thread pools. libspatialite also gets
`--enable-geosreentrant`, though only as a guard: it makes `configure` hard-fail
if the reentrant GEOS API is missing. It does **not** change the compiled output,
because libspatialite's `config.h.in` carries no template for `GEOS_REENTRANT`
(nor for any other `GEOS_*`), so `AC_DEFINE` fires during configure and the macro
is then dropped — `DEFS` is only `-DHAVE_CONFIG_H`. That is true of every
libspatialite build including Homebrew's, and the library calls the reentrant
`GEOS*_r` API in 95 places regardless, so reentrancy is largely in effect
independent of the macro.

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

## The C++ runtime must stay dynamic

`libgdal` links `libstdc++` dynamically and must keep doing so. Building with
`-static-libstdc++` gives it a private `operator new`/`delete`, `__cxa_throw` and
RTTI, while the PyPI bindings' `_gdal.so` — compiled on the consumer's machine —
links `libstdc++.so.6`. That puts two C++ runtimes in one process. SWIG wraps
every GDAL call in try/catch to turn C++ exceptions into Python ones, so
exceptions and C++ objects cross that boundary constantly, and duplicated
`type_info` means a `catch` can fail to match. GCC's own documentation requires
the *shared* libgcc for precisely this case.

This is not theoretical — it shipped once. `gdal-v3.13.2.1787749444` carried a
private runtime and segfaulted (exit 139) in horizon's nautical pipeline under an
8-thread pool. The identical code on the identical runner converted 348 cells
once `libgdal` shared the process runtime.

What makes it dangerous is that it hides from functional tests. Single-threaded
use passed, and so did deliberate threaded stress against the broken build —
2400 exceptions across the boundary and 1600 PROJ/GEOS transform cycles. So
`smoke-test.sh` asserts the invariant structurally instead of hoping to trigger
it:

```
ok   libgdal links libstdc++.so.6 dynamically
ok   no duplicate C++ runtime symbols in libgdal
```

Static linking *looks* like a portability win and is not one. gcc-toolset links
the base system's libstdc++ ABI dynamically and statically includes only the
newer symbols, so the shipped library needs `GLIBCXX_3.4.22` while AlmaLinux 8
provides `3.4.25`. manylinux whitelists `libstdc++.so.6` regardless.

## `GDAL_DATA` is load-bearing

Because this build is relocatable, GDAL finds its resource files **only** through
`GDAL_DATA` — it checks `.`, then that variable, then a compile-time absolute
prefix that does not exist on your machine. Homebrew masked this by having a
real compile-time path.

Anything that scrubs the environment will therefore break resource lookup:
turbo tasks (add `GDAL_DATA` to `globalPassThroughEnv`), `docker run` without
`-e`, CI sandboxes, `env -i` wrappers.

**It fails silently, which is the dangerous part.** Observed on the nautical
pipeline with `GDAL_DATA` stripped:

| | S-57 layers reported |
| --- | --- |
| With `GDAL_DATA` | 26 named object classes — ADMARE, COALNE, DEPARE, … |
| Without | 5 generic — DSID, Point, Line, Area, Meta |

The run still exited 0. It emitted 1,000 `Invalid index : -1` warnings, selected
0 label layers instead of 6, and produced a 54.71 MB tileset instead of 75.09 MB
— a chart with no named features, with CI green. If a pipeline can run without
resources present, assert on the output rather than the exit code.

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
