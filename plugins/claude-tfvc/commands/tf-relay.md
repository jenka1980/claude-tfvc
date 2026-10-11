---
description: Relay tf through your interactive Windows session when this is an SSH session without network credentials (TF30063) — status, on/off, one-time setup
argument-hint: "[status | on | off | auto]  (default: status)"
---

Manage the relay transport that runs `tf` inside your interactive Windows session: $ARGUMENTS

The relay exists for sessions without network credentials (typically an SSH key logon, for example VS Code
Remote-SSH), where `tf.exe` fails with `TF30063: You are not authorized`. Each `tf` call is handed to a worker
that the scheduled task `ClaudeTfvcRelay` starts in your console or RDP session. The scripts live in the plugin's
`skills/tfvc/scripts/` folder, next to `Invoke-Tf.ps1` and `Find-Tf.ps1`.

1. **status** (the default): run
   `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/skills/tfvc/scripts/Register-TfRelay.ps1" -Status`
   and summarize the report: session kind, effective transport and where the setting comes from, task state and
   last result, worker version, probe timing. Exit code 0 means the relay is usable.
   - If the task is NOT registered (or registered for another user): show the exact registration command from
     the report, explain that the worker needs an interactive Windows session (console or RDP; a disconnected RDP
     session is fine), and ask whether to run the registration now. Run it **only after an explicit yes**, from
     this session, then run `-Status` again. If registration fails here, tell the user to run the same command
     from an RDP or console session.
   - If the last result decodes to "not logged on interactively" (`0x00041303`): tell the user to connect over
     RDP once and just disconnect (do not sign out), then rerun `/tf-relay`.
2. **on** / **off** / **auto**: first do `status` (offering registration only for `on`; `off` and `auto` never
   need it), then write `env.TFVC_TRANSPORT` in `<project root>/.claude/settings.local.json`: `relay` for `on`,
   `direct` for `off`, remove the key for `auto`. If the user declines registration on `on`, still write `relay`
   and warn that every `tf` call will fail with exit 120 until the task exists. Merge into the existing file
   (keep every other key, create the folder/file if missing, keep the JSON valid with backslashes escaped).
   Never edit `~/.claude/settings.json`.
3. Report the transport now in effect. The hook and the launcher read the file on every call; the
   `TFVC_TRANSPORT` environment variable that Claude Code exports from it needs a session restart. Do not check
   anything in.
