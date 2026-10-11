---
description: Check out file(s) from TFVC for editing (tf checkout)
argument-hint: "[file or path]  (defaults to the file currently being worked on)"
---

Check out the following from TFVC so it becomes editable: $ARGUMENTS

Run, per the `tfvc` skill's "Running tf", `tf checkout <path>`. If no path is given, check out the
file(s) currently being edited in this task. Report success/failure. This is needed because TFVC keeps
unchanged files read-only until they are checked out.
