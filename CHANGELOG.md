# Changelog

All notable changes to Lemmy Migrator are documented in this file.

## [0.1] - 2026-08-19

### Added

- Export and import of community subscriptions between Lemmy instances.
- Support for Lemmy API v3 and v4, password login, and Bearer tokens.
- Dry-run, confirmation, debug, custom export directory, and resumable imports.
- Automatic retries for HTTP 429, HTTP 5xx, and transient curl failures, with configurable exponential backoff.
- A dependency-free regression test suite.

### Fixed

- Scope import resume state to the target instance so migrations to multiple targets do not interfere with one another ([#1](https://github.com/netherwraith/lemmy-migrator/issues/1)).
- Reject malformed paginated responses and repeated API v4 cursors instead of silently producing incomplete exports ([#2](https://github.com/netherwraith/lemmy-migrator/issues/2)).
- Retry rate-limited and transient API requests while respecting numeric `Retry-After` headers ([#3](https://github.com/netherwraith/lemmy-migrator/issues/3)).
- Reject missing, empty, and invalid CLI or retry-configuration values with actionable errors ([#4](https://github.com/netherwraith/lemmy-migrator/issues/4)).

[0.1]: https://github.com/netherwraith/lemmy-migrator/releases/tag/v0.1
