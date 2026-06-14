---
description: Check in pending TFVC changes with a comment (tf checkin) — asks for confirmation first
argument-hint: "[comment]  [optional path]"
---

Prepare to check in pending TFVC changes: $ARGUMENTS

1. Resolve `tf.exe` per the `tfvc` skill and run `tf status` first to show exactly what would be checked in.
2. **Confirm with the user before checking in** — never check in unprompted.
3. On confirmation, run `tf checkin /comment:"<comment>" <path>` (scope to the given path, else the pending set).
   If no comment was provided, ask for one.
4. Report the changeset result.
