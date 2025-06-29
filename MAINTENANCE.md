# Maintenance Guide

This document provides instructions for maintaining, developing, and releasing the SPM Version Updates GitHub Action.

## Development Setup

### Prerequisites

- Docker installed and running
- Ruby 3.3+ (for local development)
- Git
- GitHub CLI (`gh`) for release management

### Local Development

1. **Clone the repository**:
   ```bash
   git clone https://github.com/hbmartin/spm-version-updates-action.git
   cd spm-version-updates-action
   ```

2. **Install dependencies**:
   ```bash
   bundle install
   ```

3. **Run tests**:
   ```bash
   bundle exec rspec
   ```

4. **Build Docker image**:
   ```bash
   docker build -t spm-version-updates-action .
   ```

5. **Test locally with fixture**:
   ```bash
   docker run --rm -v $(pwd):/workspace \
     -e GITHUB_WORKSPACE=/workspace \
     spm-version-updates-action \
     spec/support/fixtures/UpToNextMajor.xcodeproj false false false ""
   ```

## Code Structure

### Core Files

- **`lib/action.rb`** - Main entry point and argument parsing
- **`lib/spm_checker.rb`** - Core SPM version checking logic
- **`lib/git_operations.rb`** - Git operations for version discovery
- **`lib/xcode_parser.rb`** - Xcode project and Package.resolved parsing
- **`lib/github_integration.rb`** - GitHub API integration and PR comments
- **`action.yml`** - GitHub Action metadata and configuration
- **`Dockerfile`** - Container configuration
- **`entrypoint.sh`** - Container entry point script

### Test Files

- **`spec/spm_version_updates_spec.rb`** - Main test suite
- **`spec/support/fixtures/`** - Test Xcode projects and Package.resolved files

## Making Changes

### Code Changes

1. **Create a feature branch**:
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes** to the Ruby files in `lib/`

3. **Update tests** in `spec/` if needed

4. **Test your changes**:
   ```bash
   bundle exec rspec
   docker build -t spm-version-updates-action .
   # Test with fixture projects
   ```

5. **Update documentation** if adding new features or changing behavior

### Adding New Features

1. **Update `action.yml`** if adding new input parameters
2. **Update `lib/action.rb`** to handle new arguments
3. **Add appropriate logic** to core modules
4. **Add tests** for new functionality
5. **Update README.md** with new configuration options

### Docker Image Changes

1. **Modify `Dockerfile`** for dependency changes
2. **Update `Gemfile`** for Ruby gem changes
3. **Test image builds** on multiple architectures if needed:
   ```bash
   docker buildx build --platform linux/amd64,linux/arm64 -t test .
   ```

## Testing

### Unit Tests

```bash
# Run all tests
bundle exec rspec

# Run specific test file
bundle exec rspec spec/spm_version_updates_spec.rb

# Run with coverage
bundle exec rspec --format documentation
```

### Integration Testing

```bash
# Test with real Xcode project
docker run --rm -v /path/to/real/project:/workspace \
  -e GITHUB_WORKSPACE=/workspace \
  spm-version-updates-action \
  MyApp.xcodeproj false false false ""
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
   - Update any version strings in documentation
   - Update README examples to use new version

2. **Test thoroughly**:
   - Run full test suite: `bundle exec rspec`
   - Build and test Docker image
   - Test with real Xcode projects
   - Test in actual GitHub Actions environment

3. **Update documentation**:
   - Update CHANGELOG.md with new features/fixes
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

2. **Update CHANGELOG.md**:
   ```markdown
   ## [1.2.0] - 2024-XX-XX
   ### Added
   - New feature description
   ### Fixed
   - Bug fix description
   ### Changed
   - Breaking change description
   ```

3. **Commit changes**:
   ```bash
   git add .
   git commit -m "Prepare release v1.2.0"
   git push origin release/v1.2.0
   ```

4. **Create Pull Request** for review

5. **After PR approval and merge**, create the release:
   ```bash
   git checkout main
   git pull origin main
   git tag v1.2.0
   git push origin v1.2.0
   ```

6. **Create GitHub Release**:
   ```bash
   gh release create v1.2.0 \
     --title "v1.2.0 - Release Title" \
     --notes-file CHANGELOG.md \
     --draft=false \
     --prerelease=false
   ```

### Post-Release Tasks

1. **Update major version tag** (for major/minor releases):
   ```bash
   # For v1.2.0, update v1 tag
   git tag -d v1
   git push origin :refs/tags/v1
   git tag v1
   git push origin v1
   ```

2. **Verify marketplace listing**:
   - Check that the action appears correctly in [GitHub Marketplace](https://github.com/marketplace)
   - Verify all metadata and descriptions are correct

3. **Test the released version**:
   ```yaml
   - uses: hbmartin/spm-version-updates-action@v1.2.0
   ```

## GitHub Marketplace

### Initial Publication

1. **Ensure action.yml is properly configured**:
   ```yaml
   name: 'SPM Version Updates'
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

1. **Docker build fails**:
   - Check Dockerfile syntax
   - Verify all files are copied correctly
   - Ensure native gem dependencies are installed

2. **Tests fail**:
   - Check fixture files haven't been corrupted
   - Verify Ruby version compatibility
   - Check for dependency version conflicts

3. **Action doesn't work in GitHub**:
   - Verify action.yml syntax
   - Check Docker image builds successfully
   - Ensure all required files are included in repository

### Debug Mode

Enable debug output by setting environment variables:
```bash
DEBUG=true docker run --rm spm-version-updates-action ...
```

### Docker Issues

```bash
# Clean build (no cache)
docker build --no-cache -t spm-version-updates-action .

# Debug container
docker run --rm -it --entrypoint /bin/sh spm-version-updates-action

# Check container size
docker images spm-version-updates-action
```

## Security Considerations

### Dependencies

- **Regularly update Ruby gems**: `bundle update`
- **Monitor security advisories**: Use `bundle audit`
- **Keep base Docker image updated**: Update Ruby version in Dockerfile

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
- **Maintain CHANGELOG.md** with all changes
- **Provide migration guides** for breaking changes

This maintenance guide should be updated as the project evolves and new processes are established.