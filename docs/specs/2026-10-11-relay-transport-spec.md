# claude-tfvc: relay transport for sessions without network credentials (SSH)

Specification for the developer of the `claude-tfvc` plugin (repository `jenka1980/claude-tfvc`, current version
0.3.0). Target version: 0.4.0.

## 1. Problem

The plugin calls `tf.exe` directly: in the hook (`hooks/tfvc-checkout.ps1`), in the `/tf-*` commands and per the
skill's instructions. This does not work when Claude Code runs in a session that has no Windows network
credentials. The typical case: logging on to a dev machine over SSH with a key (VS Code Remote-SSH). Such a session
gets a network logon without delegable credentials, and an on-prem TFS with Windows authentication answers:

```
TF30063: You are not authorized to access <server>\<collection>.
```

Reproduced on a real project (Windows 10, OpenSSH with a key, domain user, VS 2017 `TF.exe` 15.x, server
workspace, Claude Code 2.1.296, Bash tool = Git Bash):

```
"<...>/Team Explorer/TF.exe" status "D:/Projects/X/X.sln" -noprompt
TF30063: You are not authorized to access ...
```

Consequences in 0.3.0:

- The hook cannot run `tf checkout`, swallows the error and exits with code 0. The file stays read-only,
  `Edit`/`Write` fail with access denied, and the cause (TF30063) is visible nowhere.
- Every `/tf-*` command returns TF30063.
- The plugin is useless in such a session; the user has to maintain their own tooling.

## 2. Goal

The plugin must work in an SSH session the same way as in a local one: the hook checks out, `/tf-*` and the skill
run any `tf` command. To that end `tf.exe` runs not in the SSH session but in the interactive Windows session of
the same user (console or RDP, including a disconnected but not signed-out RDP session), where the credentials
exist.

Mechanism: a Windows scheduled task with `LogonType Interactive` and no stored password. The approach is proven in
production on the One.Net project (prototype: `.claude/scripts/tfs.ps1` and `register-tfs-task.ps1`, see
section 9).

### Non-goals

- Storing a password or PAT, `tf /login:user,password`.
- Support for non-Windows clients, running as a different user, remote execution on another machine.
- Changing behaviour in ordinary (local) sessions.
- Restricting the set of `tf` commands with a whitelist: the relay is transport, not policy. Policy stays in the
  skill's rules and in Claude Code `permissions` (section 7).

## 3. Solution overview

1. **A single entry point for running `tf`**: a new script `skills/tfvc/scripts/Invoke-Tf.ps1`. The hook, the
   skill and the commands run `tf` only through it. It picks the transport:
   - `direct`: runs the resolved `TF.exe` in the current process, as today;
   - `relay`: hands the request to a worker in the interactive session and returns its output and exit code.
2. **A worker** `Tf-RelayWorker.ps1`, started by the scheduled task `ClaudeTfvcRelay` in the interactive session,
   drains the request queue and runs `tf.exe`.
3. **One-time registration** of the task by the script `Register-TfRelay.ps1`, which the user runs themselves from
   an interactive session.
4. **The `/tf-relay` command**: status, on/off, diagnostics.

Why a separate `Invoke-Tf.ps1` rather than a "substitute tf" as a `.cmd` that `Find-Tf.ps1` would return:
`cmd.exe` parses the arguments of a `.cmd`, and the text of a check-in comment (`&`, `|`, `%VAR%`, `^`) turns into
mangled arguments or executed commands. A `.ps1` cannot be run directly from Git Bash, and building an `.exe` at
install time is needless complexity. Therefore the launch is always the line
`powershell -File Invoke-Tf.ps1 <tf arguments>`.

## 4. Requirements

### 4.1. `Invoke-Tf.ps1`

- Invocation: `powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>/scripts/Invoke-Tf.ps1" <tf arguments>`.
  All arguments are passed to `tf` as-is, without interpretation. Works from the PowerShell tool and from Git Bash.
- When dot-sourced it only defines functions (the same `$MyInvocation.InvocationName -ne '.'` guard as in
  `Find-Tf.ps1`); the hook uses the function, not a new process.
- The path to `TF.exe` comes only from `Find-Tf.ps1` (the "one resolver" invariant is preserved).
- The script's exit code equals `tf`'s exit code. The transport's own errors use separate codes that do not
  overlap `tf`'s (0, 1, 2, 100): proposed 120 = relay not configured / did not start, 124 = timeout.
- **`direct` mode must not change for the user**: `tf` output passes through byte for byte (the child process
  inherits stdout/stderr, no PowerShell re-encoding), stdin is not read, the exit code is the same.
- If in `direct` mode the output contains `TF30063` and the relay is not configured, one hint line is added to
  stderr: run `/tf-relay`.
- Windows PowerShell 5.1, pure ASCII, no BOM, like the plugin's other scripts.

### 4.2. Transport selection

A setting `TFVC_TRANSPORT` with the values `auto` (default), `direct`, `relay`. Read the same way and in the same
order as `TF_EXE`: `env.TFVC_TRANSPORT` in `<project>\.claude\settings.local.json`, then `settings.json`, then the
environment variable. Implement the reading next to `Get-ProjectTfSetting`, without duplicating logic.

Rule for `auto`: `relay` if both
- the session is remote (`SSH_CONNECTION` or `SSH_CLIENT` is set), and
- the task `ClaudeTfvcRelay` is registered;

otherwise `direct`. Verify that the SSH variables are visible to the hook process (they are visible in the Bash
tool).

`relay` with the task not registered is an error with code 120 and text saying what to do (in the hook: without
blocking, see 4.5).

### 4.3. Exchange protocol

Queue directory: `%LOCALAPPDATA%\claude-tfvc\relay\queue\` (the user profile, not the project directory).

Request `<id>.req.json` (UTF-8 without BOM), `id` is a GUID:

```json
{
  "protocol": 1,
  "id": "…",
  "tf": "C:\\…\\TF.exe",
  "args": ["checkout", "/noprompt", "D:\\Projects\\X\\File.cs"],
  "cwd": "D:\\Projects\\X",
  "createdUtc": "2026-10-11T07:00:00Z",
  "expiresUtc": "2026-10-11T07:00:30Z"
}
```

Response `<id>.res.json` (UTF-8 without BOM):

```json
{ "id": "…", "exitCode": 0, "stdout": "…", "stderr": "…", "startedUtc": "…", "finishedUtc": "…" }
```

Rules:

- Files are written atomically: to a temporary name, then renamed. A reader never sees a half-written file.
- **One file per request.** The prototype had a single `request.json`, and parallel requests overwrote each other;
  hooks fire simultaneously on parallel `Edit` calls, so this is a hard requirement.
- Arguments are passed as an array and never joined into a string for an interpreter (`Invoke-Expression` and
  `cmd /c` are forbidden).
- After writing the request the client calls `Start-ScheduledTask` and waits for the response by polling. If there
  is no response and the task is not in the `Running` state, the client starts it again (protection against a lost
  wakeup: the worker may have finished its scan of the queue an instant before the request appeared).
- On timeout the client deletes its request if the worker has not yet taken it, and returns 124.
- Having received the response, the client deletes the response file.

### 4.4. The worker `Tf-RelayWorker.ps1`

- Processes requests one at a time, oldest first. Before executing, it "claims" the request by renaming it (for
  example to `<id>.run.json`) so that a second instance does not take it.
- After the queue is empty it checks it once more after a short pause and only then exits.
- **Does not execute expired requests** (`expiresUtc` in the past): the client is already gone, and a deferred
  `checkin` or `undo` executed "sometime later" is unacceptable. An expired request is deleted.
- Deletes orphaned request and response files older than an hour.
- Starts `tf.exe` through `System.Diagnostics.Process` with `UseShellExecute = false`, `CreateNoWindow = true`,
  working directory = `cwd` from the request, stdin closed.
- **Argument quoting** follows the `CommandLineToArgvW` rules (escaping `"` and trailing `\`). The prototype
  simply wrapped arguments in quotes, which breaks on comments containing a quote.
- **Always adds `/noprompt`** when it is not among the arguments: the worker runs hidden, and any `tf` dialog
  (check-in, conflict resolution, credential prompt) would hang invisibly until the timeout.
- **Encoding.** `tf.exe` writes redirected output in the system ANSI code page (1255, Hebrew, on the project)
  regardless of the console code page. The worker decodes stdout/stderr as `[Text.Encoding]::Default` and puts
  Unicode into the response. The client prints the result as UTF-8 (`[Console]::OutputEncoding`). Without this,
  Hebrew and Cyrillic in paths and comments turn into `?`.
- **Executable check.** The worker runs only a file named `tf.exe` with a valid Authenticode signature from
  Microsoft; otherwise it refuses with a clear error. A request must not be able to start an arbitrary program in
  the interactive session. For tests there is an explicit test switch (see section 8) that is not reachable through
  the request file.
- An unknown `protocol` gets an error response "update the worker", not silence.
- Keeps a log with size-based rotation (in the prototype the log grew to 3.6 MB without rotation): time, `tf`
  command (first argument), exit code, duration. Comment text and output are not written to the log.

### 4.5. The hook `tfvc-checkout.ps1`

- Invariants are preserved: acts only on a read-only file, always `exit 0`, never blocks an edit, stays an instant
  no-op in non-TFVC projects (the transport scripts are loaded only when a read-only file is actually encountered).
- Calls checkout through the function from `Invoke-Tf.ps1`; the transport is chosen per 4.2.
- The relay timeout in the hook must be noticeably smaller than the hook's own timeout in `hooks.json` (currently
  30 s): proposed 20 s for the relay; raise the hook timeout if necessary.
- Desirable: on checkout failure report the cause without blocking the edit (today Claude only sees the
  access-denied error on write). The method is whichever the current hooks API supports for `PreToolUse` without
  blocking (a message to the user or additional context for the model); check the hooks documentation. Minimum
  text: TF30063 → "run `/tf-relay`"; task did not start → the decoding from 4.7.

### 4.6. Registration and update

`Register-TfRelay.ps1` (run by the user from an interactive session, console or RDP):

- Copies the worker to the stable path `%LOCALAPPDATA%\claude-tfvc\relay\` and writes the plugin version next to
  it. The task must reference this path, not the plugin directory: the plugin cache is versioned
  (`…\cache\claude-tfvc\claude-tfvc\<version>\`), and after a plugin update the path ceases to exist.
- Registers the task `ClaudeTfvcRelay`: current user, `LogonType Interactive`, `RunLevel Limited`, no stored
  password, no triggers (on-demand start only), `MultipleInstances IgnoreNew`, start on battery allowed, execution
  time limit 1 hour. Action:
  `powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File <worker>`.
- Idempotent (`-Force`); has `-Unregister` (removes the task and the relay directory).
- Verify and document whether registration can be performed from the SSH session itself. In the prototype it was
  done only from RDP.

Update: on every call the client compares the plugin version with the version of the installed worker and, on
mismatch, overwrites the worker file itself (atomically). Re-registering the task on a plugin update is not
required, because the path in the task does not change.

### 4.7. Diagnostics

The client distinguishes and explains in human language:

| Situation | Message |
|---|---|
| Task not registered | how to register (the exact `Register-TfRelay.ps1` command line) |
| `LastTaskResult` `0x00041303` (task did not start) | the user is not logged on to Windows: connect over RDP once and close the window without signing out |
| `0x8007052E` | logon failure |
| `0x80070569` | logon type denied by domain policy |
| `0x800710E0` | the task refused to start (policy or conditions) |
| Timeout | how long we waited, what state the task is in |

The codes come from the prototype, where they were met in practice. The task works while the user is logged on to
Windows; after a reboot or sign-out one RDP logon is needed; this must be in the README.

### 4.8. The `/tf-relay` command

`/tf-relay [status | on | off | auto]`, default `status`:

- `status`: the effective transport and where it came from (like `/tf-select` for `TF_EXE`), whether the task is
  registered, its state and `LastTaskResult`, the worker version, whether the session is remote; then a probe
  call through the relay (`tf workspaces` or `tf status` of a single file) with timing. If the task is not
  registered: prints the exact registration command and explains that it must be run in an RDP/console session.
- `on` / `off` / `auto`: writes `env.TFVC_TRANSPORT` (`relay` / `direct` / removes the key) in
  `<project>\.claude\settings.local.json` by the same rules as `/tf-select`: merge with the existing file, do not
  touch `~/.claude/settings.json`.

### 4.9. Skill, commands, documentation

- `SKILL.md`: replace the "Finding tf.exe" section with "Running tf": "below, `tf` means
  `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/Invoke-Tf.ps1"`";
  `Find-Tf.ps1 -List` remains for `/tf-select`. Add a row to the mistakes table about TF30063 in an SSH session →
  `/tf-relay`. Add the triggers `TF30063`, "not authorized", SSH/remote to the `description`. Body size within the
  previous limits (~500 words).
- `/tf-*` commands: the wording "resolve tf.exe per the skill" → "run tf per the skill".
- README: a "Remote sessions (SSH)" section: the symptom, how it works, the one-time setup, the limitation "an
  active Windows session is needed", security (section 7), an example of `permissions` rules. Mention in one line
  that an SSH logon with a password gives a session with credentials and the relay is then unnecessary (verify
  before publishing).
- The repository's `CLAUDE.md`: new invariants: `tf` runs only through `Invoke-Tf.ps1`; `direct` mode is
  byte-transparent; the worker does not execute expired requests and runs only a signed `tf.exe`.
- `CHANGELOG.md`, version 0.4.0 in both manifests.

## 5. Performance

- `direct` mode: the overhead is one `powershell.exe` start per call from the skill/commands; in the hook there
  are no extra processes.
- `relay` mode: target up to 3 seconds on top of the `tf` command itself (task start and the worker's PowerShell).
  The hook fires only on a read-only file, that is once per file.
- Optional optimisation: after the queue empties, the worker stays alive for N seconds polling the directory, so
  that a series of calls does not pay for the task start every time.

## 6. Compatibility

- Without a registered task and without `TFVC_TRANSPORT`, 0.3.0 behaviour is preserved, except that the skill and
  the commands run `tf` through `Invoke-Tf.ps1`.
- `TF_EXE`, `/tf-select`, the `tf.exe` resolution order: unchanged.
- Git Bash turns arguments of the form `/option` into paths; `tf` accepts `-option`. Verify that both variants work
  through `Invoke-Tf.ps1` from Git Bash, or document `-option` as the recommended form.

## 7. Security

- The relay executes commands in the interactive session with the user's network rights. This is the deliberate
  goal, but the surface must be minimal: only a signed `tf.exe`, only an argument array, no string interpretation,
  the queue directory in the user profile with default ACLs (owner only).
- Passwords and tokens are never stored or transmitted anywhere.
- Check-in comments and `tf` output are not written to the log.
- Check-in/undo confirmation stays at the level of the skill and `permissions`. Since the command line is now
  stable (`… Invoke-Tf.ps1 checkin …`), give an example of `ask` rules for `checkin` and `undo` in the README
  (verify the pattern syntax against the current Claude Code documentation).

## 8. Tests

Extend `tests/test-hook.ps1` (or add `tests/test-relay.ps1` in the same style: PS 5.1 and pwsh, console code page
862, fake tf, SKIP for missing tools). The scheduler is not used in tests: a test seam is needed, an environment
variable that makes the client start the worker as a child process instead of `Start-ScheduledTask`, and the
worker accept the fake tf instead of a signed `tf.exe`.

Mandatory checks:

1. `direct`: arguments, output and exit code match a direct run of the fake tf.
2. `relay`: the same through the queue; `tf`'s exit code is propagated (0, 1, 100).
3. Arguments with spaces, quotes, `&`, `%`, a trailing `\`, Hebrew and Cyrillic reach `tf` unchanged, from
   PowerShell and from Git Bash.
4. `tf` output in the ANSI encoding (Hebrew) reaches the client readable.
5. 10 parallel requests: each gets its own response, none is lost or executed twice.
6. An expired request is not executed (no call in the fake tf log).
7. Client timeout: code 124, the request is deleted, the worker does not execute it later.
8. `/noprompt` is added when absent and not duplicated when present.
9. Transport selection: `settings.local.json` > `settings.json` > environment variable; `auto` with and without
   SSH variables, with and without the task.
10. The hook in `relay` mode: read-only file → checkout through the queue; on any relay error → `exit 0`.
11. The hook in a non-TFVC project and on a writable file still starts nothing.
12. The worker refuses to run a file that is not a signed `tf.exe` (without the test switch).

## 9. Reference: the One.Net prototype

In the One.Net project the same idea is implemented narrowly and works in production:

- the task `ClaudeTfs` (`LogonType Interactive`, no password) runs `tfs.ps1 -FromTask`;
- the client writes `request.json` with an action name, starts the task, waits for `result-<id>.txt`;
- the worker performs a fixed set of actions (`status`, `reconcile /promote`, `diff`, `checkin`, `undo`) over a
  list of tracked files.

What to carry over from the prototype: the way of starting in the interactive session, the decoding of `tf`
output, the decoding of `LastTaskResult` codes, lossless passing of the check-in comment.
What must be fixed: one request file for everyone, naive argument quoting, no request expiry, a log without
rotation, the task bound to a path inside the project.

The user can attach the prototype sources to the task.

## 10. Acceptance criteria

On a machine with SSH key logon, on-prem TFS, server workspace, the task registered and an active (including
disconnected RDP) Windows session:

1. `Edit` of a read-only file: the file is checked out (`tf status` shows `edit`), the edit is applied, no manual
   steps.
2. Five `Edit` calls on different read-only files in sequence or in parallel: all checked out.
3. `/tf-status`, `/tf-checkout`, `/tf-get`, `/tf-undo`, `/tf-checkin` work; `/tf-checkin` still asks for
   confirmation.
4. A check-in comment with Hebrew, quotes and `&` is stored on the server without distortion; `tf` output with
   Hebrew is readable.
5. Without an active Windows session: a clear message that an RDP logon is needed; the edit is not blocked by the
   hook.
6. In a local (non-SSH) session the plugin behaves like 0.3.0; `tests\test-hook.ps1` passes with no changes to the
   existing checks.
7. After updating the plugin to the next version the relay keeps working without re-registering the task.

## 11. Related note (outside this task)

`/tf-checkin` without a path checks in the whole pending set of the workspace. In One.Net the workspace holds about
4900 old pending changes unrelated to the current work, so such a call is dangerous. A separate task should
consider: `/tf-checkin` always shows and checks in an explicit list of files, and with a large pending set and no
path given it refuses and asks for clarification.
