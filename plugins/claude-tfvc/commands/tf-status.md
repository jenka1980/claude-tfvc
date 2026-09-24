---
description: Show pending TFVC changes in the current workspace (tf status)
---

Show the current TFVC pending changes. Resolve `tf.exe` per the `tfvc` skill (project `.claude/settings*.json` →
`TF_EXE` env var → PATH → vswhere → Visual Studio install folders; works from the PowerShell or Bash tool), then run
`tf status` (optionally scoped to `$ARGUMENTS` if a path is given).
Summarize the pending adds/edits/deletes for the user. Do not check anything in.
