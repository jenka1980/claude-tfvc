---
description: Choose which TF.exe this project uses (writes env.TF_EXE to .claude/settings.local.json)
argument-hint: "[year | major version | path | auto]  (omit to pick from a list)"
---

Select the `tf.exe` this project should use: $ARGUMENTS

1. List the TF.exe candidates on this machine with their versions by running the `tfvc` skill's resolver with
   `-List` (`scripts/Find-Tf.ps1` in the skill folder; see the skill's "Finding tf.exe"). Run it again without
   `-List` for the current effective choice, and state where it comes from per the skill's resolution order
   (project `.claude/settings.local.json`, project `.claude/settings.json`, the `TF_EXE` env var, PATH, or
   auto-detected).
2. Pick the target:
   - If an argument was given, match it against the list: a year such as `2017` (a path segment), a major file
     version such as `15`, or a full path to a `TF.exe`. `auto` (or `default`) means remove the project override.
   - Otherwise, or if nothing matches, ask the user to choose from the list, offering "auto-detect: remove the
     project override" as one option. Never guess.
3. Write the choice to `<project root>/.claude/settings.local.json` as `{ "env": { "TF_EXE": "<full path>" } }`,
   merging into the existing file (keep every other key) and creating the folder/file if missing. Keep the JSON
   valid (backslashes escaped). For auto-detect, remove `env.TF_EXE` and leave everything else. Never edit
   `~/.claude/settings.json`: the machine-wide default stays the `TF_EXE` env var (`setx`).
4. Report the file and value. It applies immediately: the auto-checkout hook and the skill read this file directly,
   and Claude Code also exports it as `TF_EXE` for shell commands. Note that `.claude/` is not tracked by TFVC unless
   explicitly `tf add`ed, so the choice stays on this machine.
