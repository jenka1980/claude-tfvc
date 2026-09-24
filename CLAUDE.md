# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is **not an application** — it's a **Claude Code plugin** (`claude-tfvc`) distributed via a single-plugin
marketplace. It teaches Claude to use **TFVC (TFS / Team Foundation Version Control)** via `tf.exe` instead of
git on Windows .NET projects. There is no build or lint step; the "code" is Markdown (skill + commands), JSON
(manifests + hook config), and two PowerShell scripts (the hook and the shared `tf.exe` resolver). There IS a
test harness — see "Tests" below.

## Layout & how the pieces wire together

Two manifests define the distribution and must stay consistent with each other and the file tree:
- `.claude-plugin/marketplace.json` — the marketplace; points `source` at `./plugins/claude-tfvc`.
- `plugins/claude-tfvc/.claude-plugin/plugin.json` — the plugin manifest; its `skills`/`commands` keys point at
  the first two subsystems below. The hook is NOT referenced here — Claude Code auto-loads `hooks/hooks.json`
  from its standard location, and adding a `hooks` key back causes a "Duplicate hooks file detected" load
  failure (the 0.1.1 fix). **Version lives in both manifests** — bump together.

The plugin has three independent surfaces, all under `plugins/claude-tfvc/`:
1. **Skill** (`skills/tfvc/SKILL.md` + `skills/tfvc/scripts/Find-Tf.ps1`) — the knowledge layer. Its frontmatter
   `description` is the activation trigger (no `.git`, read-only files, TFS/tf.exe/check-in vocabulary, "which
   TF.exe version"). The skill tells Claude to run `Find-Tf.ps1` (via `${CLAUDE_SKILL_DIR}`) to locate `tf.exe`;
   `-List` prints every TF.exe with its version. That script is the ONE implementation of tf.exe resolution —
   the hook dot-sources it. Commands and README defer to the skill.
2. **Commands** (`commands/tf-*.md`) — six slash commands: the everyday loop (`/tf-status`, `/tf-checkout`,
   `/tf-checkin`, `/tf-get`, `/tf-undo`) plus `/tf-select`, which writes the project's TF.exe choice to
   `.claude/settings.local.json` (`env.TF_EXE`). Each is a prompt file with `description`/`argument-hint` frontmatter
   that instructs Claude to resolve `tf.exe` "per the `tfvc` skill" and run the matching `tf` command. The docs
   call `commands/` legacy in favour of `skills/`, but converting would rename them to `/claude-tfvc:tf-status`,
   so they stay.
3. **Hook** (`hooks/hooks.json` + `hooks/tfvc-checkout.ps1`) — a `PreToolUse` hook on `Edit|Write` that runs
   `tf checkout` on the target file. `hooks.json` launches the script with `powershell.exe` (Windows PowerShell
   5.1) via `${CLAUDE_PLUGIN_ROOT}`. The script loads `Find-Tf.ps1` lazily, only when it sees a read-only file.

Outside the plugin: `tests/` (see below) and `CHANGELOG.md`/`README.md`.

## Invariants to preserve when editing

These design rules are load-bearing — changes that break them defeat the plugin's purpose:
- **`tf.exe` resolution is implemented exactly once, in `skills/tfvc/scripts/Find-Tf.ps1`, and the order is fixed:**
  project `.claude/settings.local.json` then `.claude/settings.json` `env.TF_EXE` (written by `/tf-select`; the
  project is `CLAUDE_PROJECT_DIR`, else the hook payload's `cwd`, else the current directory) → `TF_EXE` env var →
  `PATH` → `vswhere.exe` → default Visual Studio folders (VS 2017+ any version/edition, VS 2010–2015 layouts),
  newest `TF.exe` first. Configured values count only if the file exists (quotes tolerated); stale ones fall
  through. SKILL.md and README **describe** this order — keep both in sync with the script, never re-implement it.
- **The hook must never block an edit.** `tfvc-checkout.ps1` always `exit 0`, swallows all errors, and acts
  **only when the target file is read-only** (TFVC's "not checked out" signal). This keeps it a near-instant no-op
  in git / non-TFVC projects. Do not add denials, blocking, or check-in behavior to the hook — it only checks out.
- **Both PowerShell files are launched with / must run under `powershell.exe` (Windows PowerShell 5.1), never
  require `pwsh`** — PowerShell 7 is not installed by default and starts them no faster. Keep them 5.1-compatible,
  pure ASCII (no BOM; 5.1 reads BOM-less files in the ANSI code page), reading stdin as UTF-8, and keep the
  `$MyInvocation.InvocationName -ne '.'` guard in `Find-Tf.ps1` so dot-sourcing only defines functions.
- **Never check in without explicit user confirmation.** `/tf-checkin` and `/tf-undo` run `tf status` first and
  require confirmation; the skill's "rules of engagement" forbid unprompted check-ins and `git` commands in TFVC
  projects. Preserve this in any command or skill edits.
- **Local vs server workspace distinction** is documented in three places (skill, README): local workspaces honor
  `.tfignore` and often need no explicit checkout; server workspaces require `tf checkout` and ignore `.tfignore`.

## Tests

- `tests/test-hook.ps1` — harness for the hook, `hooks.json` and `Find-Tf.ps1`. Runs every hook case under
  Windows PowerShell 5.1 and pwsh with the console code page forced to 862, uses a fake `tf` that logs its
  arguments, fake Program Files trees (versioned TF.exe stubs compiled with the .NET Framework `csc.exe`), and
  fake projects with `.claude/settings*.json`. Run it after touching either script:
  `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-hook.ps1` (exit code = failures; SKIP rows
  mark checks whose tool is missing on the machine).
- `tests/skill-evals/` — pressure-scenario evals for the skill itself (skill-creator format: `evals.json`,
  `New-Sandbox.ps1`, `Grade-Run.ps1`, a fake `tf.exe` built from `fake-tf/tf.cs`). Each scenario runs a subagent
  with and without the skill in a throwaway sandbox; `README.md` there explains the loop. `workspace/` (run
  outputs) and `fake-tf/bin/` are git-ignored.

## Conventions

- Keep the **README, CHANGELOG, and SKILL in sync** when changing behavior — they intentionally overlap.
- Update `CHANGELOG.md` (SemVer, dated entries) for any user-visible change.
- The skill follows the skill-authoring guides: description = what it does + specific triggers (kept "pushy",
  under 1024 chars), body under ~500 words with a quick-reference command block and a common-mistakes table,
  one bundled script instead of multi-language snippets.
