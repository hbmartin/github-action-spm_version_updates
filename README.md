# SPM Version Updates GitHub Action

[![CI](https://github.com/hbmartin/danger-spm_version_updates/actions/workflows/lint_and_test.yml/badge.svg)](https://github.com/hbmartin/danger-spm_version_updates/actions/workflows/lint_and_test.yml)
[![CodeFactor](https://www.codefactor.io/repository/github/hbmartin/danger-spm_version_updates/badge/main)](https://www.codefactor.io/repository/github/hbmartin/danger-spm_version_updates/overview/main)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A GitHub Action to automatically detect and report available updates for your Swift Package Manager (SPM) dependencies.

🚀 **Fast, lightweight, and works without Swift or Xcode installed on your CI runner**

It works in two ways:

- **Xcode project mode** — dependencies declared as `XCRemoteSwiftPackageReference` objects inside an `.xcodeproj`.
- **Swift manifest mode** — dependencies declared in one or more `Package.swift` manifests (a SwiftPM-first / modular iOS layout).

## Features

- ✅ **Two source modes** — point it at an `.xcodeproj` **or** at your `Package.swift` manifests
- 📦 **Comprehensive Detection** — supports all SPM dependency constraint types
- 🧩 **Multiple manifests** — check several `Package.swift` files (e.g. app modules + build tools) in one run
- 💬 **Smart PR Comments** — creates and updates a single informative pull request comment
- 🔧 **Highly Configurable** — control exactly what updates to report
- 🏃 **Runs on `ubuntu-latest`** — no macOS runner, no Swift toolchain, no Xcode required
- 📋 **Package.resolved Support** — works with both v1 and v2 formats

## Quick Start

### Xcode project mode

```yaml
name: Check SPM Dependencies
on:
  pull_request:
    paths:
      - '**/*.xcodeproj/**'
      - '**/Package.resolved'

jobs:
  spm-updates:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
      - uses: hbmartin/github-action-spm_version_updates@v1
        with:
          xcode-project-path: 'MyApp.xcodeproj'
```

### Swift manifest mode

```yaml
name: Swift Package Version Updates
on:
  pull_request:
    paths:
      - 'Modules/Package.swift'
      - 'Modules/Package.resolved'
      - 'BuildTools/Package.swift'
      - 'BuildTools/Package.resolved'
  workflow_dispatch:

permissions:
  contents: read
  pull-requests: write

jobs:
  spm-version-updates:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hbmartin/github-action-spm_version_updates@v1
        with:
          package-manifest-paths: |
            Modules/Package.swift
            BuildTools/Package.swift
          report-above-maximum: true
```

No temporary Xcode project, no synthetic `Package.resolved`, no repo-specific parser.

## Source modes

You must provide **exactly one** of `xcode-project-path` or `package-manifest-paths`. Providing both (or neither) fails with a clear error.

### Xcode project mode (`xcode-project-path`)

- Opens the `.xcodeproj` and extracts its `XCRemoteSwiftPackageReference` objects.
- Locates `Package.resolved` in the Xcode-adjacent workspace locations:
  - `<Project>.xcworkspace/xcshareddata/swiftpm/Package.resolved`
  - `<Project>.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

Use this when the `.xcodeproj` directly owns its remote package references.

### Swift manifest mode (`package-manifest-paths`)

- Parses one or more `Package.swift` manifests and extracts their direct `.package(...)` dependencies.
- Reads the matching `Package.resolved` files and compares declared dependencies against resolved pins.
- For each manifest, the resolved file is inferred to sit next to it (e.g. `Modules/Package.swift` → `Modules/Package.resolved`). Override this with `package-resolved-paths`.
- Resolved pins from every file are merged by normalized repository URL, and each warning is annotated with the manifest it came from.

Manifest parsing is done with a lightweight, dependency-free scanner — **Swift is not required**, so the action runs on `ubuntu-latest`. The common declaration forms are supported:

```swift
.package(url: "https://github.com/foo/bar", from: "1.2.3")
.package(url: "https://github.com/foo/bar", exact: "1.2.3")
.package(url: "https://github.com/foo/bar", branch: "main")
.package(url: "https://github.com/foo/bar", revision: "abcdef")
.package(url: "https://github.com/foo/bar", "1.0.0"..<"2.0.0")
.package(url: "https://github.com/foo/bar", .upToNextMajor(from: "1.2.3"))
.package(url: "https://github.com/foo/bar", .upToNextMinor(from: "1.2.3"))
.package(url: "https://github.com/foo/bar", .exact("1.2.3"))
```

Local packages (`.package(path: ...)`) and commented-out declarations are ignored.

## Configuration Options

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `xcode-project-path` | Path to your Xcode project file (`.xcodeproj`). Provide this **or** `package-manifest-paths`. | One of the two | |
| `package-manifest-paths` | Newline-separated list of `Package.swift` paths. Provide this **or** `xcode-project-path`. | One of the two | |
| `package-resolved-paths` | Optional newline-separated list of `Package.resolved` paths. Defaults to a `Package.resolved` next to each manifest. | No | inferred |
| `check-when-exact` | Check for updates even when using `exact` version constraints | No | `false` |
| `check-branches` | Check for newer commits on branch-pinned dependencies | No | `true` |
| `check-revisions` | Report the latest tagged version for revision-pinned dependencies | No | `false` |
| `report-above-maximum` | Report versions above the maximum constraint range | No | `false` |
| `report-pre-releases` | Include pre-release versions in update reports | No | `false` |
| `ignore-repos` | Comma-separated list of repository URLs to ignore | No | `''` |
| `github-token` | GitHub token for API access | No | `${{ github.token }}` |

## How dependency constraints are handled

| Constraint | Manifest form | Behavior |
|------------|---------------|----------|
| Up to next major | `from:` / `.upToNextMajor(from:)` | Reports newer versions within the same major version. |
| Up to next minor | `.upToNextMinor(from:)` | Reports newer versions within the same minor version. |
| Version range | `"1.0.0"..<"2.0.0"` | Reports newer versions below the maximum. |
| Exact | `exact:` / `.exact(...)` | Skipped unless `check-when-exact: true`. |
| Branch | `branch:` / `.branch(...)` | Reports newer commits on the branch unless `check-branches: false`. |
| Revision | `revision:` / `.revision(...)` | Skipped unless `check-revisions: true`. A pinned commit has no general "newer" version, so when enabled the action only reports the latest tagged release for reference. |

When `report-above-maximum: true`, the action additionally reports the newest version that exists above the configured maximum (e.g. a new major release that your constraint would not pick up).

## Example output

When the action finds available updates, it posts (and keeps updating) a single comment on your pull request:

> ## 📦 SPM Version Updates
>
> ⚠️ **Found 2 potential dependency updates:**
>
> 1. Newer version of onevcat/Kingfisher: 8.0.0
>    Source: Modules/Package.swift
> 2. Newer version of SwiftGen/SwiftGenPlugin: 6.7.0
>    Source: BuildTools/Package.swift

The `Source:` line is only included in Swift manifest mode, where it tells you which manifest a given update applies to.

## Advanced configuration

```yaml
- uses: hbmartin/github-action-spm_version_updates@v1
  with:
    package-manifest-paths: |
      Modules/Package.swift
      BuildTools/Package.swift
    package-resolved-paths: |
      Modules/Package.resolved
      BuildTools/Package.resolved
    check-when-exact: true
    check-branches: true
    check-revisions: false
    report-above-maximum: true
    ignore-repos: 'https://github.com/pointfreeco/swift-snapshot-testing'
```

## Versioning

Pin to a major version tag so you automatically receive backward-compatible updates:

```yaml
uses: hbmartin/github-action-spm_version_updates@v1
```

You can also pin to an exact release (e.g. `@v1.0.0`) or to a commit SHA for maximum reproducibility.

## Development

To work on this action locally:

1. Clone this repository
2. Make your changes to the Ruby files in `lib/`
3. Run the action specs: `bundle exec ruby -e "require 'rspec/core'; exit RSpec::Core::Runner.run(['spec/action'])"`
4. Build the Docker image: `docker build -t spm-version-updates-action .`
5. Test against a sample project: `docker run --rm -v $(pwd):/workspace -e INPUT_XCODE_PROJECT_PATH=path/to/project.xcodeproj spm-version-updates-action`

## Authors

- [Harold Martin](https://www.linkedin.com/in/harold-martin-98526971/) - harold.martin at gmail

## Legal

Swift and the Swift logo are trademarks of Apple Inc.

Copyright (c) 2023-2024 Harold Martin

MIT License

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
