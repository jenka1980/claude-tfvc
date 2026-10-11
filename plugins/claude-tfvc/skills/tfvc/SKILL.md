---
name: tfvc
description: >
  Use tf.exe (TFVC, TFS, Team Foundation Version Control, also hosted by Azure DevOps Server) instead of git on
  Windows projects. Use this whenever a project has no .git folder, files are read-only until checked out (saving
  fails with EPERM or "access denied"), tf.exe reports "no working folder mapping" or "TF30063: not authorized"
  (typical in an SSH or VS Code Remote-SSH session; see /tf-relay), or the user mentions TFS, TFVC, Team Explorer,
  tf.exe, check-in, checkout, pending changes, shelvesets, workspaces, or which TF.exe or Visual Studio version a
  project should use (/tf-select), even when they say "commit" or "git". Covers running tf.exe (directly, or
  relayed into the interactive session from SSH), the read-only/checkout model, status/checkout/checkin/get/undo/
  shelve, and local-vs-server workspaces with .tfignore.
---

# Working with TFVC (TFS) instead of git

TFVC is **centralized** source control: no local history, no `.git`, every edit goes through
**checkout → change → check-in** against a server. Use `tf.exe`, never git. A folder with a `.git` directory is
not TFVC.

## Running tf
Run `tf` only through this launcher. It resolves `tf.exe` and picks the transport: direct, or a relay into your
interactive Windows session when an SSH session lacks network credentials:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/Invoke-Tf.ps1" <tf arguments>
```

Below, `tf` means that command line. It works from PowerShell and Git Bash. `tf` accepts `-option` as well as `/option` from either shell. Exit codes are `tf`'s own; 120
means the relay is not set up (run `/tf-relay`), 124 a relay timeout, 127 no `tf.exe` found.
`scripts/Find-Tf.ps1 -List` lists every TF.exe with its file version (15 = VS 2017 ... 18 = VS 18) for
`/tf-select`; resolution order: project `.claude/settings.local.json` (then `settings.json`) `env.TF_EXE`,
`TF_EXE` env var, PATH, vswhere, VS folders, newest first.

## The core model: read-only until checkout
Unchanged files are read-only, so writes fail (EPERM, "access denied") until checkout. The PreToolUse hook runs
`tf checkout` on a read-only file before Edit/Write; `/tf-checkout` does too.

## Everyday commands
```text
tf status
tf checkout <path>                     # same as: tf edit
tf add <path>
tf checkin /comment:"message" <path>
tf get [<path>] [/recursive]
tf undo <path>
tf rename <old> <new>
tf delete <path>
tf shelve <name>                       # tf unshelve <name> restores
tf workspaces                          # /format:detailed shows local vs server
```

## Local vs server workspaces
- **Local** (VS 2012+ default): edits are detected without checkout; `.tfignore` is honored.
- **Server** (TFS 2010-era): read-only until `tf checkout`; `.tfignore` is ignored, so never `tf add` junk.

`.tfignore` "not working" usually means a server workspace.

## Rules of engagement
- Never run `git init`, `git add` or `git commit` in a TFVC project, even when the user says "commit". "Commit"
  means: show `tf status`, then ask them to confirm the exact pending set, and run `tf checkin` **only after that
  explicit confirmation**. Check-ins are visible to the whole team and cannot be quietly undone. A request that
  already names the files and the comment is still the request, not the confirmation, and a deadline, "I'm
  leaving now" or the lack of a follow-up turn does not waive it: when you cannot ask, stop with the pending set
  shown and the exact `tf checkin` line that a "yes" would run.
- New files are invisible to the server until `tf add`; renames and deletes go through `tf rename` and
  `tf delete`, so the server records them.
- `tf undo` discards local edits irreversibly; confirm first.

## Common mistakes
| Mistake | Do this instead |
|---|---|
| Clearing the read-only attribute (`attrib -r`) to force a write | `tf checkout`; the server never sees a stripped-attribute edit |
| Moving or deleting tracked files with the OS | `tf rename` / `tf delete` |
| `tf add`ing bin/obj, packages, `*.user`, credentials | Keep build output and secrets out |
| Checking in because the task "is done" | Check in only when the user asks, after they confirm the pending set |
| Using the newest TF.exe against an old server | Pin an older TF.exe for that project with `/tf-select` |
| Retrying `tf` after `TF30063: not authorized` in an SSH / Remote-SSH session | No network credentials; run `/tf-relay` so `tf` runs in your interactive Windows session |
