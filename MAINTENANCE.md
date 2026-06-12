# Maintenance Guide

This document provides instructions for maintaining, developing, and releasing the Swift Package Version Updates GitHub Action.

## Development Setup

### Prerequisites

- Ruby 3.3+ (for local development)
- Git
- GitHub CLI (`gh`) for release management

### Local Development

1. **Clone the repository**:

   ```bash
   git clone https://github.com/hbmartin/github-action-spm_version_updates.git
   cd github-action-spm_version_updates
   ```

2. **Install dependencies**:

   ```bash
   bundle install
   ```

3. **Run tests**:

   ```bash
   bundle exec rspec
   ```

4. **Test locally with fixture**:

   ```bash
   GITHUB_WORKSPACE="$(pwd)" \
     INPUT_XCODE_PROJECT_PATH=spec/support/fixtures/UpToNextMajor.xcodeproj \
     bundle exec ruby action/lib/action.rb
   ```

## Code Structure

The repository hosts three layered components: the core checker gem, the
Danger plugin gem that wraps it, and the composite GitHub Action that drives
it directly. Both gems are released from this repository in lockstep.

### Core gem (`gems/spm_version_updates/`)

- **`lib/spm_version_updates/spm_checker.rb`** - Core SPM version checking logic
- **`lib/spm_version_updates/git_operations.rb`** - Git operations for version discovery
- **`lib/spm_version_updates/xcode_parser.rb`** - Xcode project and Package.resolved parsing
- **`lib/spm_version_updates/version.rb`** - The single version constant for both gems

### Danger plugin gem (`gems/danger-spm_version_updates/`)

- **`lib/spm_version_updates/plugin.rb`** - The `Danger::DangerSpmVersionUpdates` plugin
- **`lib/danger_plugin.rb`** - Danger's plugin discovery entry point

### GitHub Action (`action/` + `action.yml`)

- **`action.yml`** - GitHub Action metadata and configuration (must stay at the repo root)
- **`action/lib/action.rb`** - Main entry point and argument parsing
- **`action/lib/github_integration.rb`** - GitHub API integration and PR comments
- **`action/Gemfile`** - Action runtime bundle; depends on the core gem by path

### Test Files

- **`spec/core/`** - Core checker specs (must pass with only the core gem's isolation bundle)
- **`spec/action/`** - Action, reporter, and GitHub integration specs
- **`spec/plugin/spm_version_updates_spec.rb`** - Danger plugin test suite
- **`spec/support/fixtures/`** - Test Xcode projects and Package.resolved files

## Making Changes

### Code Changes

1. **Create a feature branch**:

   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes** to the Ruby files in `gems/*/lib/` or `action/lib/`

3. **Update tests** in `spec/` if needed

4. **Test your changes**:

   ```bash
   bundle exec rspec
   GITHUB_WORKSPACE="$(pwd)" INPUT_XCODE_PROJECT_PATH=spec/support/fixtures/UpToNextMajor.xcodeproj bundle exec ruby action/lib/action.rb
   ```

5. **Update documentation** if adding new features or changing behavior

### Adding New Features

1. **Update `action.yml`** if adding new input parameters
2. **Update `action/lib/action.rb`** to handle new arguments
3. **Add appropriate logic** to core modules
4. **Add tests** for new functionality
5. **Update README.md** with new configuration options

### Runtime Dependency Changes

1. **Update the right Gemfile/gemspec**: `gems/*/​*.gemspec` for gem runtime
   dependencies, `action/Gemfile` for action runtime dependencies (mirror any
   action runtime change in the root `Gemfile`, which is the dev bundle)
2. **Run `bundle install`** at the root and `bundle lock` in `action/` to refresh both committed lockfiles
3. **Verify the manifest fast path** with `BUNDLE_WITHOUT=development:test:xcode`
4. **Verify the composite action** in a real GitHub Actions workflow so `ruby/setup-ruby` caching is exercised
5. **Verify `setup-ruby: false`** only after an earlier invocation has installed the same or a superset of runtime dependencies

## Testing

### Unit Tests

```bash
# Run all tests
bundle exec rspec

# Run specific test file
bundle exec rspec spec/plugin/spm_version_updates_spec.rb

# Prove the core gem stays free of danger/octokit dependencies
BUNDLE_GEMFILE=gems/spm_version_updates/Gemfile bundle install
BUNDLE_GEMFILE=gems/spm_version_updates/Gemfile bundle exec rspec spec/core

# Run with coverage
bundle exec rspec --format documentation
```

### Integration Testing

```bash
# Test with real Xcode project
GITHUB_WORKSPACE=/path/to/real/project \
  INPUT_XCODE_PROJECT_PATH=MyApp.xcodeproj \
  bundle exec ruby action/lib/action.rb
```

### GitHub Actions Testing

Create a test repository or use a branch to test the action in a real GitHub Actions environment:

```yaml
name: Test Action
on:
  push:
    branches: [ test-* ]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ./  # Use local action
        with:
          xcode-project-path: 'spec/support/fixtures/UpToNextMajor.xcodeproj'
```

## Release Process

### Version Strategy

This action follows semantic versioning:

- **Major (v2.0.0)**: Breaking changes to action interface or behavior
- **Minor (v1.1.0)**: New features, backward compatible
- **Patch (v1.0.1)**: Bug fixes, no interface changes

### Pre-Release Checklist

1. **Update version references**:
   - Bump `SpmVersionUpdates::VERSION` in `gems/spm_version_updates/lib/spm_version_updates/version.rb`
     (both gems release in lockstep from this single constant; the pushed tag must match it)
   - **Re-lock the action bundle in the same commit**: `cd action && bundle lock`
     (the frozen install on runners records the path gem's version, so a stale
     `action/Gemfile.lock` breaks every action run; CI's "Verify action lockfile
     matches gem version" step fails until the lockfile is refreshed)
   - Update any version strings in documentation
   - Update README examples to use new version

2. **Test thoroughly**:
   - Run full test suite: `bundle exec rspec`
   - Test the composite action in GitHub Actions
   - Test with real Xcode projects
   - Test in actual GitHub Actions environment

3. **Update documentation**:
   - Update README.md if needed
   - Update any version-specific documentation

### Creating a Release

1. **Prepare the release**:

   ```bash
   # Ensure you're on main branch
   git checkout main
   git pull origin main
   
   # Create release branch
   git checkout -b release/v1.2.0
   ```

2. **Commit changes**:

   ```bash
   git add .
   git commit -m "Prepare release v1.2.0"
   git push origin release/v1.2.0
   ```

3. **Create Pull Request** for review

4. **After PR approval and merge**, create the release:

   ```bash
   git checkout main
   git pull origin main
   git tag v1.2.0
   git push origin v1.2.0
   ```

   Pushing the tag triggers `push_gem.yml`, which verifies the tag against the
   version constant, then publishes `spm_version_updates` followed by
   `danger-spm_version_updates` to RubyGems via trusted publishing. Both gems
   need a trusted publisher registered on rubygems.org for this repository and
   workflow (a *pending* publisher must be registered before the first release
   of a new gem).

5. **Create GitHub Release**:

   ```bash
   gh release create v1.2.0 \
     --title "v1.2.0 - Release Title" \
     --generate-notes \
     --draft=false \
     --prerelease=false
   ```

   Publishing the release triggers `move_major_tag.yml`, which moves the
   floating major tag (e.g. `v1`) to the released commit. This runs off the
   release event — not the gem-publish workflow — so action users get the
   release even if RubyGems publishing fails. Prereleases and non-`vX.Y.Z`
   tags do not move the floating tag.

### Post-Release Tasks

1. **Verify the floating major tag moved** (automated by `move_major_tag.yml`):

   ```bash
   # Both should print the same commit for a v1.x.y release.
   git ls-remote origin refs/tags/v1 refs/tags/v1.2.0
   ```

2. **Verify marketplace listing**:
   - Check that the action appears correctly in [GitHub Marketplace](https://github.com/marketplace)
   - Verify all metadata and descriptions are correct

3. **Test the released version**:

   ```yaml
   - uses: hbmartin/github-action-spm_version_updates@v1
   ```

## GitHub Marketplace

### Initial Publication

1. **Ensure action.yml is properly configured**:

   ```yaml
   name: 'Swift Package Version Updates'
   description: 'Check for available updates to Swift Package Manager dependencies'
   author: 'hbmartin'
   branding:
     icon: 'package'
     color: 'orange'
   ```

2. **Create a release** following the process above

3. **Publish to marketplace**:
   - Go to your repository on GitHub
   - Click "Use this template" → "Publish to marketplace"
   - Fill in marketplace details
   - Submit for review

### Marketplace Updates

The marketplace automatically updates when you create new releases, but you may need to:

1. **Update marketplace metadata** if action.yml changes
2. **Update screenshots** or descriptions if the UI changes significantly
3. **Respond to user feedback** and marketplace reviews

## Troubleshooting

### Common Development Issues

1. **Tests fail**:
   - Check fixture files haven't been corrupted
   - Verify Ruby version compatibility
   - Check for dependency version conflicts

2. **Action doesn't work in GitHub**:
   - Verify action.yml syntax
   - Check that `ruby/setup-ruby` installed dependencies from this action directory
   - If `setup-ruby: false` is set, confirm an earlier action invocation in the same job ran with `setup-ruby: true`
   - Ensure all required files are included in repository

### Debug Mode

Enable debug output by setting environment variables:

```bash
DEBUG=true GITHUB_WORKSPACE="$(pwd)" INPUT_XCODE_PROJECT_PATH=MyApp.xcodeproj bundle exec ruby action/lib/action.rb
```

## Security Considerations

### Dependencies

- **Regularly update Ruby gems**: `bundle update`
- **Monitor security advisories**: Use `bundle audit`
- **Keep Ruby runtime updated**: Update `ruby-version` in `action.yml` and CI when needed

### GitHub Token Handling

- **Never log tokens**: Ensure no debug output includes GITHUB_TOKEN
- **Use minimal permissions**: Only request necessary GitHub API permissions
- **Handle token absence gracefully**: Action should work without token (no comments)

### User Input Validation

- **Validate file paths**: Prevent directory traversal attacks
- **Sanitize repository URLs**: Ensure they're valid git URLs
- **Limit input sizes**: Prevent resource exhaustion

## Monitoring and Analytics

### Usage Metrics

Monitor action usage through:

- GitHub repository insights
- Marketplace analytics
- GitHub API usage (if applicable)

### Error Tracking

- Monitor GitHub Actions logs for common failures
- Track issues opened against the repository
- Watch for patterns in support requests

## Support and Community

### Issue Management

1. **Label issues appropriately**: bug, enhancement, question, etc.
2. **Provide issue templates** for bug reports and feature requests
3. **Respond promptly** to user questions
4. **Create reproducible test cases** for reported bugs

### Documentation Maintenance

- **Keep README.md current** with latest features
- **Update examples** to reflect best practices
- **Keep GitHub Release notes accurate** for all user-facing changes
- **Provide migration guides** for breaking changes

This maintenance guide should be updated as the project evolves and new processes are established.
