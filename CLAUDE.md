# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is **not an application** — it's a **Claude Code plugin** (`claude-tfvc`) distributed via a single-plugin
marketplace. It teaches Claude to use **TFVC (TFS / Team Foundation Version Control)** via `tf.exe` instead of
git on Windows .NET projects. There is no build, test, or lint step; the "code" is Markdown (skill + commands),
JSON (manifests + hook config), and one PowerShell hook script.

## Layout & how the pieces wire together

Two manifests define the distribution and must stay consistent with each other and the file tree:
- `.claude-plugin/marketplace.json` — the marketplace; points `source` at `./plugins/claude-tfvc`.
- `plugins/claude-tfvc/.claude-plugin/plugin.json` — the plugin manifest; its `skills`/`commands` keys point at
  the first two subsystems below. The hook is NOT referenced here — Claude Code auto-loads `hooks/hooks.json`
  from its standard location, and adding a `hooks` key back causes a "Duplicate hooks file detected" load
  failure (the 0.1.1 fix). **Version lives in both manifests** — bump together.

The plugin has three independent surfaces, all under `plugins/claude-tfvc/`:
1. **Skill** (`skills/tfvc/SKILL.md`) — the knowledge layer. Its frontmatter `description` is the activation
   trigger (no `.git`, read-only files, or user mentions TFS/tf.exe). This is the source of truth for the TFVC
   model and `tf.exe` resolution order; commands and README defer to it.
2. **Commands** (`commands/tf-*.md`) — the five everyday-loop slash commands (`/tf-status`, `/tf-checkout`,
   `/tf-checkin`, `/tf-get`, `/tf-undo`). Each is a prompt file with `description`/`argument-hint` frontmatter that
   instructs Claude to resolve `tf.exe` "per the `tfvc` skill" and run the matching `tf` command.
3. **Hook** (`hooks/hooks.json` + `hooks/tfvc-checkout.ps1`) — a `PreToolUse` hook on `Edit|Write` that runs
   `tf checkout` on the target file. `hooks.json` launches the script with `powershell.exe` (Windows PowerShell
   5.1) via `${CLAUDE_PLUGIN_ROOT}`.

## Invariants to preserve when editing

These design rules are load-bearing — changes that break them defeat the plugin's purpose:
- **`tf.exe` resolution order is fixed everywhere: `TF_EXE` env var (existing file; quotes tolerated) → `PATH` →
  `vswhere.exe` → default Visual Studio folders (VS 2017+ any version/edition, VS 2010–2015 layouts), newest
  `TF.exe` first.** It appears in the skill, README, and `tfvc-checkout.ps1` — keep all three in sync.
- **The hook must never block an edit.** `tfvc-checkout.ps1` always `exit 0`, swallows all errors, and acts
  **only when the target file is read-only** (TFVC's "not checked out" signal). This keeps it a near-instant no-op
  in git / non-TFVC projects. Do not add denials, blocking, or check-in behavior to the hook — it only checks out.
- **The hook is launched with `powershell.exe` (Windows PowerShell 5.1), never `pwsh`** — PowerShell 7 is not
  installed by default and starts the hook no faster. The script must therefore stay 5.1-compatible, pure ASCII
  (no BOM; 5.1 reads BOM-less files in the ANSI code page), read stdin as UTF-8, and keep the
  `$MyInvocation.InvocationName -ne '.'` guard so dot-sourcing only defines `Resolve-TfExe` (the test harness
  relies on that).
- **Never check in without explicit user confirmation.** `/tf-checkin` and `/tf-undo` run `tf status` first and
  require confirmation; the skill's "rules of engagement" forbid unprompted check-ins and `git` commands in TFVC
  projects. Preserve this in any command or skill edits.
- **Local vs server workspace distinction** is documented in three places (skill, README): local workspaces honor
  `.tfignore` and often need no explicit checkout; server workspaces require `tf checkout` and ignore `.tfignore`.

## Conventions

- Keep the **README, CHANGELOG, and SKILL in sync** when changing behavior — they intentionally overlap.
- Update `CHANGELOG.md` (SemVer, dated entries) for any user-visible change.
- PowerShell hook targets both Windows PowerShell 5.1 and `pwsh`; keep it compatible with both (5.1 is the one
  that actually runs it).
