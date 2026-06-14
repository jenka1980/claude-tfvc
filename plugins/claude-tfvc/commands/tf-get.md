---
description: Get the latest version from the TFVC server (tf get)
argument-hint: "[path]  (defaults to the whole workspace, recursive)"
---

Get the latest from the TFVC server for: $ARGUMENTS

Resolve `tf.exe` per the `tfvc` skill, then run `tf get <path> /recursive` (default to the workspace root if no
path is given). Report what was updated and flag any conflicts for the user to resolve.
