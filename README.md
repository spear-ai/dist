<img src=".github/assets/logo.png" alt="" width="64">

`dist/*`

Prebuilt distributions (binaries, library, toolchains, etc.) published as GitHub releases.  
For things that should have existed already, but don’t.

| Name                                               | Version | Platforms                                 |
| -------------------------------------------------- | ------- | ----------------------------------------- |
| [GDAL](https://gdal.org/en/stable)                 | 3.13.2  | `linux-arm64`, `linux-x64`, `macos-arm64` |
| [tippecanoe](https://github.com/mapbox/tippecanoe) | 2.79.0  | `linux-arm64`, `linux-x64`, `macos-arm64` |

<small>Distributions follow upstream version numbers appended by a timestamp. e.g., `upstream@1.2.3` -> `upstream-v1.2.3.1787832000`</small>

## mise

For usage with [mise](https://mise.jdx.dev) to manage dev tooling.

**mise.toml**

```toml
#:schema https://mise.jdx.dev/schema/mise.json

[env]
GDAL_DATA = { value = "{{ tools.gdal.path }}/share/gdal", tools = true }
LDFLAGS = { value = "${LDFLAGS:-} -Wl,-rpath,{{ tools.gdal.path }}/lib", tools = true }

[tool_alias]
gdal = "github:spear-ai/dist"
tippecanoe = "github:spear-ai/dist"

[tools]
gdal = { version = "X.X.X", version_prefix = "gdal-v", asset_pattern = "gdal-{{ version }}-{{ os() }}-{{ arch() }}.tar.gz" }
tippecanoe = { version = "X.X.X", version_prefix = "tippecanoe-v", asset_pattern = "gdal-{{ version }}-{{ os() }}-{{ arch() }}.tar.gz" }
```

## Renovate

For usage with [Renovate](https://github.com/renovatebot/renovate) to manage dependency updates.

**renovate.json**

```jsonc
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "customManagers": [
    {
      "description": "GitHub releases at `github:spear-ai/dist` are tagged as `<dependency-name>-v<major>.<minor>.<patch>.<timestamp>`.",
      "customType": "regex",
      "datasourceTemplate": "github-releases",
      "extractVersionTemplate": "^{{{depName}}}-v(?<version>.+)$",
      "managerFilePatterns": ["(^|/)mise\\.toml$"],
      "matchStrings": [
        "version = \"(?<currentValue>[^\"]+)\", version_prefix = \"(?<depName>[\\w-]+)-v\"",
      ],
      "packageNameTemplate": "spear-ai/dist",
      "versioningTemplate": "loose",
    },
  ],
}
```
