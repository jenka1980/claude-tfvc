---
name: tfvc
description: >
  Use tf.exe (TFVC, TFS, Team Foundation Version Control, also hosted by Azure DevOps Server) instead of git on
  Windows projects. Use this whenever a project has no .git folder, files are read-only until checked out (saving
  fails with EPERM or "access denied"), tf.exe reports "no working folder mapping", or the user mentions TFS, TFVC,
  Team Explorer, tf.exe, check-in, checkout, pending changes, shelvesets, workspaces, or which TF.exe or Visual
  Studio version a project should use (/tf-select), even when they say "commit" or "git". Covers finding tf.exe,
  the read-only/checkout model, status/checkout/checkin/get/undo/shelve, and local-vs-server workspaces with
  .tfignore.
---

# Working with TFVC (TFS) instead of git

TFVC is Microsoft's **centralized** source control: no local history, no `.git`, and every edit goes through
**checkout → change → check-in** against a server. On these projects use `tf.exe`, never git. A folder that has a
`.git` directory is not TFVC, even when TFS or Azure DevOps hosts that git repo.

## Finding tf.exe
Run the resolver bundled with this skill; it prints the full path to use (exit code 1 if it finds none):

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/Find-Tf.ps1"
```

Add `-List` to see every TF.exe on the machine with its file version (15 = VS 2017, 16 = VS 2019, 17 = VS 2022,
18 = VS 18); that is what `/tf-select` shows before pinning one for a project. The order is: the project's
`.claude/settings.local.json` (then `settings.json`) `env.TF_EXE`, the `TF_EXE` environment variable, PATH,
vswhere, then the default Visual Studio folders, newest version first; a configured path that no longer exists
falls through. The same command line works from PowerShell and from Git Bash, because `powershell.exe` is on every
Windows, and `tf` accepts `-option` as well as `/option` from either shell. Below, `tf` stands for that resolved
path.

## The core model: read-only until checkout
TFVC keeps unchanged files read-only, so a write fails (EPERM, "access denied") until the file is checked out.
The plugin's PreToolUse hook runs `tf checkout` on a read-only file right before Edit/Write; `/tf-checkout` does
the same explicitly.

## Everyday commands
```text
tf status                              # pending changes in the workspace
tf checkout <path>                     # make file(s) editable (same as: tf edit)
tf add <path>                          # start tracking a new file
tf checkin /comment:"message" <path>   # commit pending changes to the server
tf get [<path>] [/recursive]           # get latest from the server
tf undo <path>                         # discard a pending change / checkout
tf rename <old> <new>                  # move or rename under source control
tf delete <path>                       # delete under source control
tf shelve <name> [/comment:"..."]      # park pending changes on the server as a shelveset (/replace updates it)
tf unshelve <name>                     # bring a shelveset back into the workspace
tf workspaces /collection:<url>        # list workspaces (/format:detailed shows local vs server)
```

## Local vs server workspaces
- **Local** (VS 2012+ default): edits are detected without checkout and `.tfignore` is honored.
- **Server** (typical on TFS 2010-era servers): files stay read-only until `tf checkout`, and `.tfignore` is
  ignored, so keep junk out by never `tf add`ing it (or via the Pending Changes "Excluded" list in VS).

`.tfignore` "not working" almost always means a server workspace; confirm with `tf workspaces`.

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
| Clearing the read-only attribute (`attrib -r`, `IsReadOnly = $false`) to force a write | `tf checkout` the file; a stripped attribute leaves an edit the server never sees |
| Moving or deleting tracked files with the OS | `tf rename` / `tf delete` |
| `tf add`ing bin/obj, packages, `*.user` or files holding credentials | Leave build output and secrets out; connection strings travel out-of-band |
| Checking in because the task "is done" | Check in only when the user asks, after they confirm the pending set |
| Using the newest TF.exe against an old server | Pin an older TF.exe for that project with `/tf-select` |
