# claude-tfvc 0.4.0: relay transport for sessions without network credentials

Design document. Requirements come from `docs/specs/2026-10-11-relay-transport-spec.md`; this document records
the agreed design and the decisions taken while reviewing it. Section numbers quoted as "spec 4.x" refer to that
file. Target version: 0.4.0.

## 1. Summary

When Claude Code runs in a Windows session that has no network credentials (typically an SSH key logon, for
example VS Code Remote-SSH), every `tf.exe` call against an on-prem TFS with Windows authentication fails with
`TF30063: You are not authorized`. The plugin becomes useless: the hook cannot check files out, and every
`/tf-*` command fails.

The fix is a **relay transport**. A new launcher, `Invoke-Tf.ps1`, becomes the single way the plugin runs `tf`.
In a normal session it runs `tf.exe` directly, byte-transparently. In a remote session it hands the request to a
**worker** that a Windows scheduled task starts inside the user's *interactive* session (console or RDP, even a
disconnected one), where the credentials exist. Requests and responses travel through a per-user file queue.
Registration of the task is a one-time step; a new `/tf-relay` command diagnoses and configures the feature.

## 2. Problem and evidence

Reproduced on DEVELOPER4 (Windows 10, OpenSSH with key, domain user, VS 2017 `TF.exe` 15.x, server workspace):

```text
"<...>/Team Explorer/TF.exe" status "D:/Projects/X/X.sln" -noprompt
TF30063: You are not authorized to access <server>\<collection>.
```

Consequences in 0.3.0: the hook swallows the error and exits 0, the file stays read-only, `Edit`/`Write` fail
with "access denied", and the cause is visible nowhere. All `/tf-*` commands fail the same way.

Verified while designing: `tf.exe` writes its error text to **stderr**, leaves stdout empty, and exits with
**100** on a failed connection. Redirected non-ASCII output comes out as single-byte characters (one byte per
Hebrew letter), so a code-page decode is the right model for the worker.

## 3. Goals, non-goals, success criteria

**Goals**

- In an SSH session the plugin behaves as in a local one: the hook checks out read-only files, `/tf-*` and the
  skill run any `tf` command.
- `tf.exe` executes in the user's interactive session via a scheduled task with `LogonType Interactive` and no
  stored password.
- Local sessions keep the 0.3.0 behaviour.

**Non-goals**

- Storing a password or PAT, `tf /login:...`.
- Non-Windows clients, running as another user, running on another machine.
- A command whitelist in the relay. The relay is transport; policy stays in the skill and in `permissions`.

**Success criteria** are the acceptance checks in section 17.

## 4. Architecture

```text
  Claude Code session (may be SSH, no network credentials)
  ┌────────────────────────────────────────────────────────────────────┐
  │ hook tfvc-checkout.ps1 ──dot-source──┐                             │
  │ skill / commands: powershell -File ──┤──► Invoke-Tf.ps1            │
  │                                      │     ├─ Find-Tf.ps1 (resolve tf.exe, read settings)
  │                                      │     ├─ transport = direct ──► tf.exe (inherits stdout)
  │                                      │     └─ transport = relay                              │
  └──────────────────────────────────────┼─────────────┬───────────────┘
                                         │             │ <id>.req.json  +  Start-ScheduledTask
                        %LOCALAPPDATA%\claude-tfvc\relay\queue\     (per-user file queue)
                                         │             │ <id>.res.json
  Interactive Windows session (console / RDP, has credentials)       │
  ┌──────────────────────────────────────┼─────────────▼───────────────┐
  │ scheduled task ClaudeTfvcRelay ──► Tf-RelayWorker.ps1 ──► tf.exe   │
  └────────────────────────────────────────────────────────────────────┘
```

Three design rules hold everything together:

1. **One launcher.** The hook, the skill and the commands run `tf` only through `Invoke-Tf.ps1`. It is the only
   place that chooses a transport. `tf.exe` resolution stays exactly once, in `Find-Tf.ps1`.
2. **Direct mode is byte-transparent.** The child `tf.exe` inherits stdout; stderr is relayed byte for byte.
   No PowerShell re-encoding, no stdin consumption, same exit code.
3. **The worker is a narrow executor.** It runs only a Microsoft-signed `tf.exe`, only from an argument array,
   never an expired request, and nothing else.

## 5. File layout

Plugin, under `plugins/claude-tfvc/`:

| Path | Status | Role |
|---|---|---|
| `skills/tfvc/scripts/Find-Tf.ps1` | modified | tf.exe resolver. `Get-ProjectTfSetting` generalised to `Get-ProjectEnvSetting -Name`, used for `TF_EXE` and `TFVC_TRANSPORT`. Resolution order unchanged. |
| `skills/tfvc/scripts/Invoke-Tf.ps1` | new | The launcher: transport selection, direct mode, relay client. |
| `skills/tfvc/scripts/Tf-RelayWorker.ps1` | new | The worker that the scheduled task runs. |
| `skills/tfvc/scripts/Register-TfRelay.ps1` | new | Register (default), `-Unregister`, `-Status`. |
| `commands/tf-relay.md` | new | `/tf-relay [status\|on\|off\|auto]`. |
| `hooks/tfvc-checkout.ps1` | modified | Calls `Invoke-Tf` instead of `tf.exe`; reports failures via `additionalContext`. |
| `hooks/hooks.json` | modified | Timeout 30 s → 45 s. |
| `commands/tf-*.md` (5) | modified | "resolve tf.exe per the skill" → "run tf per the skill". |
| `skills/tfvc/SKILL.md` | modified | "Running tf" section, TF30063 row, new triggers. |
| `.claude-plugin/plugin.json`, `../../.claude-plugin/marketplace.json` | modified | Version 0.4.0. |

Repository: `README.md`, `CHANGELOG.md`, `CLAUDE.md` updated; `tests/test-relay.ps1` new; `tests/test-hook.ps1`
extended.

Runtime state, in the user profile (never in a project, never in the versioned plugin cache):

```text
%LOCALAPPDATA%\claude-tfvc\relay\
  Tf-RelayWorker.ps1      installed copy of the worker (the task points here)
  worker.version          version=<plugin version>  sha256=<hash of the plugin's worker source>
  worker.lock             held open exclusively by the running worker
  worker.log, worker.1.log
  queue\<guid>.req.json | .run.json | .res.json | .tmp
```

All four PowerShell scripts run under Windows PowerShell 5.1 (and pwsh), are pure ASCII without BOM, and keep
the `$MyInvocation.InvocationName -ne '.'` guard so dot-sourcing only defines functions.

## 6. Invoke-Tf.ps1

### 6.1 Command-line contract

```text
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>/scripts/Invoke-Tf.ps1" <tf arguments>
```

- No `param` block. `$args` receives every token verbatim, including `-noprompt`, `/noprompt`,
  `/comment:...`. Nothing is interpreted; nothing is joined into a string for a shell.
- Works identically from the PowerShell tool and from Git Bash.
- stdout and stderr carry `tf`'s output (section 6.4 and 6.5). Nothing else is printed on success.
- Exit code: `tf`'s own code, or a launcher code from the table below.

| Exit code | Meaning |
|---|---|
| `tf`'s (0, 1, 2, 100) | passed through unchanged |
| 120 | relay unavailable: task not registered, failed to start, or the worker refused the request |
| 124 | relay timeout: request not picked up, or not finished, in time |
| 127 | `Find-Tf.ps1` found no `tf.exe` |

### 6.2 Function contract (used by the hook)

Dot-sourcing defines:

- `Resolve-TfTransport -ProjectDir` → object `{ Transport, Setting, Source, Remote, TaskRegistered }`.
  `Transport` is `direct` or `relay`; `Setting` is the configured value (`auto`, `direct`, `relay`); `Source`
  is `settings.local.json`, `settings.json`, `env`, or `default`; `TaskRegistered` is `$null` when it was not
  needed.
- `Invoke-Tf -Arguments <string[]> [-ProjectDir] [-Capture] [-TimeoutSec] [-PickupTimeoutSec]` → object
  `{ ExitCode, StdOut, StdErr, Transport, Diagnostic }`. Without `-Capture`, direct mode streams to the console
  and `StdOut` is `$null`. `Diagnostic` is a human-readable explanation when `ExitCode` is 120/124/127, else
  `$null`.
- `Invoke-TfDirect`, `Invoke-TfRelay`, `Test-TfRelayWorkerAlive`, `Get-TfRelayPaths` as internals, also
  reachable by `Register-TfRelay.ps1 -Status`.

The script body is `exit (Invoke-Tf -Arguments $args).ExitCode` after writing the captured relay output.

### 6.3 Transport selection

`TFVC_TRANSPORT` is read like `TF_EXE`: project `.claude\settings.local.json`, then project
`.claude\settings.json` (`env.TFVC_TRANSPORT`, via `Get-ProjectEnvSetting`), then the environment variable.
The project is `CLAUDE_PROJECT_DIR`, else the hook payload's `cwd`, else the current directory. Values are
case-insensitive `auto` (default), `direct`, `relay`. An unknown value is treated as `auto` with one warning
line on stderr.

| Setting | Behaviour |
|---|---|
| `direct` | always direct; no scheduler call, no hint |
| `relay` | always relay; when the worker is not alive and the task is missing, exit 120 with the registration command |
| `auto` | relay iff the session is **remote** and the relay is **available**; otherwise direct |

- **Remote** means `SSH_CONNECTION` or `SSH_CLIENT` is set in the environment. Claude Code's Bash tool exposes
  them; the hook process inherits them from Claude Code. (To confirm on the real machine: see section 19.)
- **Available** means a worker is alive (`worker.lock` held, section 7.3) or `Get-ScheduledTask
  -TaskName ClaudeTfvcRelay` finds the task. The scheduler query costs one module import (about half a second)
  and runs only in remote sessions with no live worker. Local sessions never pay it.

### 6.4 Direct mode

`tf.exe` starts as a `System.Diagnostics.Process` with `UseShellExecute = $false`, `RedirectStandardOutput =
$false`, `RedirectStandardInput = $false`, `RedirectStandardError = $true`, working directory the current one.

- stdout and stdin are inherited handles: bytes flow `tf.exe` → Claude Code untouched, exactly as in 0.3.0.
- stderr is read from `StandardError.BaseStream` in chunks; each chunk is written unchanged to
  `[Console]::OpenStandardError()` and also kept in a memory buffer. After exit, the buffer is decoded with
  `[System.Text.Encoding]::Default` and searched for `TF30063`.
- On a hit, and only when the transport was chosen by `auto` (not forced `direct`), one line is appended to
  stderr:
  `claude-tfvc: TF30063 usually means this session has no network credentials (SSH key logon). Run /tf-relay to route tf through your interactive Windows session.`
- Exit code = `$process.ExitCode`.

With `-Capture` (hook) both streams are redirected, read asynchronously, decoded with the system ANSI
encoding and returned in the result object.

### 6.5 Relay mode output

The response's `stdout` and `stderr` strings are written to the launcher's stdout and stderr with
`[Console]::OutputEncoding` set to UTF-8 without BOM, so Hebrew and Cyrillic in paths and comments reach Claude
Code intact. This is the one visible difference from direct mode, and it is an improvement, not a regression.

## 7. Relay protocol

### 7.1 Files

| File | Written by | Meaning |
|---|---|---|
| `<guid>.req.json` | client | request waiting to be claimed |
| `<guid>.run.json` | worker (rename) | claimed, `tf` running |
| `<guid>.res.json` | worker | response waiting for the client |
| `*.tmp` | both | in-progress write, renamed into place when complete |

Every file is written to a `.tmp` name and renamed (`[System.IO.File]::Move`) into its final name. A rename
within one NTFS directory is atomic, so no reader ever sees a partial file. One file per request: parallel
`Edit` calls fire the hook concurrently and must never overwrite each other (the One.Net prototype's single
`request.json` did).

### 7.2 Request and response

```json
{
  "protocol": 1,
  "id": "6f1d0d4a-....",
  "tf": "C:\\Program Files (x86)\\...\\TF.exe",
  "args": ["checkout", "/noprompt", "D:\\Projects\\X\\File.cs"],
  "cwd": "D:\\Projects\\X",
  "createdUtc": "2026-10-11T07:00:00.000Z",
  "expiresUtc": "2026-10-11T07:00:30.000Z"
}
```

```json
{
  "id": "6f1d0d4a-....",
  "exitCode": 0,
  "stdout": "File.cs\r\n",
  "stderr": "",
  "error": null,
  "workerVersion": "0.4.0",
  "startedUtc": "2026-10-11T07:00:01.200Z",
  "finishedUtc": "2026-10-11T07:00:02.900Z"
}
```

- `args` is always an array. The worker never joins arguments for an interpreter; `Invoke-Expression` and
  `cmd /c` do not appear anywhere.
- `error` is non-null only when the worker refused the request (unsupported `protocol`, executable rejected,
  process failed to start). The client prints `error` to stderr and exits 120.
- UTF-8 without BOM, `ConvertTo-Json` / `ConvertFrom-Json`, written through `[System.IO.File]::WriteAllText`
  with `UTF8Encoding($false)`.

### 7.3 Worker liveness: `worker.lock`

The worker opens `relay\worker.lock` with `FileShare.None` and keeps it open for its whole life. A second
instance that cannot open it exits immediately. The client probes the lock the same way and releases it at
once; "cannot open" means a worker is alive and will drain the queue.

This replaces most scheduler queries: the fast path never calls `Start-ScheduledTask` while a worker lingers,
`auto` checks task registration only when no worker is alive, and the test harness runs the worker as a plain
child process. If a worker loses the probe race and exits, the client's re-kick (section 8, step 4) starts
another.

## 8. Client algorithm (`Invoke-TfRelay`)

1. **Install or refresh the worker** (section 10.4).
2. **Write the request** with `expiresUtc = now + PickupTimeoutSec`.
3. **Kick**: if the lock is free, `Start-ScheduledTask -TaskName ClaudeTfvcRelay`. Errors are kept for the
   diagnostic, not fatal yet.
4. **Poll** every 150 ms for `<id>.res.json`. Every 2 s, while `<id>.req.json` still exists (unclaimed) and
   the lock is free, kick again. This closes the lost-wakeup gap: the worker may have finished its last scan an
   instant before the request appeared.
5. **Fail fast**: 5 s after a kick, if the lock is still free and `Get-ScheduledTaskInfo` reports a
   `LastTaskResult` from the known launch-failure set (section 10.3), stop waiting; exit 120 with the decoded
   message.
6. **Pickup timeout**: when `PickupTimeoutSec` elapses and `<id>.req.json` still exists, delete it and exit
   124 with "waited N s, task state X, last result Y". If the delete fails because the worker renamed it in
   that instant, treat the request as claimed and keep waiting.
7. **Overall timeout**: when `TimeoutSec` elapses after a claim, exit 124. `tf` keeps running in the worker to
   completion; the orphaned response is swept by the worker within the hour. This is deliberate: a half-done
   `checkin` is worse than a late one, and the client cannot abort a process in another session anyway.
8. **Response**: read, delete `<id>.res.json`, return the result.

| Caller | PickupTimeoutSec | TimeoutSec |
|---|---|---|
| command line (skill, `/tf-*`) | 30 | 600, or `TFVC_RELAY_TIMEOUT` (seconds) when set |
| hook | 15 | 20 (hook timeout in `hooks.json` is 45) |

600 s matches the longest Bash/PowerShell tool timeout Claude Code allows; if the tool kills the client first,
step 7's reasoning applies.

## 9. Worker (`Tf-RelayWorker.ps1`)

### 9.1 Startup and loop

1. Take `worker.lock` or exit silently (another instance is running).
2. Set `[Console]::OutputEncoding` to `[System.Text.Encoding]::Default`. A .NET console app such as `tf.exe`
   picks its output encoding from the console code page when it has a console and from the ANSI page when it
   has none; after this step both paths yield ANSI, which the worker decodes.
3. Log `start <version>`.
4. Loop:
   - Every 60 s (and at start) **sweep**: delete `*.res.json`, `*.run.json`, `*.tmp` and `*.req.json` whose
     last write is older than 60 minutes.
   - Pick the oldest `*.req.json` (by last write time). If none: when idle for longer than the linger (15 s,
     `CLAUDE_TFVC_RELAY_LINGER_SEC` overrides), exit; else sleep 200 ms and repeat.
   - **Claim** it by renaming to `.run.json`. If the rename fails, another instance took it; continue.
   - **Process** (9.2), then delete the `.run.json`.
5. After 50 minutes of life, stop claiming new requests and exit as soon as the current one (if any) has been
   answered. The task's one-hour `ExecutionTimeLimit` then never kills a running `tf`; the client's re-kick
   starts a fresh worker for the next request.

### 9.2 Processing one request

In order; the first failing step ends processing:

1. Parse JSON. Unparseable → delete, log `malformed`.
2. `protocol` ≠ 1 → respond with `error = "protocol N not supported by worker <version>; update the plugin's worker (run any tf command or Register-TfRelay.ps1)"`.
3. `expiresUtc` in the past → delete, log `expired`, **no `tf` run, no response**. A `checkin` or `undo`
   executed "sometime later" after its client gave up is unacceptable.
4. Executable check (cached per path for the worker's life): file name is `tf.exe` (case-insensitive) and
   `Get-AuthenticodeSignature` returns `Valid` with a signer whose subject contains `O=Microsoft Corporation`.
   Otherwise `error = "refusing to run <path>: not a Microsoft-signed tf.exe"`. The only bypass is the environment
   variable `CLAUDE_TFVC_RELAY_ALLOW_UNSIGNED=1` in the **worker's** environment, which a request file cannot set.
5. Add `/noprompt` unless an argument already matches `^[/-]noprompt$` (case-insensitive). The worker is
   invisible; any `tf` dialog would hang until the timeout.
6. Build the command line with **`CommandLineToArgvW` quoting**: an argument is used as-is when it is non-empty
   and contains no space, tab, newline or `"`; otherwise it is wrapped in quotes, each `"` becomes `\"` preceded
   by doubled backslashes, and trailing backslashes are doubled before the closing quote. .NET Framework's
   `ProcessStartInfo` has no `ArgumentList`, so this is hand-rolled as `ConvertTo-CommandLine` and unit-tested.
7. Start: `UseShellExecute = $false`, `CreateNoWindow = $true`, `WorkingDirectory = cwd`,
   `RedirectStandardInput = $true` then `StandardInput.Close()` immediately (prompts read end-of-file),
   `RedirectStandardOutput/Error = $true` with `StandardOutputEncoding = StandardErrorEncoding =
   [System.Text.Encoding]::Default`. Both streams are read with `ReadToEndAsync()` before `WaitForExit()` to
   avoid pipe deadlocks. Start failure → `error` with the exception message.
8. Write the response, log one line: `<utc> <id> <first arg> exit=<n> <ms>ms`.

### 9.3 Log

`relay\worker.log`; when it exceeds 1 MB it is renamed to `worker.1.log` (replacing the previous one). Lines
contain timestamps, request ids, the first `tf` argument, exit codes, durations and lifecycle events. They never
contain comments, further arguments, paths, or `tf` output.

### 9.4 Test seams

All are environment variables of the client or worker process. The scheduler populates the worker's environment
from the user's own environment block, so nothing in a request can reach them.

| Variable | Read by | Effect |
|---|---|---|
| `CLAUDE_TFVC_RELAY_ROOT` | both | relocates the `relay\` folder (default `%LOCALAPPDATA%\claude-tfvc\relay`) |
| `CLAUDE_TFVC_RELAY_LAUNCH=child` | client | spawns the installed worker as a hidden child `powershell.exe` instead of `Start-ScheduledTask`, and treats the task as registered |
| `CLAUDE_TFVC_RELAY_LAUNCH=none` | client | treats the task as not registered and never starts anything |
| `CLAUDE_TFVC_RELAY_LINGER_SEC` | worker | linger after the queue empties (default 15) |
| `CLAUDE_TFVC_RELAY_ALLOW_UNSIGNED=1` | worker | skips the signature check (name must still be `tf.exe`) |

## 10. Register-TfRelay.ps1

### 10.1 Register (default)

1. Create the relay folder and `queue\`.
2. Install the worker copy and write `worker.version` (10.4).
3. `Register-ScheduledTask -TaskName ClaudeTfvcRelay -Force` with:
   - **Action**: `powershell.exe` with arguments
     `-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "<relay>\Tf-RelayWorker.ps1"`,
     working directory `<relay>`. The path is absolute and lives outside the versioned plugin cache
     (`...\cache\claude-tfvc\claude-tfvc\<version>\` disappears on update), so the task survives plugin updates.
   - **Principal**: `New-ScheduledTaskPrincipal -UserId "<DOMAIN>\<user>" -LogonType Interactive -RunLevel Limited`.
     No password is stored or asked for.
   - **Settings**: `-MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
     -ExecutionTimeLimit (New-TimeSpan -Hours 1)`; no triggers (on-demand only).
4. **Smoke test**: `Start-ScheduledTask`, wait up to 5 s for `worker.lock` to be taken, report "worker started
   in the interactive session" or the decoded `LastTaskResult`.

Idempotent. Prints what it did and the exact `/tf-relay` follow-up.

### 10.2 `-Unregister` and `-Status`

`-Unregister` removes the task (`Unregister-ScheduledTask -Confirm:$false`) and the relay folder. If a worker
holds the lock it waits up to the linger time, then reports what it could not delete.

`-Status` prints a plain-text, key-per-line report and exits 0 when the relay is usable, 1 otherwise:

```text
Session:          remote (SSH_CONNECTION set)
Transport:        relay   (TFVC_TRANSPORT=auto from default; task registered)
Task:             registered, state Ready, last run 2026-10-11 09:58:12, last result 0x0 (success)
Worker:           installed 0.4.0, matches plugin
Queue:            C:\Users\gabi\AppData\Local\claude-tfvc\relay\queue  (0 waiting, 0 running, 0 orphaned)
Probe:            tf workspaces /noprompt via relay: exit 0 in 1.8 s
```

The probe uses `Invoke-TfRelay` directly with the resolved `tf.exe` and the current directory; `-NoProbe`
skips it. When the task is missing, the report ends with the exact registration command line
(`powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\Register-TfRelay.ps1"`).

### 10.3 Decoded failure codes

| Observation | Message |
|---|---|
| task not registered | "relay task ClaudeTfvcRelay is not registered; run: <command>" |
| `LastTaskResult` `0x00041303` | "the task could not start because you are not logged on to Windows interactively; connect once over RDP (you may disconnect afterwards, do not sign out)" |
| `0x8007052E` | "logon failure; the task's user does not match the current account or the password changed; re-run the registration" |
| `0x80070569` | "this logon type is denied by domain policy for scheduled tasks" |
| `0x800710E0` | "the task refused to start (policy or task conditions); check Task Scheduler" |
| lock held, request unclaimed past pickup timeout | "a worker is running but did not pick up the request; see worker.log" |
| timeout | "waited N s for the relay; task state X, last result Y" |

The hex codes come from the One.Net prototype, where each was met in practice. The task runs as long as the
user has an interactive session; after a reboot or sign-out one RDP logon is needed again. README says so.

### 10.4 Worker refresh

The client, on every relay call, hashes the plugin's `Tf-RelayWorker.ps1` (`Get-FileHash`, SHA-256) and
compares it with `worker.version`. On mismatch or missing file it writes the new copy to a `.tmp` name, renames
it over the installed one, and rewrites `worker.version` (`version=` from `plugin.json`, `sha256=`). A running
worker has already loaded its script, so the replacement is safe; the next start runs the new file. The task
definition never changes, so updating the plugin never requires re-registration. The hash, not the version
number, is compared so that development iterations within one version also refresh.

## 11. Hook (`tfvc-checkout.ps1`)

Invariants preserved: acts only on a read-only target, always `exit 0`, never blocks, loads nothing until a
read-only file is actually seen.

Changes:

1. On a read-only file, dot-source `..\skills\tfvc\scripts\Invoke-Tf.ps1` (which dot-sources `Find-Tf.ps1`).
2. Call `Invoke-Tf -Arguments @('checkout', '/noprompt', $file) -ProjectDir $projectDir -Capture
   -PickupTimeoutSec 15 -TimeoutSec 20`. `$projectDir` is `CLAUDE_PROJECT_DIR`, else the payload `cwd`, else
   the current directory, as today; it also becomes the request's `cwd`.
3. Exit code 0 → print nothing, exit 0 (the existing check T1 "no output" keeps passing).
4. Otherwise print, as UTF-8, and still exit 0:

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse",
  "additionalContext":"claude-tfvc: tf checkout of D:\\Projects\\X\\File.cs failed (direct, exit 100): TF30063: You are not authorized ... This session has no network credentials; run /tf-relay to route tf through your interactive Windows session."}}
```

   `additionalContext` is documented for PreToolUse as "a string added to Claude's context alongside the tool
   result". The remedy text is the decoded message from 10.3 or the TF30063 hint. `systemMessage` (shown to the
   user) is not documented for PreToolUse; it is added only if the empirical check in section 19 shows it is
   displayed.
5. `hooks.json`: `timeout` 30 → 45, leaving margin over the 20 s relay budget plus module import.

## 12. `/tf-relay` command (`commands/tf-relay.md`)

`/tf-relay [status | on | off | auto]`, default `status`. Frontmatter: `description`, `argument-hint`.

- **status**: run `Register-TfRelay.ps1 -Status` from the skill folder and summarise the report. If the task is
  not registered: show the exact registration command, explain that the worker needs an interactive Windows
  session, and **ask whether to run the registration now**. Run it only after an explicit yes. If registration
  fails from the current session, say to run the same command from an RDP or console session.
- **on** / **off** / **auto**: write `env.TFVC_TRANSPORT` = `relay` / `direct` / remove the key in
  `<project>\.claude\settings.local.json`, merging into the existing file exactly like `/tf-select` (keep every
  other key, create the folder/file if missing, valid JSON, never touch `~/.claude/settings.json`). `on` first
  runs `status`, so a missing task is offered for registration before the setting is written.

## 13. Skill, commands, documentation, versioning

- **SKILL.md**: "Finding tf.exe" becomes "Running tf": below, `tf` stands for
  `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/Invoke-Tf.ps1"`; it picks
  direct or relay transport by itself; `Find-Tf.ps1 -List` remains for `/tf-select`. The common-mistakes table
  gets a row: "TF30063 / not authorized in an SSH or Remote-SSH session → `/tf-relay`". The `description` adds
  the triggers TF30063, "not authorized", SSH, Remote-SSH, remote session, and stays under 1024 characters. The
  body stays near 500 words.
- **Commands**: the five `tf-*.md` say "run `tf` per the `tfvc` skill" instead of "resolve `tf.exe`".
- **README**: new section "Remote sessions (SSH)": symptom (TF30063), why (network logon without delegable
  credentials), how the relay works (one paragraph and the diagram), one-time setup (`/tf-relay` or the
  registration command, run once; after reboot or sign-out log in once over RDP), limitations (needs an
  interactive Windows session; the same user; Windows only), security (section 15), a `permissions` example:

  ```json
  { "permissions": { "ask": [
      "Bash(*Invoke-Tf.ps1*checkin*)",  "Bash(*Invoke-Tf.ps1*undo*)",
      "PowerShell(*Invoke-Tf.ps1*checkin*)", "PowerShell(*Invoke-Tf.ps1*undo*)" ] } }
  ```

  Permission rules match the whole command text, `*` may appear anywhere, and `ask` rules still prompt even
  when a hook allows. One sentence notes that an SSH logon with a password gives a session with credentials, so
  the relay is then unnecessary (verified on the real machine before publishing, section 19).
- **CLAUDE.md** (repo): new invariants: `tf` runs only through `Invoke-Tf.ps1`; direct mode is byte-transparent;
  the worker never runs an expired request and only a Microsoft-signed `tf.exe`; four PowerShell files, all
  5.1-compatible ASCII; the relay folder lives in the user profile and the task points there.
- **CHANGELOG**: a dated `[0.4.0]` entry with Added / Changed / Fixed; `plugin.json` and `marketplace.json`
  bumped together (test T11 enforces agreement).

## 14. Tests

### 14.1 `tests/test-relay.ps1` (new)

Same conventions as `test-hook.ps1`: runs each case under Windows PowerShell 5.1 and pwsh, console input code
page 862, fixtures under `%TEMP%\claude\tfvc-tests\relay`, `PASS`/`FAIL`/`SKIP` rows, exit code = failures.

**Fake `tf.exe`**: compiled at test time from inline C# with the .NET Framework `csc.exe` (SKIP everything that
needs it when `csc` is missing). It appends every argument on its own line to `tf-calls.log` next to the exe,
framed per call (`--- call ---`), and understands `/exit:N` (exit code), `/sleep:N` (seconds),
`/ansi` (writes a fixed non-ASCII sample through `Console.OpenStandardOutput()` encoded with `Encoding.Default`)
and `/stderr:<text>` (writes the text to stderr). The expected decoded sample is
`Encoding.Default.GetString(Encoding.Default.GetBytes(sample))`, so the check is independent of the machine's
ANSI page.

Seams used: `CLAUDE_TFVC_RELAY_ROOT` → fixture folder, `CLAUDE_TFVC_RELAY_LAUNCH=child`,
`CLAUDE_TFVC_RELAY_LINGER_SEC=1`, `CLAUDE_TFVC_RELAY_ALLOW_UNSIGNED=1`. A fake project folder carries
`.claude\settings*.json` with `TFVC_TRANSPORT` values.

| # | Spec check | Test |
|---|---|---|
| 1 | direct: args, output, exit code equal a direct fake-tf run | R1: run both ways with `/exit:0`, `/exit:1`, `/exit:100`; compare log, stdout, stderr, exit |
| 2 | relay: same through the queue, exit codes 0/1/100 pass through | R2 |
| 3 | spaces, quotes, `&`, `%`, trailing `\`, Hebrew, Cyrillic reach `tf` unchanged, from PowerShell and Git Bash | R3 (PowerShell, direct and relay), R3b (Git Bash, SKIP without bash); also `/noprompt` vs `-noprompt` from Git Bash, result documented in SKILL.md |
| 4 | ANSI (Hebrew) `tf` output is readable at the client | R4: `/ansi` through relay, decoded output equals the expected sample |
| 5 | 10 parallel requests: each gets its own answer, none lost or run twice | R5: 10 clients started with `Start-Process`, log shows exactly 10 calls with 10 distinct markers |
| 6 | expired request is not run | R6: drop a `.req.json` with `expiresUtc` in the past, start the worker, log has no call, file is gone |
| 7 | client timeout: exit 124, request deleted, worker never runs it | R7: `CLAUDE_TFVC_RELAY_LAUNCH=none` with a 2 s pickup timeout → 124 and no `.req.json`; then start a worker, log stays empty |
| 8 | `/noprompt` added when absent, not duplicated when present | R8: log shows exactly one `/noprompt` in both cases (also with `-noprompt`) |
| 9 | transport selection order and `auto` logic | R9: settings.local.json > settings.json > env; `auto` with/without `SSH_CONNECTION`, with `LAUNCH=child` vs `none`; `Resolve-TfTransport` via dot-source |
| 10 | hook in relay mode: read-only file → checkout through the queue; any relay failure → exit 0 | R10: hook with `TFVC_TRANSPORT=relay` + child launch → log has `checkout /noprompt <path>`; with `LAUNCH=none` → exit 0 and stdout holds `additionalContext` JSON |
| 11 | hook in non-TFVC project / writable file still starts nothing | covered by existing T3a/T3b/T3c in `test-hook.ps1`, and R11 asserts no `relay\` folder appears |
| 12 | worker refuses a non-signed `tf.exe` without the bypass | R12: fake `tf.exe` with the bypass unset → response `error` mentions "not a Microsoft-signed", exit 120, no call in the log |
| – | quoting | R13: `ConvertTo-CommandLine` round-trips through a C# echo stub (`Environment.GetCommandLineArgs`) for a table of hard cases |
| – | exit code 127 | R14: no `tf.exe` anywhere → 127, nothing on stdout |
| – | TF30063 hint | R15: direct, `/stderr:TF30063...`, `auto` → hint line present; forced `direct` → absent |
| – | worker refresh | R16: stale `worker.version` → client rewrites the copy before the request |

### 14.2 `tests/test-hook.ps1` (extended)

Every existing check stays unchanged and must pass (acceptance 6). Added: the three new scripts in the T10 ASCII
check; T24 "the hook calls `Invoke-Tf` and contains no direct `tf` invocation"; T11 already enforces 0.4.0 in
both manifests and the changelog.

### 14.3 Acceptance on the real machine

Run on DEVELOPER4 from an SSH key logon (VS Code Remote-SSH), on-prem TFS, server workspace, task registered,
with an active or disconnected RDP session:

1. `Edit` of a read-only file: `tf status` shows `edit`, the edit is applied, no manual step.
2. Five `Edit` calls on different read-only files in a row and in parallel: all checked out.
3. `/tf-status`, `/tf-checkout`, `/tf-get`, `/tf-undo`, `/tf-checkin` work; `/tf-checkin` still asks.
4. A check-in comment with Hebrew, quotes and `&` is stored on the server unchanged; `tf` output with Hebrew is
   readable.
5. With no interactive Windows session: clear message that an RDP logon is needed; the edit is not blocked.
6. In the console session the plugin behaves like 0.3.0; `tests\test-hook.ps1` passes.
7. After installing the next plugin version the relay keeps working without re-registration.

## 15. Security

- The relay runs commands in the interactive session with the user's network rights. That is the purpose; the
  surface is kept minimal: only a `tf.exe` with a valid Microsoft Authenticode signature, only an argument array,
  no string interpretation, no shell.
- Queue, lock, log and worker copy live under `%LOCALAPPDATA%` with its default ACL (owner, SYSTEM,
  Administrators). Nothing is world-writable; nothing lives in a project folder.
- No password, PAT or token is stored, asked for, or transmitted. The task has no stored credentials.
- The log never records comments, arguments beyond the first, or `tf` output.
- Test seams are environment variables of the worker process, filled by the scheduler from the user's own
  environment block; a request file cannot set them.
- Check-in and undo confirmation remains where it is: the skill's rules of engagement and, because the command
  line is now stable, the `permissions.ask` rules shown in README.

## 16. Performance

- Direct mode: one extra `powershell.exe` start per call from the skill or a command. In the hook no extra
  process at all.
- Relay mode: target under 3 s on top of `tf` itself. Cold path: `Start-ScheduledTask` (module import plus
  task launch, about 1.5 s) and the worker's PowerShell start (about 0.5 s). Warm path with a lingering worker:
  file write plus polling, well under half a second, with no scheduler call.
- The hook fires only for read-only files, that is once per file.

## 17. Compatibility

- Without a registered task and without `TFVC_TRANSPORT`, 0.3.0 behaviour is preserved; the only change is
  that the skill and commands run `tf` through `Invoke-Tf.ps1`, and `tf`'s stderr now passes through the
  launcher byte for byte.
- `TF_EXE`, `/tf-select`, the `tf.exe` resolution order: unchanged.
- Git Bash converts `/option` into a path; `tf` also accepts `-option`. Test R3b decides whether SKILL.md keeps
  "both work" or recommends `-option` from Bash.

## 18. Decisions taken during review

| Topic | Decision |
|---|---|
| Direct mode vs TF30063 hint (spec 4.1 contradiction) | Capture **stderr only**, byte-transparently; stdout inherited. Hint on TF30063 when the transport came from `auto`. |
| Registration from the SSH session (spec 4.6) | `/tf-relay` offers to register and runs `Register-TfRelay.ps1` after an explicit yes. Expected to work; if not, the message says to run it from RDP/console. |
| Worker liveness and lost wakeups | `worker.lock` held exclusively; client re-kicks every 2 s while unclaimed and lock free. |
| Worker update detection | SHA-256 of the plugin's worker vs `worker.version`; version number recorded for display only. |
| Linger (spec 5, optional) | Implemented, 15 s; env override for tests. 50-minute life cap under the 1-hour task limit. |
| Status probe command | `tf workspaces /noprompt` from the current directory. |
| Script placement | All four scripts in `skills/tfvc/scripts/`; lifecycle in one script with `-Unregister`/`-Status`. |
| Tests | New `tests/test-relay.ps1`; `test-hook.ps1` existing checks untouched. |
| Hook feedback (spec 4.5) | `hookSpecificOutput.additionalContext` on failure only, nothing on success. |
| Launcher exit codes | 120 relay unavailable, 124 timeout, 127 no `tf.exe`. |
| Design doc language and place | English, `docs/specs/`, next to the requirements spec (itself rewritten in English). |

## 19. To verify empirically during implementation

Each item has a planned fallback, so none blocks the design:

1. **`Register-ScheduledTask` with `LogonType Interactive` from an SSH session** on DEVELOPER4. Fallback:
   `/tf-relay` tells the user to run the command from RDP/console.
2. **`systemMessage` display for PreToolUse hooks.** Fallback: `additionalContext` only.
3. **`powershell -File` argument fidelity** for embedded quotes and trailing backslashes from PowerShell and
   Git Bash (R3/R3b). Fallback: document the limitation in SKILL.md (for example single quotes inside comments).
4. **`/option` from Git Bash** (MSYS path conversion). Fallback: SKILL.md recommends `-option` from Bash.
5. **Real `tf.exe` output code page under the worker** (acceptance 4). The worker pins the console code page
   to ANSI, which should make it moot; if real output arrives in the OEM page, decode with
   `[Console]::OutputEncoding` captured before step 9.1.2 instead.
6. **SSH password logon carries credentials** (README sentence). Fallback: drop the sentence.
7. **`SSH_CONNECTION` visible to the hook process** under Claude Code. Fallback: also accept a
   `CLAUDE_TFVC_REMOTE=1` setting, read like `TFVC_TRANSPORT`.

## 20. Out of scope, noted for later

`/tf-checkin` without a path checks in the whole pending set of the workspace. In One.Net that set holds about
4900 stale pending changes, so the call is dangerous. A separate task should make `/tf-checkin` always show and
check in an explicit file list, and refuse a large pending set when no path is given.
