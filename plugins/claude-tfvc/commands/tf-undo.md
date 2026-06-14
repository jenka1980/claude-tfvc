---
description: Discard a pending TFVC change / checkout (tf undo) — asks for confirmation first
argument-hint: "[file or path]"
---

Undo (discard) pending TFVC changes for: $ARGUMENTS

1. Resolve `tf.exe` per the `tfvc` skill and run `tf status` to show what would be reverted.
2. **Confirm with the user** — `tf undo` discards local edits and cannot be undone.
3. On confirmation, run `tf undo <path>` and report the result.
