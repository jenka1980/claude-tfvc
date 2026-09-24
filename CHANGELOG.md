# Changelog

All notable changes to this project are documented here. Versioning follows [SemVer](https://semver.org/).

## [0.3.0] - 2026-09-24
### Added
- `/tf-select`: pick which TF.exe a project uses. Lists the TF.exe versions found on the machine and writes the
  choice to the project's `.claude/settings.local.json` (`env.TF_EXE`); `auto` removes it. The hook and the skill
  honor that file first, so one machine can use different TF.exe versions for different projects (e.g. an older
  client for a TFS 2010 server).
- `skills/tfvc/scripts/Find-Tf.ps1`: the single tf.exe resolver, shared by the skill, `/tf-select` and the hook.
  `-List` prints every TF.exe with its file version.
- `tests/`: a harness for the hook and resolver (both PowerShells, non-UTF-8 console, fake tf, fake Visual Studio
  trees, fake projects), pressure-scenario evals for the skill with a fake `tf.exe`, and a reviewed set of twenty
  trigger queries for the description.
### Changed
- Skill rewritten per the skill-authoring guides: description names the concrete triggers (read-only/EPERM
  errors, "no working folder mapping", Team Explorer, Azure DevOps Server, pending changes, picking a TF.exe
  version, "commit" in a project without `.git`), the body is ~half the size, uses the bundled resolver instead of
  three hand-written snippets, adds `tf shelve`/`tf unshelve`, ends with a common-mistakes table, and its rules of
  engagement close the loophole the evals exposed: a request that already names the files and the comment is not
  the confirmation, and a deadline does not waive it.

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
