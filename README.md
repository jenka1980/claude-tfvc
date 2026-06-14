# claude-tfvc

A [Claude Code](https://claude.com/claude-code) plugin that teaches Claude to use **TFVC (TFS / Team Foundation
Version Control)** via `tf.exe` instead of git, for Windows .NET projects.

It provides:
- a **knowledge skill** so Claude understands the read-only/checkout model and uses `tf.exe` (not git) in TFVC projects;
- **slash commands** for the everyday loop — `/tf-status`, `/tf-checkout`, `/tf-checkin`, `/tf-get`, `/tf-undo`;
- a **guarded auto-checkout hook** that runs `tf checkout` on a file right before Claude edits it — but only when
  the file is read-only (TFVC's "not checked out" signal), and it **never blocks edits**, so it's a no-op in
  git / non-TFVC projects.

## Requirements
- **Windows** (TFVC's `tf.exe` is Windows-only).
- Visual Studio with Team Explorer, or `tf.exe` otherwise available.
- PowerShell (`pwsh` or Windows PowerShell) for the hook.

## Install
```text
/plugin marketplace add jenka1980/claude-tfvc
/plugin install claude-tfvc@claude-tfvc
```
Installed plugins are user-level — available in every project on your machine. Run `/reload-plugins` after
install if the commands/hook don't appear immediately.

## Configuration
`tf.exe` is resolved in this order: **`TF_EXE` env var → `PATH` → a Visual Studio install** (probes 2022 / 2019 /
2017, all editions). For reliability, set `TF_EXE` to your `tf.exe` once, e.g.:
```powershell
setx TF_EXE "C:\Program Files (x86)\Microsoft Visual Studio\2017\Professional\Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\TF.exe"
```

## Commands
| Command | Action |
|---|---|
| `/tf-status` | Show pending changes (`tf status`) |
| `/tf-checkout [path]` | Check out file(s) for editing (`tf checkout`) |
| `/tf-checkin [comment] [path]` | Check in — **asks for confirmation first** (`tf checkin`) |
| `/tf-get [path]` | Get latest from the server (`tf get /recursive`) |
| `/tf-undo [path]` | Discard pending changes — **asks for confirmation first** (`tf undo`) |

## The auto-checkout hook
A `PreToolUse` hook on `Edit`/`Write` runs `hooks/tfvc-checkout.ps1`, which:
1. reads the target file path from the tool input,
2. acts **only if that file is read-only** (so writable files and non-TFVC projects are skipped instantly),
3. resolves `tf.exe` and runs `tf checkout` best-effort,
4. **always allows the edit to proceed** (it never denies/blocks).

**Disable it** by removing the `PreToolUse` block from `hooks/hooks.json` (or uninstalling the plugin). It only
calls `tf checkout` — it never checks in.

## Workspace types & `.tfignore` (read this for older TFS)
- **Local workspaces** (VS 2012+ default) honor a `.tfignore` file and detect edits without explicit checkout.
- **Server workspaces** (common on TFS 2010-era servers) require an explicit `tf checkout` (files stay read-only)
  and **do not** honor `.tfignore` — exclude files via the Pending Changes "Excluded/Detected" list instead.

Check your type with `tf workspaces /collection:<url>`.

## Scope / limitations
- Covers the everyday checkout/checkin/status/get/undo loop. Branching/merging/shelvesets are not wrapped as
  commands (use `tf.exe` directly; the skill documents the model).
- Windows-only by nature of `tf.exe`.

## License
MIT © Evgeny Satanovsky
