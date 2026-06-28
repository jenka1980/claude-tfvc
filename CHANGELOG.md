# Changelog

All notable changes to this project are documented here. Versioning follows [SemVer](https://semver.org/).

## [0.1.1] - 2026-06-28
### Fixed
- Plugin failed to load with "Duplicate hooks file detected": the manifest's `hooks` key pointed at the
  standard `hooks/hooks.json`, which Claude Code already loads automatically. Removed the redundant `hooks`
  reference from `plugin.json`; the auto-checkout hook still loads from its standard location.

## [0.1.0] - 2026-06-11
### Added
- Initial release.
- `tfvc` knowledge skill (read-only/checkout model, `tf.exe` resolution, status/checkout/checkin/get/undo,
  local-vs-server workspace and `.tfignore` guidance, "use tf, not git" rules).
- Slash commands: `/tf-status`, `/tf-checkout`, `/tf-checkin`, `/tf-get`, `/tf-undo`.
- Guarded `PreToolUse` auto-checkout hook for `Edit`/`Write` (acts only on read-only files; never blocks edits).
