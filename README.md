<img src=".github/assets/logo.png" alt="" width="64">  

`dist/*`

Prebuilt distributions published as GitHub releases. When none exist for no good reason.

| Name | Version | Platforms |
| --- | --- | --- |
| [GDAL]([packages/gdal](https://gdal.org/en/stable/)) | 3.13.2 | `linux-arm64`, `linux-x64`, `macos-arm64` |
| [tippecanoe]([packages/tippecanoe](https://github.com/mapbox/tippecanoe)) | 2.79.0 | `linux-arm64`, `linux-x64`, `macos-arm64` |

## Conventions

**Tags are `<package>-v<version>`** — `gdal-v3.13.2`. A bare `v3.13.2` becomes
ambiguous the moment a second package exists, and mise reads the prefix back
off with `version_prefix`.

**Assets are `<package>-<version>-<os>-<arch>.tar.gz`**, where `<os>` and
`<arch>` are exactly what mise's `{{os()}}` and `{{arch()}}` render to
(`macos`/`linux`, `arm64`/`x64`), so one `asset_pattern` covers every platform.

Every package provides the same five files:

| File | Purpose |
| --- | --- |
| `versions.env` | Every input pinned — the single source of truth for what a tag builds |
| `build.sh` | Reproduces the release tarball for the host platform |
| `smoke-test.sh` | Asserts the result is self-contained, relocatable and functional; non-zero exit on any failure |
| `dist-version.sh` | Prints the version this commit releases as; `build.sh` and the workflow both call it, so they cannot disagree |
| `README.md` | The design decisions, and what was deliberately left out |

Inputs are pinned by URL + SHA256 wherever upstream publishes a release
tarball, which is the normal case. `tippecanoe` is the exception: its upstream
attaches no release assets, so it is pinned by commit SHA instead — see
[that package's README](packages/tippecanoe#pinning-by-commit-sha) for why a
regenerable archive's checksum is the weaker pin.

`dist-version.sh` is duplicated per package rather than shared at the root. It
is twenty lines, and the copies differ only in which variable they read from
`versions.env`. Factoring it up would give every caller — `build.sh`, both
workflows, and the `git tag` line in each README — a package argument to pass,
in exchange for removing one line of real duplication. Revisit at the point
where the copies start disagreeing about something that matters, not before.

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
gdal = { version = "3.13.2", version_prefix = "gdal-v", asset_pattern = "gdal-{{ version }}-{{ os() }}-{{ arch() }}.tar.gz" }
```

`version_prefix` is what lets several packages share one repository: mise lists
only `gdal-v*` tags as versions for this tool and strips the prefix, so
`mise ls-remote gdal` shows `3.13.2`.

## Keeping consumers up to date with Renovate

Renovate's mise manager cannot see a `[tool_alias]` entry — it resolves bare tool
names against mise's public registry — so consumers need one `customManager`
**per package**, and each **must** set `versioningTemplate: "loose"`:

```json
{
  "customType": "regex",
  "datasourceTemplate": "github-releases",
  "depNameTemplate": "spear-ai/dist",
  "managerFilePatterns": ["(^|/)mise\\.toml$"],
  "matchStrings": ["gdal = \\{ version = \"(?<currentValue>[^\"]+)\""],
  "extractVersionTemplate": "^gdal-v(?<version>.+)$",
  "versioningTemplate": "loose"
}
```

Renovate's default is `semver-coerced`, which coerces `3.13.2.1` to `3.13.2` and
so compares a build revision as **equal** to the version it rebuilds — meaning
those releases would never produce a PR, silently and forever. `loose` orders
them correctly and still derives major/minor/patch from the first three
components, so `matchUpdateTypes` rules keep working.

`extractVersion` is what keeps the packages apart. All of them share one
`github-releases` datasource — `spear-ai/dist` — so without it a consumer
pinning `gdal` would be offered `tippecanoe-v2.79.0.…` as an upgrade. The
regex filters the tag list down to one package's tags and strips the prefix,
so `gdal-v*` and `tippecanoe-v*` never contaminate each other's version lists.
A second package means a second block, identical but for the two `tippecanoe`
strings:

```json
{
  "customType": "regex",
  "datasourceTemplate": "github-releases",
  "depNameTemplate": "spear-ai/dist",
  "managerFilePatterns": ["(^|/)mise\\.toml$"],
  "matchStrings": ["tippecanoe = \\{ version = \"(?<currentValue>[^\"]+)\""],
  "extractVersionTemplate": "^tippecanoe-v(?<version>.+)$",
  "versioningTemplate": "loose"
}
```

A rebuild and an upstream patch both classify as `patch`. To treat them
differently, match on shape instead:
`"matchNewValue": "/^\\d+\\.\\d+\\.\\d+\\.\\d+$/"` is a rebuild.

## Adding a package

1. Create `packages/<name>/` with the five files above. `build.sh` should
   resolve its own directory rather than assume a working directory, so it runs
   from anywhere.
2. Copy `.github/workflows/gdal.yml` to `<name>.yml`; change the tag filter,
   the `paths` filter, the `working-directory`, the concurrency group, and the
   cache key. Same for `gdal-upstream.yml`.
3. Add a row to the table above.
4. Give each consumer a `customManager` of its own, as above.
5. Tag `<name>-v<version>` to publish.

Two things bite in the workflow that do not bite locally. Actions selects `sh`
inside a container, so keep `defaults: run: { shell: bash }` and source files
by path (`. ./versions.env`, never `source versions.env`, which searches
`$PATH`). And a container job needs
`git config --global --add safe.directory "$GITHUB_WORKSPACE"` after checkout,
because checkout writes its own entry under a temporarily overridden `HOME`
that later steps do not see — `dist-version.sh` needs git. Neither reproduces
under Docker on macOS, which maps the host uid to root.
