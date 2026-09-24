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
- Visual Studio with Team Explorer (2010 or later), or `tf.exe` otherwise available.
- **Windows PowerShell 5.1** for the hook. It ships with every supported Windows, so there is nothing to install.
  PowerShell 7 (`pwsh`) is **not** required, and gains nothing here: both start the hook in about the same time.
- Git for Windows is optional. Claude runs `tf` from whichever shell tool it has (PowerShell or Git Bash); `tf`'s
  `/option` syntax works unchanged from both.

## Install
```text
/plugin marketplace add jenka1980/claude-tfvc
/plugin install claude-tfvc@claude-tfvc
```
Installed plugins are user-level — available in every project on your machine. Run `/reload-plugins` after
install if the commands/hook don't appear immediately.

## Configuration
`tf.exe` is resolved in this order, by the skill and the hook alike:
1. **`TF_EXE`** env var, if it points at an existing file (surrounding quotes are tolerated).
2. **`tf.exe` on `PATH`**.
3. **`vswhere.exe`** (installed with any VS 2017+), which also finds Visual Studio installs outside Program Files.
4. **Default Visual Studio folders** under Program Files / Program Files (x86): VS 2017+ (any version folder — a
   year like `2022` or a major version like `18` — and any edition, including BuildTools and TeamExplorer) and
   VS 2010–2015 (`Microsoft Visual Studio <n>.0\Common7\IDE\TF.exe`).

When several are found, the **newest `TF.exe` wins**. Set `TF_EXE` to pin a specific one — for example a TFS
2010-era server may reject newer clients, so point it at VS 2017's:
```powershell
setx TF_EXE "C:\Program Files (x86)\Microsoft Visual Studio\2017\Professional\Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\TF.exe"
```
`setx` only affects new processes — **restart Claude Code** afterwards.

## Commands
| Command | Action |
|---|---|
| `/tf-status` | Show pending changes (`tf status`) |
| `/tf-checkout [path]` | Check out file(s) for editing (`tf checkout`) |
| `/tf-checkin [comment] [path]` | Check in — **asks for confirmation first** (`tf checkin`) |
| `/tf-get [path]` | Get latest from the server (`tf get /recursive`) |
| `/tf-undo [path]` | Discard pending changes — **asks for confirmation first** (`tf undo`) |

## The auto-checkout hook
A `PreToolUse` hook on `Edit`/`Write` runs `hooks/tfvc-checkout.ps1` via `powershell.exe` (Windows PowerShell
5.1), which:
1. reads the target file path from the tool input (as UTF-8, so non-ASCII paths work on any console code page),
2. acts **only if that file is read-only** (so writable files and non-TFVC projects are skipped instantly),
3. resolves `tf.exe` (order above) and runs `tf checkout /noprompt` best-effort — `/noprompt` makes a missing
   server login fail fast instead of opening a credential dialog,
4. **always allows the edit to proceed** (it never denies/blocks).

**Locked-down machines:** if Group Policy pins the PowerShell execution policy, or AppLocker blocks scripts under
the user profile, the hook cannot run and degrades to a no-op — the edit still proceeds, you just see a hook error.
Use `/tf-checkout` manually in that case.

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
