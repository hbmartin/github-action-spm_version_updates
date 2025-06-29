# SPM Version Updates GitHub Action

[![CI](https://github.com/hbmartin/danger-spm_version_updates/actions/workflows/lint_and_test.yml/badge.svg)](https://github.com/hbmartin/danger-spm_version_updates/actions/workflows/lint_and_test.yml)
[![CodeFactor](https://www.codefactor.io/repository/github/hbmartin/danger-spm_version_updates/badge/main)](https://www.codefactor.io/repository/github/hbmartin/danger-spm_version_updates/overview/main)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A GitHub Action to automatically detect and report available updates for your Swift Package Manager (SPM) dependencies in Xcode projects.

🚀 **Fast, lightweight, and works without Swift installed on your CI runner**

## Features

- ✅ **Zero Configuration** - Just point it at your Xcode project
- 📦 **Comprehensive Detection** - Supports all SPM dependency constraint types
- 💬 **Smart PR Comments** - Creates and updates informative pull request comments
- 🔧 **Highly Configurable** - Control exactly what updates to report
- 🏃‍♂️ **Performance Optimized** - Docker container with minimal dependencies
- 📋 **Package.resolved Support** - Works with both v1 and v2 formats

## Quick Start

Add this action to your GitHub workflow:

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
      - uses: hbmartin/spm-version-updates-action@v1
        with:
          xcode-project-path: 'MyApp.xcodeproj'
```

## Configuration Options

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `xcode-project-path` | Path to your Xcode project file (.xcodeproj) | ✅ Yes | |
| `check-when-exact` | Check for updates even when using exact version constraints | No | `false` |
| `report-above-maximum` | Report versions above the maximum constraint range | No | `false` |
| `report-pre-releases` | Include pre-release versions in update reports | No | `false` |
| `ignore-repos` | Comma-separated list of repository URLs to ignore | No | `''` |
| `github-token` | GitHub token for API access | No | `${{ github.token }}` |

## Advanced Configuration

```yaml
- uses: hbmartin/spm-version-updates-action@v1
  with:
    xcode-project-path: 'MyApp.xcodeproj'
    check-when-exact: true
    report-above-maximum: true
    report-pre-releases: false
    ignore-repos: 'https://github.com/pointfreeco/swift-snapshot-testing,https://github.com/Quick/Nimble'
```

## Supported Dependency Types

The action supports all SPM dependency constraint types:

- **Exact Version** (`exactVersion`) - Reports updates when `check-when-exact` is enabled
- **Up to Next Major** (`upToNextMajorVersion`) - Reports compatible updates within major version
- **Up to Next Minor** (`upToNextMinorVersion`) - Reports compatible updates within minor version  
- **Version Range** (`versionRange`) - Reports updates within specified range
- **Branch Tracking** (`branch`) - Reports newer commits on tracked branches

## Example Output

When the action finds available updates, it will post a comment like this on your pull request:

> ## 📦 SPM Version Updates
> 
> ⚠️ **Found 2 potential dependency updates:**
> 
> 1. Newer version of Alamofire/Alamofire: 5.8.1
> 2. Newer version of onevcat/Kingfisher: 7.10.2
> 
> <details>
> <summary>💡 How to update dependencies</summary>
> 
> To update your SPM dependencies:
> 1. Open your Xcode project
> 2. Go to **File → Swift Packages → Update to Latest Package Versions**
> 3. Or update individual packages from the Package Dependencies section in Project Navigator
> 
> </details>

## Complete Workflow Example

```yaml
name: Swift Package Dependencies

on:
  pull_request:
    paths:
      - '**/*.xcodeproj/**'
      - '**/Package.resolved'
      - '.github/workflows/spm-updates.yml'

jobs:
  check-dependencies:
    name: Check for SPM Updates
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        
      - name: Check SPM Dependencies
        uses: hbmartin/spm-version-updates-action@v1
        with:
          xcode-project-path: 'MyApp.xcodeproj'
          report-above-maximum: true
          ignore-repos: 'https://github.com/pointfreeco/swift-snapshot-testing'
```

## Migration from Danger Plugin

If you're migrating from the `danger-spm_version_updates` Danger plugin, see [MIGRATION_PLAN.md](MIGRATION_PLAN.md) for a detailed migration guide.

## Development

To work on this action locally:

1. Clone this repository
2. Make your changes to the Ruby files in `lib/`
3. Build the Docker image: `docker build -t spm-version-updates-action .`
4. Test with a sample project: `docker run --rm -v $(pwd):/workspace spm-version-updates-action path/to/project.xcodeproj`

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
