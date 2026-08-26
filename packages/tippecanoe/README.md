# tippecanoe

Self-contained [tippecanoe](https://github.com/felt/tippecanoe) builds for
`mise`, published as GitHub releases for `macos-arm64`, `linux-arm64` and
`linux-x64`.

Part of [`spear-ai/dist`](../..); see the root README for the tag and asset
conventions shared by every package here.

## Why this exists

`horizon` shells out to `tippecanoe` and `tile-join` from its cartography
pipelines, and used to get them from a `mise` `enter` hook that ran
`brew install tippecanoe` on every shell entry. That hook could pin only the
major version — Homebrew has one `tippecanoe` formula and it moves when
Homebrew decides — so the pipeline ran against whatever the developer's last
`brew upgrade` produced, and the hook's fallback path could trigger a
`brew update` in the middle of `cd`-ing into the repo.

An exact version, resolved by `mise` from a pinned tarball, replaces all of it.

## The design decision

Same shape as [`gdal`](../gdal), arrived at far more cheaply: **SQLite and zlib
are compiled as static archives and linked into each binary.** tippecanoe has no
library, no plugins and no resource files, so the tarball is six executables and
a man page that depend on nothing but the platform's own C/C++ runtime.

```
linux    libpthread.so.0  libdl.so.2  libm.so.6  libc.so.6  ld-linux
macOS    libSystem.B.dylib  libc++.1.dylib
```

Two consequences worth knowing:

- **No `[env]` block for consumers.** Unlike `gdal`, which needs `GDAL_DATA` to
  find its resource files and `LDFLAGS` for the Python bindings' rpath,
  tippecanoe reads nothing from the environment and nothing compiles against it.
  Putting `bin/` on `PATH` — which `mise` does — is the whole integration.
  `smoke-test.sh` runs every check with `PATH` reduced to `/usr/bin:/bin` and the
  library-path variables unset, so that claim is tested rather than assumed.
- **zlib is built rather than borrowed.** macOS ships `/usr/lib/libz.1.dylib`, so
  linking the platform's would work there — but on Linux `libz.so.1` is not part
  of glibc, and a dynamic dependency on it would break the "links only platform
  libraries" property on exactly one of the three targets. Static zlib costs
  about 100 KB and keeps one recipe for both.

  This is also the one case where the platform allowlist cannot catch a
  regression on its own: `/usr/lib/libz.1.dylib` *is* a platform library on
  macOS, so a zlib that silently linked dynamically would pass. `smoke-test.sh`
  therefore names `libz` and `libsqlite3` explicitly, in addition to the
  allowlist.

### Pinning by commit SHA

Every other input in this repository is pinned as *URL + SHA256* of a published
release tarball. tippecanoe cannot be, and the substitute is a commit SHA:

```
TIPPECANOE_VERSION=2.79.0
TIPPECANOE_COMMIT=68ab8dcc229f95b8b25877697d5e8d66783af503
```

`felt/tippecanoe` attaches **no assets to its releases** — the only tarball on
offer is the archive GitHub generates from the tag on demand. Those archives are
not stored, they are re-created per request, and their bytes are not guaranteed
stable: GitHub changed archive generation in early 2023 and invalidated
published checksums across the ecosystem. A pin whose verification can start
failing for reasons unrelated to the source is worse than no pin, because it
fails at the moment you most need the old version to rebuild.

A commit SHA has the property the checksum was there to provide. It is
content-addressed by git over the whole tree and history, so it cannot drift,
and unlike the tag it names, it cannot be moved. `build.sh` shallow-clones the
tag and then makes two checks:

1. `git rev-parse HEAD` must equal `TIPPECANOE_COMMIT`. A moved or re-cut tag
   fails here.
2. The source's own `version.hpp` — `#define VERSION "v2.79.0"` — must agree
   with `TIPPECANOE_VERSION`. This catches the other direction: a commit SHA
   updated to match a tag that turned out to be a different release.

The trade is that the source is re-cloned rather than restored from cache. That
costs about six seconds, and it means the SHA is verified against a fresh fetch
from upstream on every single build, rather than against a cache entry. The
`work/cache` cache still covers the SQLite and zlib tarballs.

## Consuming it

```toml
# mise.toml
[tool_alias]                       # not [alias] — that spelling is deprecated
tippecanoe = "github:spear-ai/dist"

[tools]
tippecanoe = { version = "2.79.0.1787749444", version_prefix = "tippecanoe-v", asset_pattern = "tippecanoe-{{ version }}-{{ os() }}-{{ arch() }}.tar.gz" }
```

No `[env]` entries. See above.

## Building locally

```shell
./build.sh                 # ~2 min cold; writes work/dist/tippecanoe-<ver>-<platform>.tar.gz
                           # macos-arm64:  3.5 MB packed,  7 MB installed
                           # linux-arm64:  6.3 MB packed, 13 MB installed
./smoke-test.sh            # structural + functional checks
```

`work/` is disposable. The SQLite and zlib tarballs are cached in `work/cache`
and re-verified against their checksums on every run; tippecanoe is re-cloned
and re-verified against its commit SHA.

To check the Linux build from a macOS host:

```shell
docker run --rm -v "$PWD/../..:/repo" -w /repo/packages/tippecanoe \
  quay.io/pypa/manylinux_2_28_aarch64 \
  bash -c 'git config --global --add safe.directory /repo;
           WORK_DIR=/repo/packages/tippecanoe/work-linux ./build.sh &&
           WORK_DIR=/repo/packages/tippecanoe/work-linux ./smoke-test.sh work-linux/out'
```

Local Docker is not a faithful stand-in for a Linux runner on file ownership:
OrbStack and Docker Desktop map the host uid to root inside the container, so
git's `dubious ownership` check never fires there and the workflow's
`safe.directory` step looks unnecessary. It is not — see `tippecanoe.yml`.

## Releasing

1. Bump `TIPPECANOE_VERSION` and `TIPPECANOE_COMMIT` in `versions.env` (the
   weekly `tippecanoe-upstream` workflow opens this PR for you). CI builds and
   smoke-tests the PR on all three platforms.
2. Tag the merged commit and push:

   ```shell
   git tag "tippecanoe-v$(packages/tippecanoe/dist-version.sh)"
   ```

3. The workflow refuses to release if the tag and the commit disagree, then
   produces all three tarballs, smoke-tests each, attaches `SHA256SUMS`, and
   attests build provenance — which `mise` verifies by default.

### Version scheme

A release is `<tippecanoe version>.<commit timestamp>`, exactly as in
[`gdal`](../gdal#version-scheme):

```console
$ packages/tippecanoe/dist-version.sh
2.79.0.1787749444
```

Both packages' `dist-version.sh` read the timestamp of the repository's `HEAD`,
so they return the same revision on the same commit. That is not a bug and does
not need fixing with a path filter: nothing auto-tags here, so a package's
version only materialises when it is deliberately tagged, and a tag names one
package. Filtering by path would also require `fetch-depth: 0`, trading a real
cost for a cosmetic one.

## What is deliberately not included

**`unit`, the test harness.** `make install` builds exactly the six shipped
binaries; a plain `make` would also build `unit`, which nothing ships. The
upstream test suite is not run here — it needs Node and `geobuf` — and
`smoke-test.sh` covers the shape this distribution promises instead.

**The `docs` target.** `man/tippecanoe.1` is checked into upstream and shipped
as-is. Regenerating it needs `md2man-roff`, and `make install` does not evaluate
that rule, so nothing here requires Ruby.

Three upstream quirks are worked around in `build.sh`, each commented there:

- **`LIBS` and `INCLUDES` are assigned with plain `=`,** to `-L/usr/local/lib`
  and `-I/usr/local/include` — which is where Homebrew installs on Intel macOS,
  and `-I/usr/local/include` is listed *ahead of* `-I.`. Left alone, the build
  picks up whatever SQLite the runner happens to have. Both are overridden on
  the `make` command line, which is the only assignment that wins against `=`.
  `INCLUDES` must keep `-I.` and `-Iclipper2/include`.
- **`CFLAGS`/`CXXFLAGS` must go through the environment, not the command line.**
  The Makefile *appends* to them (`CXXFLAGS := $(CXXFLAGS) -std=c++17 -fPIE`),
  and a command-line assignment would replace that and drop `-std=c++17`.
- **`tippecanoe-enumerate`'s link line ends in a bare `-lsqlite3`,** where the
  other five end in `-lpthread`. Static SQLite calls `pthread_*` and `dl*`, and
  on glibc 2.28 those are still in `libpthread.so`/`libdl.so` rather than libc
  (merged in 2.34), so the build fails on one binary, on Linux only — macOS has
  both in libSystem. `build.sh` adds `-lpthread -ldl` on Linux.

**The C++ runtime is linked statically on Linux, and `gdal` links it
dynamically.** That divergence is deliberate and is commented in both
`build.sh` files. `libgdal` shares a process with the PyPI bindings' `_gdal.so`,
which links `libstdc++` dynamically; a private runtime inside `libgdal` would
mean two of them and exceptions that fail to match across the boundary.
tippecanoe ships standalone executables — nothing links or loads them, so there
is no boundary, and static removes the `libstdc++` version floor from the
tarball entirely.

## Licensing

tippecanoe is BSD-2-Clause, SQLite is public domain, zlib is the Zlib licence.
All three are permissive, so unlike `gdal` — which statically links LGPL GEOS
and therefore engages LGPL-2.1 section 6 — there is no relinking provision to
satisfy. A `LICENSES.md` naming each component ships inside the tarball.

## Runner notes

`linux-arm64` uses the `ubuntu-24.04-arm` runner, which is free for public
repositories and requires a paid plan for private ones.
