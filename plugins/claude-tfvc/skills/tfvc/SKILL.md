---
name: tfvc
description: >
  Use when working in a TFVC / TFS (Team Foundation Version Control) project on Windows — i.e. there is
  no .git directory, source files are read-only until checked out, or the user mentions TFS/TFVC/tf.exe,
  checkout/checkin, shelvesets, or workspaces. Teaches Claude to use tf.exe for source control instead of
  git: locating tf.exe, the read-only/checkout model, status/checkout/checkin/get/undo, and the
  local-vs-server workspace and .tfignore caveats.
---

# Working with TFVC (TFS) instead of git

TFVC (Team Foundation Version Control) is Microsoft's **centralized** source-control system. It is **not git**:
there is no local history, no `.git`, and edits go through an explicit **checkout → change → check-in** cycle
against a server. On these projects, use `tf.exe` — **do not run git commands**.

## When this applies
- The working tree has **no `.git`** directory, and/or
- Source files are **read-only** on disk (TFVC marks files read-only until you check them out), and/or
- The user refers to TFS, TFVC, `tf.exe`, check-in/checkout, shelvesets, or workspaces.

## Locating tf.exe
Resolve in this order (the auto-checkout hook uses exactly the same order):
1. The `TF_EXE` environment variable, if it points at an existing file (surrounding quotes are tolerated).
2. `tf.exe` on `PATH`.
3. `vswhere.exe` (`%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe`, present with any VS 2017+
   install; it also finds installs outside Program Files): for each install, look for
   `<installationPath>\Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\TF.exe`.
4. Default install folders under Program Files and Program Files (x86):
   - VS 2017+: `Microsoft Visual Studio\<version>\<edition>\Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\TF.exe`
     (`<version>` is a year like `2022` or a major version like `18`; any edition, including BuildTools and TeamExplorer)
   - VS 2010-2015: `Microsoft Visual Studio <n>.0\Common7\IDE\TF.exe`

When several exist, the newest `TF.exe` wins. Old TFS servers (2010-era) may reject the newest client; set `TF_EXE`
to an older TF.exe in that case. Tip: set `TF_EXE` once (user env var, then restart Claude Code) to skip probing.

Use whichever shell tool you have. `tf` options work unchanged from both PowerShell and Git Bash, and `tf` accepts
`-option` as well as `/option`. All commands below assume `$tf` / `"$tf"` resolves to that path.

```powershell
$tf = "$env:TF_EXE".Trim('"')
if (-not ($tf -and (Test-Path $tf))) { $tf = (Get-Command tf.exe -ErrorAction SilentlyContinue).Source }
if (-not $tf) {
  $vsw = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  if (Test-Path $vsw) {
    $tf = & $vsw -all -prerelease -products * -property installationPath |
      ForEach-Object { Join-Path $_ 'Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\TF.exe' } |
      Where-Object { Test-Path $_ } | Select-Object -First 1
  }
}
& $tf status
```

```bash
tf="${TF_EXE//\"/}"                                   # TF_EXE with any quotes stripped
[ -f "$tf" ] || tf="$(command -v tf.exe)"
[ -n "$tf" ] || tf="$("/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe" -all -prerelease -products '*' -property installationPath 2>/dev/null | tr -d '\r' | while read -r p; do f="$p\\Common7\\IDE\\CommonExtensions\\Microsoft\\TeamFoundation\\Team Explorer\\TF.exe"; [ -f "$f" ] && { echo "$f"; break; }; done)"
"$tf" status
```

## The core model: read-only until checkout
TFVC keeps unchanged files **read-only**. To edit a file you must check it out first; otherwise the write fails.
This plugin's PreToolUse hook auto-runs `tf checkout` on read-only files before an edit, but you can also do it
explicitly with `/tf-checkout` or the commands below.

## Everyday commands
```text
tf status                              # pending changes in the workspace
tf checkout <path>                     # mark file(s) editable (a.k.a. "tf edit")
tf add <path>                          # add a new file to source control
tf checkin /comment:"message" <path>   # commit pending changes to the server
tf get [<path>] [/recursive]           # get latest from the server
tf undo <path>                         # discard a pending change / checkout
tf rename <old> <new>                  # move/rename under source control
tf delete <path>                       # delete under source control
tf workspaces /collection:<url>        # list workspaces (and their type)
```
New files: create the file, then `tf add` it (it won't be tracked otherwise). Renames/moves/deletes must go
through `tf rename` / `tf delete` so the server records them — don't use OS move/del for tracked files.

## Local vs server workspaces (important)
- **Local workspaces** (VS 2012+ default): support offline edits and honor a **`.tfignore`** file for excluding
  files from "Detected/Add" — `tf checkout` is often unnecessary because edits are detected locally.
- **Server workspaces** (common on older TFS, e.g. TFS 2010): require an explicit `tf checkout` before editing
  (files stay read-only), and **do NOT honor `.tfignore`** — exclude files via the Pending Changes
  "Excluded/Detected" list or simply never `tf add` them.

Check the type with `tf workspaces /collection:<url>` (or VS → manage workspaces). If `.tfignore` doesn't seem to
work, the workspace is almost certainly a server workspace.

## Rules of engagement
- Prefer `tf` over git in TFVC projects. **Do not** run `git init`/`git add`/`git commit` here.
- **Never check in** unless the user explicitly asks; describe the pending changes and let them confirm.
- Treat connection strings / secrets as out-of-band — never add files containing live credentials.
- When an edit fails because a file is read-only, check it out (`tf checkout`) rather than clearing the
  read-only attribute by hand.
