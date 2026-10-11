---
description: Show pending TFVC changes in the current workspace (tf status)
---

Show the current TFVC pending changes. Run `tf status` per the `tfvc` skill's "Running tf" (the launcher
`scripts/Invoke-Tf.ps1` picks the direct or relay transport; works from the PowerShell or Bash tool), optionally
scoped to `$ARGUMENTS` if a path is given.
Summarize the pending adds/edits/deletes for the user. Do not check anything in.
