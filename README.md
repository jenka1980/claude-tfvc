# claude-tfvc

A [Claude Code](https://claude.com/claude-code) plugin that teaches Claude to use **TFVC (TFS / Team Foundation
Version Control)** via `tf.exe` instead of git, for Windows .NET projects.

It provides:
- a **knowledge skill** so Claude understands the read-only/checkout model and uses `tf.exe` (not git) in TFVC projects;
- **slash commands** for the everyday loop — `/tf-status`, `/tf-checkout`, `/tf-checkin`, `/tf-get`, `/tf-undo`;
- a **guarded auto-checkout hook** that runs `tf checkout` on a file right before Claude edits it — but only when
  the file is read-only (TFVC's "not checked out" signal), and it **never blocks edits**, so it's a no-op in
  git / non-TFVC projects;
- a **relay for SSH sessions** — when Claude Code runs over SSH without network credentials (`TF30063`), `tf` is executed inside your interactive Windows session through a scheduled task; set up once with `/tf-relay`.

## Requirements
- **Windows** (TFVC's `tf.exe` is Windows-only).
- Visual Studio with Team Explorer (2010 or later), or `tf.exe` otherwise available.
- **Windows PowerShell 5.1** for the hook. It ships with every supported Windows, so there is nothing to install.
  PowerShell 7 (`pwsh`) is **not** required, and gains nothing here: both start the hook in about the same time.
- Git for Windows is optional. Claude runs `tf` from whichever shell tool it has (PowerShell or Git Bash); `tf`'s
  `/option` syntax works unchanged from both.

## Install
```text
/plugin marketplace add jenka1980/claude-tfvc
/plugin install claude-tfvc@claude-tfvc
```
Installed plugins are user-level — available in every project on your machine. Run `/reload-plugins` after
install if the commands/hook don't appear immediately.

## Configuration
`tf.exe` is resolved in this order, by the skill and the hook alike (one shared script,
`skills/tfvc/scripts/Find-Tf.ps1`; run it with `-List` to see every TF.exe on the machine with its version):
1. **The project's own choice** — `env.TF_EXE` in `<project>\.claude\settings.local.json` (then
   `.claude\settings.json`). Set it with **`/tf-select`** (below). This is how one machine uses different TF.exe
   versions for different projects.
2. **`TF_EXE`** env var — the machine-wide default.
3. **`tf.exe` on `PATH`**.
4. **`vswhere.exe`** (installed with any VS 2017+), which also finds Visual Studio installs outside Program Files.
5. **Default Visual Studio folders** under Program Files / Program Files (x86): VS 2017+ (any version folder — a
   year like `2022` or a major version like `18` — and any edition, including BuildTools and TeamExplorer) and
   VS 2010–2015 (`Microsoft Visual Studio <n>.0\Common7\IDE\TF.exe`).

A configured value (1–2) is used only if it points at an existing file; surrounding quotes are tolerated and a stale
path falls through. When several are found (4–5), the **newest `TF.exe` wins**.

### Per-project choice: `/tf-select`
A TFS 2010-era server may reject newer clients while your other projects want the newest TF.exe. Run `/tf-select`
inside a project: it lists every TF.exe on the machine with its version, lets you pick one (or `auto` to remove the
override), and writes it to the project's `.claude\settings.local.json`:
```json
{ "env": { "TF_EXE": "C:\\Program Files (x86)\\Microsoft Visual Studio\\2017\\Professional\\Common7\\IDE\\CommonExtensions\\Microsoft\\TeamFoundation\\Team Explorer\\TF.exe" } }
```
`/tf-select 2017`, `/tf-select 15` (major file version) or `/tf-select <path>` skip the question. The choice applies
immediately — the hook and the skill read the file directly, and Claude Code also exports it as `TF_EXE` for shell
commands — and stays on this machine: TFVC does not track `.claude\` unless you `tf add` it.

### Machine-wide default: `TF_EXE`
```powershell
setx TF_EXE "C:\Program Files (x86)\Microsoft Visual Studio\2017\Professional\Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\TF.exe"
```
`setx` only affects new processes — **restart Claude Code** afterwards.

## Commands
| Command | Action |
|---|---|
| `/tf-select [version\|path\|auto]` | Choose this project's TF.exe (writes `.claude\settings.local.json`) |
| `/tf-status` | Show pending changes (`tf status`) |
| `/tf-checkout [path]` | Check out file(s) for editing (`tf checkout`) |
| `/tf-checkin [comment] [path]` | Check in — **asks for confirmation first** (`tf checkin`) |
| `/tf-get [path]` | Get latest from the server (`tf get /recursive`) |
| `/tf-undo [path]` | Discard pending changes — **asks for confirmation first** (`tf undo`) |
| `/tf-relay [status\|on\|off\|auto]` | Relay `tf` through your interactive session from SSH; status, one-time setup, `TFVC_TRANSPORT` |

## The auto-checkout hook
A `PreToolUse` hook on `Edit`/`Write` runs `hooks/tfvc-checkout.ps1` via `powershell.exe` (Windows PowerShell
5.1), which:
1. reads the target file path from the tool input (as UTF-8, so non-ASCII paths work on any console code page),
2. acts **only if that file is read-only** (so writable files and non-TFVC projects are skipped instantly),
3. runs `tf checkout /noprompt` through the launcher `skills/tfvc/scripts/Invoke-Tf.ps1` (direct, or relayed from an SSH session; see below) — `/noprompt` makes a missing server login fail fast instead of opening a credential dialog,
4. **always allows the edit to proceed** (it never denies/blocks); when checkout fails it hands Claude the reason as hook context, for example "TF30063 … run /tf-relay".

**Locked-down machines:** if Group Policy pins the PowerShell execution policy, or AppLocker blocks scripts under
the user profile, the hook cannot run and degrades to a no-op — the edit still proceeds, you just see a hook error.
Use `/tf-checkout` manually in that case.

**Disable it** by removing the `PreToolUse` block from `hooks/hooks.json` (or uninstalling the plugin). It only
calls `tf checkout` — it never checks in.

## Remote sessions (SSH)
**Symptom:** Claude Code runs over SSH (for example VS Code Remote-SSH with a key) and every `tf` call fails with
`TF30063: You are not authorized to access <server>\<collection>`; the auto-checkout hook silently does nothing and
edits fail with "access denied". An SSH key logon is a *network* logon without delegable Windows credentials, so an
on-prem TFS with Windows authentication rejects the client. (An SSH logon with a password carries credentials, so
the relay is unnecessary there.)

**How it works:** the plugin runs `tf` through one launcher, `skills/tfvc/scripts/Invoke-Tf.ps1`. In a remote
session it writes the request to a per-user queue (`%LOCALAPPDATA%\claude-tfvc\relay\queue`), starts the scheduled
task `ClaudeTfvcRelay`, and that task runs `Tf-RelayWorker.ps1` **inside your interactive Windows session** (console
or RDP; a disconnected RDP session is fine), where the credentials exist. The worker runs `tf.exe` and writes the
output back; the launcher returns it with `tf`'s exit code. Local sessions are untouched: `tf.exe` runs directly.

**One-time setup:** run `/tf-relay` inside a project. It reports the state and, when the task is missing, shows the
registration command and offers to run it:
```text
powershell -NoProfile -ExecutionPolicy Bypass -File "<plugin>\skills\tfvc\scripts\Register-TfRelay.ps1"
```
The task runs as you with `LogonType Interactive`, no stored password, no triggers, one instance at a time, a one
hour limit. It points at a worker copy under `%LOCALAPPDATA%\claude-tfvc\relay`, which the launcher refreshes after
plugin updates, so you never re-register. `Register-TfRelay.ps1 -Unregister` removes the task and the folder.

**Transport selection:** `TFVC_TRANSPORT` is `auto` (default: relay when `SSH_CONNECTION`/`SSH_CLIENT` is set and
the task exists, else direct), `direct`, or `relay`. It is read like `TF_EXE`: the project's
`.claude/settings.local.json`, then `.claude/settings.json`, then the environment. `/tf-relay on|off|auto` writes it.

**Limitations:** the worker needs an interactive session of the same user on the same machine. After a reboot or
sign-out, log in once over RDP (disconnecting afterwards is fine); until then `tf` calls report "not logged on to
Windows interactively" and the hook lets the edit proceed with that explanation. Expect one to three seconds of
overhead per call, and almost none while the worker lingers after a burst of calls.

**Security:** the worker starts only an executable named `tf.exe` with a valid Microsoft Authenticode signature,
only from an argument array (no shell, no string interpretation), with `/noprompt` forced and stdin closed. The
queue, lock, log and worker copy live in your profile with its default ACL. Nothing stores or transmits a password
or token. The log holds timestamps, request ids, the `tf` verb, exit codes and durations, never comments or output.
Check-in and undo confirmation stays in the skill and in Claude Code permissions; because the command line is now
stable you can make Claude Code ask before them:
```json
{ "permissions": { "ask": [
    "Bash(*Invoke-Tf.ps1*checkin*)", "Bash(*Invoke-Tf.ps1*undo*)",
    "PowerShell(*Invoke-Tf.ps1*checkin*)", "PowerShell(*Invoke-Tf.ps1*undo*)" ] } }
```
`*` may appear anywhere in a rule, and `ask` rules still prompt even when a hook allows the call.

**Diagnostics:** `/tf-relay` (or `Register-TfRelay.ps1 -Status`) prints the session kind, the effective transport,
the task state with `LastTaskResult` decoded, the worker version, queue counts and a timed probe.

## Workspace types & `.tfignore` (read this for older TFS)
- **Local workspaces** (VS 2012+ default) honor a `.tfignore` file and detect edits without explicit checkout.
- **Server workspaces** (common on TFS 2010-era servers) require an explicit `tf checkout` (files stay read-only)
  and **do not** honor `.tfignore` — exclude files via the Pending Changes "Excluded/Detected" list instead.

Check your type with `tf workspaces /collection:<url>`.

## Scope / limitations
- Covers the everyday checkout/checkin/status/get/undo loop. Branching/merging/shelvesets are not wrapped as
  commands (use `tf.exe` directly; the skill documents the model).
- Windows-only by nature of `tf.exe`.

## Tests
- `tests\test-hook.ps1` exercises the hook, `hooks.json` and the resolver under Windows PowerShell 5.1 and pwsh
  (console code page forced to 862, fake `tf`, fake Visual Studio trees, fake projects):
  `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-hook.ps1`
  (it now also needs `csc.exe`, which ships with .NET Framework 4.x, to compile the fake `tf.exe`)
- `tests\test-relay.ps1` exercises the launcher (direct and relay), the worker, `Register-TfRelay.ps1 -Status`, the hook in relay mode and the docs, without touching the scheduler (a child worker and a fake `tf.exe` compiled from `tests\FakeTf.cs`): `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-relay.ps1`
- `tests\skill-evals\` holds pressure-scenario evals for the skill (run with and without the skill in a sandbox
  with a fake `tf.exe`); see its README.

## License
MIT © Evgeny Satanovsky
