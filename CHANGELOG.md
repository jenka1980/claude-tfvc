# Changelog

All notable changes to this project are documented here. Versioning follows [SemVer](https://semver.org/).

## [0.2.0] - 2026-09-23
### Changed
- The auto-checkout hook is launched with `powershell.exe` (Windows PowerShell 5.1, present on every Windows)
  instead of `pwsh` (PowerShell 7, a separate download). Machines without PowerShell 7 previously got a hook error
  on every edit and no checkout. The hook also runs `-NonInteractive`.
- `tf.exe` discovery is broader: `TF_EXE` (quotes tolerated; a stale path falls through) → `PATH` → `vswhere.exe`
  (also finds installs outside Program Files) → default folders for any VS 2017+ version/edition (year folders like
  `2022` and major-version folders like `18`) and VS 2010–2015 layouts. The newest `TF.exe` wins.
- The skill and commands describe `tf.exe` resolution for both the PowerShell and the Bash (Git Bash) tool.
### Fixed
- The hook read its stdin JSON in the console's OEM code page, so non-ASCII file paths (e.g. Hebrew folder names)
  were mangled and the checkout silently skipped. It now reads UTF-8.
- The hook runs `tf checkout /noprompt`, so a missing server login fails fast instead of opening a credential
  dialog until the hook timeout.
- The hook script is pure ASCII (Windows PowerShell 5.1 reads BOM-less files in the ANSI code page).
### Docs
- README: PowerShell 7 is not required; `setx TF_EXE` needs a Claude Code restart; pin `TF_EXE` for old TFS
  servers; behavior on locked-down machines.

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
