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
Resolve in this order:
1. The `TF_EXE` environment variable (if set, use it verbatim).
2. `tf.exe` on `PATH` (`Get-Command tf.exe`).
3. A Visual Studio install, e.g.:
   `…\Microsoft Visual Studio\<edition>\Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\TF.exe`
   (probe 2022/2019/2017 and Enterprise/Professional/Community).

Tip: set `TF_EXE` once (machine env var) to avoid probing. All commands below assume `tf` resolves to that path.

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
