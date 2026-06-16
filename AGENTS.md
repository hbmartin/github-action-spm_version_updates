# Verification

After completing a task, always run `bundle exec rubocop --format simple; bundle exec reek --format text; bundle exec rspec`
rubocop and reek must pass checks before work can be considered complete.

## Code Style and Structure

If there is any conflict between the below guidelines and the rubocop or reek checks, stop and ask the user which style they prefer. Then Update either AGENTS.md or the tool configuration to reflect the user's preference.

### Ruby Conventions

- Write concise, idiomatic Ruby code with accurate examples
- Use object-oriented and functional programming patterns as appropriate
- Prefer iteration and modularization over code duplication
- Prefer double-quoted strings unless you need single quotes to avoid extra backslashes for escaping

### Naming Conventions

- Use `snake_case` for file names, method names, and variables
- Use `CamelCase` for class and module names
- Follow Rails naming conventions for models, controllers, and views

### Meaningful Names

- Variables, functions, and classes should reveal their purpose
- Names should explain why something exists and how it's used
- Avoid abbreviations unless they're universally understood

### Single Responsibility

- Each function should do exactly one thing
- Functions should be small and focused
- If a function needs a comment to explain what it does, it should be split
