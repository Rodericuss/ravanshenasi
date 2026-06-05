# Contributing to Ravanshenasi

First off, thank you for taking the time to contribute! Contributions are what make the open-source and developer communities such an amazing place to learn, inspire, and create.

All types of contributions are encouraged and valued. Please make sure to read the relevant sections before making your contribution.

---

## Code of Conduct

This project and everyone participating in it is governed by the [Ravanshenasi Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code. Please report unacceptable behavior to **conduct@ravanshenasi.com**.

## Development Setup

This is a Phoenix web application built using the Elixir programming language.

### Prerequisites

- Elixir 1.19+ and Erlang/OTP 26+
- PostgreSQL 17+ (with TimescaleDB extension if required by migrations)
- Node.js (for asset management if needed, though Phoenix v1.8 defaults to esbuild/tailwind)

### Getting Started

1. Clone the repository.
2. Install dependencies and set up the database:
   ```bash
   mix setup
   ```
3. Start the Phoenix server:
   ```bash
   mix phx.server
   ```
4. Run the test suite to ensure everything is working:
   ```bash
   mix test
   ```

## Development Guidelines

### Elixir Style and Quality

We use `credo` and the built-in code formatter to maintain code quality.
- **Formatting**: Before submitting changes, always format the code:
  ```bash
  mix format
  ```
- **Static Analysis**: Run Credo to check for code consistency:
  ```bash
  mix credo --strict
  ```
- **Precommit Checks**: We have a bundled pre-commit alias that runs formatting checks, Credo analysis, and the test suite:
  ```bash
  mix precommit
  ```
  Make sure `mix precommit` runs clean before submitting your contribution.

### Git Workflow and Branching

- We commit directly to `main` for simple contributions, or via Pull Requests.
- Please write **atomic commits** with logical groupings of files. Do not bundle unrelated modifications.

### Commit Message Guidelines

We follow the Conventional Commits specification, prefixed with a Gitmoji matching the type of change. Here are some examples:

- `✨ feat(live): status filter, framework edit/delete, patient inactivate`
- `🐛 fix(security): owner/tenant guards in patient-framework association`
- `📝 docs(spec): add slice 2 — sessions + SOAP notes design`
- `🎨 style: apply mix format to slice 1 files`
- `🔧 chore(deps): install Oban and migrate database`
- `🌐 docs(i18n): translate developer-facing comments to English`

Common prefixes:
- `✨ feat(...)`: A new feature
- `🐛 fix(...)`: A bug fix
- `📝 docs(...)`: Documentation changes
- `🎨 style(...)`: Code style adjustments (formatting, Credo refactors)
- `🔧 chore(...)`: Infrastructure/dependency configurations
- `🌐 docs/feat/fix(i18n):` Internationalization changes

## Reporting Issues

If you find a bug or have a suggestion, please use the [Issue templates](.github/ISSUE_TEMPLATE/) on GitHub to submit a structured report.

Thank you for contributing!
