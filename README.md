# dist

Prebuilt, self-contained toolchains published as GitHub releases for `mise`.

Each distribution lives under `packages/` and owns its build recipe, its pinned
inputs, and its tests. Packages are tagged and released independently.

## Packages

| Package | Version | Platforms |
| --- | --- | --- |
| [gdal](packages/gdal) | 3.13.2 | `macos-arm64`, `linux-arm64`, `linux-x64` |

## Conventions

**Tags are `<package>-v<version>`** — `gdal-v3.13.2`. A bare `v3.13.2` becomes
ambiguous the moment a second package exists, and mise reads the prefix back
off with `version_prefix`.

**Assets are `<package>-<version>-<os>-<arch>.tar.gz`**, where `<os>` and
`<arch>` are exactly what mise's `{{os()}}` and `{{arch()}}` render to
(`macos`/`linux`, `arm64`/`x64`), so one `asset_pattern` covers every platform.

Every package provides the same four files:

| File | Purpose |
| --- | --- |
| `versions.env` | Every input pinned by version and SHA256 — the single source of truth for what a tag builds |
| `build.sh` | Reproduces the release tarball for the host platform |
| `smoke-test.sh` | Asserts the result is self-contained, relocatable and functional; non-zero exit on any failure |
| `README.md` | The design decisions, and what was deliberately left out |

Workflows must live at the repository root, so they are named per package:
`.github/workflows/<package>.yml` builds, tests and releases on a
`<package>-v*` tag, and also runs on pull requests touching
`packages/<package>/**` so a version bump is proven before it is tagged.
`<package>-upstream.yml` opens that bump PR on a schedule.

## Consuming

```toml
# mise.toml
[tool_alias]                       # not [alias] — that spelling is deprecated
gdal = "github:spear-ai/dist"

[tools]
gdal = { version = "3.13.2", version_prefix = "gdal-v", asset_pattern = "gdal-{{version}}-{{os()}}-{{arch()}}.tar.gz" }
```

`version_prefix` is what lets several packages share one repository: mise lists
only `gdal-v*` tags as versions for this tool and strips the prefix, so
`mise ls-remote gdal` shows `3.13.2`.

Releases carry GitHub build provenance attestations, which mise verifies by
default.

## Adding a package

1. Create `packages/<name>/` with the four files above. `build.sh` should
   resolve its own directory rather than assume a working directory, so it runs
   from anywhere.
2. Copy `.github/workflows/gdal.yml` to `<name>.yml`; change the tag filter,
   the `paths` filter, the `working-directory`, and the cache key.
3. Add a row to the table above.
4. Tag `<name>-v<version>` to publish.
