# Relay Transport (claude-tfvc 0.4.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the claude-tfvc plugin work in Windows sessions without network credentials (SSH key logon) by running `tf.exe` through a worker in the user's interactive session, while keeping local sessions byte-for-byte unchanged.

**Architecture:** A new launcher `Invoke-Tf.ps1` becomes the only way the hook, the skill and the `/tf-*` commands run `tf`. It picks `direct` (child `tf.exe`, stdout inherited, stderr relayed byte for byte) or `relay` (a per-user file queue under `%LOCALAPPDATA%\claude-tfvc\relay\queue`, served by `Tf-RelayWorker.ps1`, which the scheduled task `ClaudeTfvcRelay` starts in the interactive session). `Register-TfRelay.ps1` registers the task once; `/tf-relay` diagnoses and configures.

**Tech Stack:** Windows PowerShell 5.1 (also runs on pwsh), .NET Framework `System.Diagnostics.Process`, Task Scheduler cmdlets (`ScheduledTasks` module), JSON files, `csc.exe` for test fixtures, Markdown skill/command files.

**Spec:** `docs/specs/2026-10-11-relay-transport-design.md` (design, authoritative) and `docs/specs/2026-10-11-relay-transport-spec.md` (requirements; "spec 4.x" in the design refers to it). Read both before starting.

## Global Constraints

- All four PowerShell scripts (`Find-Tf.ps1`, `Invoke-Tf.ps1`, `Tf-RelayWorker.ps1`, `Register-TfRelay.ps1`) and the hook run under **Windows PowerShell 5.1** and pwsh; are **pure ASCII, no BOM**; keep the `$MyInvocation.InvocationName -ne '.'` guard so dot-sourcing only defines functions.
- **`tf.exe` resolution exists once**, in `Find-Tf.ps1` (`Resolve-TfExe`); order unchanged: project `.claude\settings.local.json`, `.claude\settings.json` `env.TF_EXE`, `TF_EXE` env var, PATH, vswhere, Visual Studio folders.
- **The hook never blocks an edit**: always `exit 0`, acts only on a read-only target, loads nothing until a read-only file is seen.
- **Never check in without confirmation**; the relay is transport only, no command whitelist.
- Launcher exit codes: `tf`'s own pass through; **120** relay unavailable, **124** relay timeout, **127** no `tf.exe`.
- Relay folder `%LOCALAPPDATA%\claude-tfvc\relay\` (override `CLAUDE_TFVC_RELAY_ROOT`); files `queue\<id>.req.json` → `.run.json` → `.res.json`, `worker.lock`, `worker.version`, `worker.log` (rotate at 1 MB to `worker.1.log`), installed `Tf-RelayWorker.ps1`.
- Scheduled task name **`ClaudeTfvcRelay`**: `LogonType Interactive`, `RunLevel Limited`, no triggers, `MultipleInstances IgnoreNew`, 1 hour limit, action `powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "<relay>\Tf-RelayWorker.ps1"`.
- Protocol version **1**. Timeouts: command line pickup 30 s / total 600 s (`TFVC_RELAY_TIMEOUT` overrides total); hook pickup 15 s / total 20 s; `hooks.json` timeout 45. Worker linger 15 s (`CLAUDE_TFVC_RELAY_LINGER_SEC`), life cap 50 min, orphan sweep 60 min.
- Test seams are environment variables only: `CLAUDE_TFVC_RELAY_ROOT`, `CLAUDE_TFVC_RELAY_LAUNCH` = `child` | `none` | `noop`, `CLAUDE_TFVC_RELAY_LINGER_SEC`, `CLAUDE_TFVC_RELAY_ALLOW_UNSIGNED=1`.
- Existing checks in `tests/test-hook.ps1` stay unchanged and must pass. Version 0.4.0 in `plugin.json`, `marketplace.json` and the newest CHANGELOG entry.
- Commit after every task on branch `feat/relay-transport` (already created; the design docs are its first commit). Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Shell for executors on this machine: use the PowerShell tool for everything except `git`, per the user's global CLAUDE.md. Run harnesses with `powershell -NoProfile -ExecutionPolicy Bypass -File tests\<name>.ps1`.

## Review Focus

1. **Output larger than a pipe buffer** (for example `tf get /recursive` printing hundreds of KB on stdout and stderr at once): the worker and the hook's capture path must read both streams concurrently, otherwise `tf` deadlocks and the call times out. Pinned by R32 in Task 5 (`/big` in the fake).
2. **An argument that is empty or ends in a backslash** (`"D:\Projects\X\"`, `""`): must reach `tf` unchanged in both transports; naive quoting eats the closing quote. Pinned by R13 in Task 4 and R3 in Task 7.
3. **A corrupt or foreign file in the queue** (not JSON, wrong extension): the worker must skip or delete it and keep serving; the client waiting on it must get 124, not hang 600 s. Pinned by R33 in Task 6 and R25 in Task 7.
4. **Relay folder deleted while the task exists** (user cleaned `%LOCALAPPDATA%`): the next call must reinstall the worker before kicking the task. Pinned by R16 in Task 7.
5. **Non-ASCII file path in a hook failure message**: the `additionalContext` JSON must be valid UTF-8 JSON, not mojibake or broken escapes. Pinned by R27 in Task 8.

---

## File structure

| File | Task | Responsibility |
|---|---|---|
| `tests/FakeTf.cs` | 1 | One fake `tf.exe` for both harnesses: logs every call and argument, honours `/exit:N`, `/sleep:N`, `/stdout:`, `/stderr:`, `/ansi`, `/big`. |
| `tests/test-hook.ps1` | 1, 8, 9 | Existing harness; fixtures become compiled exes (checks unchanged); new static checks. |
| `tests/test-relay.ps1` | 1–11 | New harness for launcher, worker, register, hook-in-relay-mode, docs. |
| `plugins/claude-tfvc/skills/tfvc/scripts/Find-Tf.ps1` | 2 | Resolver; gains `Get-ProjectEnvSetting -Name [-Detailed]`. |
| `plugins/claude-tfvc/skills/tfvc/scripts/Invoke-Tf.ps1` | 3, 4, 7 | Launcher: transport selection (3), direct mode and orchestration (4), relay client (7). |
| `plugins/claude-tfvc/skills/tfvc/scripts/Tf-RelayWorker.ps1` | 5, 6 | Worker: request processing (5), lock/loop/sweep/linger (6). Single file, dot-sources nothing. |
| `plugins/claude-tfvc/hooks/tfvc-checkout.ps1`, `hooks/hooks.json` | 8 | Hook calls `Invoke-Tf -Capture`, reports failures via `additionalContext`; timeout 45. |
| `plugins/claude-tfvc/skills/tfvc/scripts/Register-TfRelay.ps1` | 9 | Register / `-Unregister` / `-Status` (+ probe, smoke test, decoded failure codes). |
| `plugins/claude-tfvc/commands/tf-relay.md`, `commands/tf-*.md`, `skills/tfvc/SKILL.md` | 10 | New command; wording; "Running tf". |
| `README.md`, `CHANGELOG.md`, `CLAUDE.md`, both manifests | 11 | Docs and 0.4.0. |

`ConvertTo-CommandLine` (CommandLineToArgvW quoting) exists **twice on purpose**, in `Invoke-Tf.ps1` and `Tf-RelayWorker.ps1`, because the worker is installed as a single file; a static check keeps the two copies identical.

---

### Task 1: Shared fake tf.exe and the relay harness scaffold

**Files:**
- Create: `tests/FakeTf.cs`
- Create: `tests/test-relay.ps1`
- Modify: `tests/test-hook.ps1:24-26` (fixture paths), `:40-41` (log helpers), `:96-98` (fixture creation)

**Interfaces:**
- Produces: `tests/FakeTf.cs` behaviour (below); harness helpers `Check`, `Skip`, `Set-TestEnv`, `Restore-TestEnv`, `Invoke-Launcher`, `Invoke-InChild`, `Reset-FakeLog`, `Get-FakeCalls`, variables `$FakeTf`, `$Relay`, `$Proj`, `$RelayEnv`, `$Exes`, `$Bash`, `$Csc`, `$HaveFake`; the `# ---- report` anchor every later task inserts checks before.

- [ ] **Step 1: Write the fake tf.exe source**

```csharp
// tests/FakeTf.cs - fake tf.exe for tests/test-hook.ps1 and tests/test-relay.ps1.
// Logs every call next to the exe and reacts to a few control arguments:
//   /exit:N        exit with code N (default 0)          /sleep:N      sleep N seconds first
//   /stdout:TEXT   write TEXT + newline to stdout         /stderr:TEXT  write TEXT + newline to stderr
//   /ansi          write Sample + newline to stdout as raw bytes in the system ANSI code page (what tf.exe does)
//   /big           write 300 KB to stdout and 300 KB to stderr, interleaved (pipe-buffer deadlock check)
// Logs (UTF-8, no BOM):
//   tf-calls.log   one line per call: "<tag> " + arguments joined by one space; <tag> = content of <exe>.tag if present
//   tf-args.log    "--- call ---" then every argument on its own line
// Build: csc.exe /nologo /target:exe /out:<dir>\tf.exe tests\FakeTf.cs   (csc ships with .NET Framework 4.x)
using System;
using System.IO;
using System.Text;
using System.Threading;

static class FakeTf
{
    public const string Sample = "shalom-\u05E9\u05DC\u05D5\u05DD-privet-\u041F\u0440\u0438\u0432\u0435\u0442";

    static void Append(string path, string text)
    {
        for (int i = 0; ; i++)
        {
            try { File.AppendAllText(path, text, new UTF8Encoding(false)); return; }
            catch (IOException) { if (i >= 20) throw; Thread.Sleep(25); }
        }
    }

    static int Main(string[] args)
    {
        string exe = System.Reflection.Assembly.GetExecutingAssembly().Location;
        string dir = Path.GetDirectoryName(exe);
        string tag = File.Exists(exe + ".tag") ? File.ReadAllText(exe + ".tag").Trim() + " " : "";
        Append(Path.Combine(dir, "tf-calls.log"), tag + string.Join(" ", args) + Environment.NewLine);
        var sb = new StringBuilder("--- call ---" + Environment.NewLine);
        foreach (var a in args) sb.Append(a).Append(Environment.NewLine);
        Append(Path.Combine(dir, "tf-args.log"), sb.ToString());

        int exit = 0;
        foreach (var a in args)
        {
            if (a.StartsWith("/exit:", StringComparison.OrdinalIgnoreCase)) exit = int.Parse(a.Substring(6));
            else if (a.StartsWith("/sleep:", StringComparison.OrdinalIgnoreCase)) Thread.Sleep(int.Parse(a.Substring(7)) * 1000);
            else if (a.StartsWith("/stdout:", StringComparison.OrdinalIgnoreCase)) Console.Out.WriteLine(a.Substring(8));
            else if (a.StartsWith("/stderr:", StringComparison.OrdinalIgnoreCase)) Console.Error.WriteLine(a.Substring(8));
            else if (a.Equals("/ansi", StringComparison.OrdinalIgnoreCase))
            {
                byte[] bytes = Encoding.Default.GetBytes(Sample + Environment.NewLine);
                Stream o = Console.OpenStandardOutput(); o.Write(bytes, 0, bytes.Length); o.Flush();
            }
            else if (a.Equals("/big", StringComparison.OrdinalIgnoreCase))
            {
                string line = new string('x', 99) + Environment.NewLine;           // 101 bytes
                for (int i = 0; i < 3000; i++) { Console.Out.Write(line); Console.Error.Write(line); }
            }
        }
        return exit;
    }
}
```

- [ ] **Step 2: Switch test-hook.ps1 fixtures to compiled exes (checks untouched)**

In `tests/test-hook.ps1` replace lines 25–26:

```powershell
$FakeTf    = Join-Path $S 'fake-tf.ps1'
$FakeTf2   = Join-Path $S 'fake-tf2.ps1'
```

with:

```powershell
$FakeTfSrc = Join-Path $PSScriptRoot 'FakeTf.cs'
$FakeTf    = Join-Path $S 'fake-tf\tf.exe'      # compiled from FakeTf.cs; the hook now starts tf.exe as a process,
$FakeTf2   = Join-Path $S 'fake-tf2\tf.exe'     # so the fakes must be real executables (a .ps1 cannot be started)
```

Replace lines 40–41 (`Reset-Log`, `Get-Log`) with:

```powershell
function Reset-Log { foreach ($d in (Split-Path -Parent $FakeTf), (Split-Path -Parent $FakeTf2)) { Remove-Item -LiteralPath "$d\tf-calls.log", "$d\tf-args.log" -Force -ErrorAction SilentlyContinue } }
function Get-Log {
    $lines = foreach ($d in (Split-Path -Parent $FakeTf), (Split-Path -Parent $FakeTf2)) {
        if (Test-Path -LiteralPath "$d\tf-calls.log") { Get-Content -LiteralPath "$d\tf-calls.log" -Encoding utf8 }
    }
    return (@($lines) -join ' | ')
}
function New-FakeTf([string]$Path, [string]$Tag) {
    # Compiles FakeTf.cs to $Path (once) and writes the <exe>.tag that prefixes every logged call.
    if (-not $Csc) { return $false }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $Path)) { & $Csc /nologo /target:exe "/out:$Path" $FakeTfSrc | Out-Null }
    Set-Content -LiteralPath "$Path.tag" -Value $Tag -Encoding Ascii
    return (Test-Path -LiteralPath $Path)
}
```

Replace lines 97–98 (the two `Set-Content ... fake-tf*.ps1` lines) with:

```powershell
$HaveFake = (New-FakeTf $FakeTf '[5]') -and (New-FakeTf $FakeTf2 '[TF2]')
if (-not $HaveFake) { "csc.exe not found: hook cases need the compiled fake tf.exe and will be reported as SKIP" }
```

Wrap the hook-behaviour loop so it skips without the fake: change line 134 `foreach ($exe in $Exes.Keys) {` to `foreach ($exe in $Exes.Keys) { if (-not $HaveFake) { Skip "$exe hook cases" 'csc.exe not available to build the fake tf.exe'; continue }`. Do the same for the `T4b`/`T4c` blocks: guard them with `if ($HaveFake) { ... } else { Skip ... }`.

The `[5]` tag satisfies the unchanged T14/T15 checks (`StartsWith("[5] checkout")`); `[TF2]` satisfies T12/T13/T16–T18.

- [ ] **Step 3: Run test-hook.ps1 to verify the converted fixtures still pass every existing check**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-hook.ps1`
Expected: same PASS set as before the change (the hook still runs `& $tf`, which works with an exe), `0 failed`.

- [ ] **Step 4: Write the relay harness scaffold**

Create `tests/test-relay.ps1`:

```powershell
<#
.SYNOPSIS
  Verification harness for the claude-tfvc relay transport: Invoke-Tf.ps1 (direct and relay), Tf-RelayWorker.ps1,
  Register-TfRelay.ps1 (-Status and the task spec), the hook in relay mode, and the docs that describe them.

.DESCRIPTION
  Run from any PowerShell:   powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-relay.ps1
  Launcher cases run under Windows PowerShell 5.1 and, when installed, pwsh, with the console input code page
  forced to 862. Worker cases run under Windows PowerShell 5.1 only (the scheduled task always uses powershell.exe).
  The scheduler is never touched: CLAUDE_TFVC_RELAY_LAUNCH=child makes the client start the worker as a child
  process, CLAUDE_TFVC_RELAY_ROOT relocates the relay folder under -WorkDir, and a fake tf.exe compiled from
  tests\FakeTf.cs (csc.exe from .NET Framework 4.x) logs every argument. Exit code = number of failed checks.
#>
param([string]$WorkDir = (Join-Path $env:TEMP 'claude\tfvc-tests\relay'))

$ErrorActionPreference = 'Continue'
$Repo     = Split-Path -Parent $PSScriptRoot
$Plugin   = Join-Path $Repo 'plugins\claude-tfvc'
$Scripts  = Join-Path $Plugin 'skills\tfvc\scripts'
$InvokeTf = Join-Path $Scripts 'Invoke-Tf.ps1'
$Worker   = Join-Path $Scripts 'Tf-RelayWorker.ps1'
$Register = Join-Path $Scripts 'Register-TfRelay.ps1'
$Hook     = Join-Path $Plugin 'hooks\tfvc-checkout.ps1'
$S        = $WorkDir
if (Test-Path -LiteralPath $S) { Remove-Item -LiteralPath $S -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $S -Force | Out-Null
$Exes     = [ordered]@{ powershell = (Get-Command powershell.exe).Source }
$pwshCmd  = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($pwshCmd) { $Exes.pwsh = $pwshCmd.Source }
$Bash     = @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe", "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe") |
            Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
$Csc      = @("$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe", "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe") |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$Results  = New-Object System.Collections.ArrayList
$Utf8     = New-Object System.Text.UTF8Encoding $false

function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    [void]$Results.Add([pscustomobject]@{ Result = $(if ($Ok) { 'PASS' } else { 'FAIL' }); Name = $Name; Detail = $Detail })
}
function Skip([string]$Name, [string]$Why) { [void]$Results.Add([pscustomobject]@{ Result = 'SKIP'; Name = $Name; Detail = $Why }) }

# ---- fake tf.exe ----------------------------------------------------------------------------
$FakeDir  = Join-Path $S 'fake-tf'
$FakeTf   = Join-Path $FakeDir 'tf.exe'
$HaveFake = $false
if ($Csc) {
    New-Item -ItemType Directory -Path $FakeDir -Force | Out-Null
    & $Csc /nologo /target:exe "/out:$FakeTf" (Join-Path $PSScriptRoot 'FakeTf.cs') | Out-Null
    $HaveFake = Test-Path -LiteralPath $FakeTf
}
$ArgsLog  = Join-Path $FakeDir 'tf-args.log'
$CallsLog = Join-Path $FakeDir 'tf-calls.log'
function Reset-FakeLog { Remove-Item -LiteralPath $ArgsLog, $CallsLog -Force -ErrorAction SilentlyContinue }
function Get-FakeCalls {
    # Every call the fake received, as an array of string arrays (one per call), exactly as its Main() saw them.
    if (-not (Test-Path -LiteralPath $ArgsLog)) { return @() }
    $calls = New-Object System.Collections.ArrayList; $cur = $null
    foreach ($line in [System.IO.File]::ReadAllLines($ArgsLog, $Utf8)) {
        if ($line -eq '--- call ---') { $cur = New-Object System.Collections.ArrayList; [void]$calls.Add($cur) }
        elseif ($null -ne $cur) { [void]$cur.Add($line) }
    }
    return @($calls | ForEach-Object { , @($_) })
}
# The fake's non-ASCII sample, as the ANSI round trip leaves it (letters the ANSI page cannot hold become '?').
# The fake (.NET Framework) and the worker (powershell.exe) use the SYSTEM ANSI page; ask powershell.exe for it,
# because [Text.Encoding]::Default is UTF-8 when this harness itself runs under pwsh.
$AnsiCp    = [int](& $Exes.powershell -NoProfile -NonInteractive -Command '[System.Text.Encoding]::Default.CodePage')
$AnsiEnc   = [System.Text.Encoding]::GetEncoding($AnsiCp)
$Sample    = "shalom-$([char]0x5E9)$([char]0x5DC)$([char]0x5D5)$([char]0x5DD)-privet-$([char]0x41F)$([char]0x440)$([char]0x438)$([char]0x432)$([char]0x435)$([char]0x442)"
$SampleRT  = $AnsiEnc.GetString($AnsiEnc.GetBytes($Sample))

# ---- fixtures -------------------------------------------------------------------------------
$Relay    = Join-Path $S 'relay'                       # CLAUDE_TFVC_RELAY_ROOT for the cases
$Proj     = Join-Path $S 'proj';      New-Item -ItemType Directory -Path "$Proj\.claude" -Force | Out-Null
$ProjNone = Join-Path $S 'proj-none'; New-Item -ItemType Directory -Path $ProjNone -Force | Out-Null
Set-Content -LiteralPath "$Proj\.claude\settings.local.json" -Value (@{ env = @{ TFVC_TRANSPORT = 'relay' } } | ConvertTo-Json -Depth 5)
# Environment every relay case starts from (null = make sure the variable is absent).
$RelayEnv = @{ TF_EXE = $FakeTf; CLAUDE_TFVC_RELAY_ROOT = $Relay; CLAUDE_TFVC_RELAY_LAUNCH = 'child'; CLAUDE_TFVC_RELAY_LINGER_SEC = '1'
               CLAUDE_TFVC_RELAY_ALLOW_UNSIGNED = '1'; TFVC_TRANSPORT = $null; CLAUDE_PROJECT_DIR = $ProjNone; SSH_CONNECTION = $null; SSH_CLIENT = $null; TFVC_RELAY_TIMEOUT = $null }
$DirectEnv = @{ TF_EXE = $FakeTf; CLAUDE_TFVC_RELAY_ROOT = $Relay; CLAUDE_TFVC_RELAY_LAUNCH = 'none'; TFVC_TRANSPORT = $null; CLAUDE_PROJECT_DIR = $ProjNone; SSH_CONNECTION = $null; SSH_CLIENT = $null }

function Set-TestEnv([hashtable]$EnvVars) {
    # Applies $EnvVars to this process (children inherit them) and returns what to pass to Restore-TestEnv.
    $saved = @{}
    foreach ($k in $EnvVars.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $EnvVars[$k])
    }
    return $saved
}
function Restore-TestEnv([hashtable]$Saved) { foreach ($k in $Saved.Keys) { [Environment]::SetEnvironmentVariable($k, $Saved[$k]) } }
function Merge-Env([hashtable]$Base, [hashtable]$Extra) { $m = @{}; foreach ($k in $Base.Keys) { $m[$k] = $Base[$k] }; foreach ($k in $Extra.Keys) { $m[$k] = $Extra[$k] }; return $m }

. $InvokeTf   # for ConvertTo-CommandLine (builds exact child command lines); dot-sourcing defines functions only
$ErrorActionPreference = 'Continue'

function Invoke-Launcher([string]$Exe, [hashtable]$EnvVars, [string[]]$TfArgs) {
    # Runs Invoke-Tf.ps1 exactly as the skill does: powershell -File <script> <tf args>, in a child interpreter,
    # with $EnvVars applied. Returns exit code, stdout/stderr (text and raw bytes) and the fake's calls.
    Reset-FakeLog
    $saved = Set-TestEnv $EnvVars
    try {
        $out = Join-Path $S 'launcher.out'; $err = Join-Path $S 'launcher.err'
        Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
        $cmdline = ConvertTo-CommandLine (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $InvokeTf) + @($TfArgs))
        $p = Start-Process -FilePath $Exes[$Exe] -ArgumentList $cmdline -RedirectStandardOutput $out -RedirectStandardError $err -Wait -PassThru -NoNewWindow
        $outBytes = if (Test-Path -LiteralPath $out) { [System.IO.File]::ReadAllBytes($out) } else { @() }
        $errBytes = if (Test-Path -LiteralPath $err) { [System.IO.File]::ReadAllBytes($err) } else { @() }
        return @{ Exit = $p.ExitCode; Out = $Utf8.GetString($outBytes); Err = $Utf8.GetString($errBytes); OutBytes = $outBytes; ErrBytes = $errBytes; Calls = @(Get-FakeCalls) }
    } finally { Restore-TestEnv $saved }
}
function Invoke-InChild([string]$Exe, [hashtable]$EnvVars, [string]$Command) {
    # Runs $Command in a child interpreter with $EnvVars applied; returns stdout+stderr text and the exit code.
    $saved = Set-TestEnv $EnvVars
    try {
        $out = (& $Exes[$Exe] -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $Command 2>&1 | Out-String).Trim()
        return @{ Exit = $LASTEXITCODE; Out = $out }
    } finally { Restore-TestEnv $saved }
}
function Reset-Relay { if (Test-Path -LiteralPath $Relay) { Remove-Item -LiteralPath $Relay -Recurse -Force -ErrorAction SilentlyContinue } }
function Wait-NoWorker { $deadline = (Get-Date).AddSeconds(10); while ((Get-Date) -lt $deadline -and (Test-TfRelayWorkerAlive (Get-RelayPaths))) { Start-Sleep -Milliseconds 200 } }
function Get-RelayPaths { $saved = Set-TestEnv @{ CLAUDE_TFVC_RELAY_ROOT = $Relay }; try { return Get-TfRelayPaths } finally { Restore-TestEnv $saved } }

"host: PowerShell $($PSVersionTable.PSVersion)   interpreters: $($Exes.Keys -join ', ')   git bash: $(if ($Bash) { 'yes' } else { 'no' })   csc: $(if ($Csc) { 'yes' } else { 'no' })   ansi: $($AnsiEnc.WebName)"

$savedEnc = [Console]::InputEncoding
[Console]::InputEncoding = [System.Text.Encoding]::GetEncoding(862)
try {
    # ---- R0 fake tf.exe sanity ------------------------------------------------------------------
    if ($HaveFake) {
        Reset-FakeLog
        & $FakeTf status 'a b' /exit:3 | Out-Null
        $calls = @(Get-FakeCalls)
        Check 'R0 fake tf.exe logs each argument on its own line and honours /exit:N' `
            (($LASTEXITCODE -eq 3) -and ($calls.Count -eq 1) -and ($calls[0].Count -eq 3) -and ($calls[0][1] -eq 'a b')) "exit=$LASTEXITCODE calls=$($calls.Count) args=[$($calls[0] -join '|')]"
    } else { Skip 'R0 fake tf.exe sanity' 'csc.exe not available to build the fake tf.exe' }

    # ---- report (keep this anchor last; later tasks insert their checks above it) --------------------
}
finally { [Console]::InputEncoding = $savedEnc }

$Results | Format-Table -AutoSize -Wrap | Out-String -Width 220
$fail = @($Results | Where-Object Result -eq 'FAIL').Count
$skip = @($Results | Where-Object Result -eq 'SKIP').Count
"$(@($Results).Count) checks, $fail failed, $skip skipped"
exit $fail
```

Note: the scaffold dot-sources `Invoke-Tf.ps1`, which does not exist until Task 3. Until then the harness prints an error for that line and R0 still runs, because `$ErrorActionPreference` is `Continue`. Task 3 makes the line succeed.

- [ ] **Step 5: Run the relay harness**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-relay.ps1`
Expected: one error line about `Invoke-Tf.ps1` not found (expected until Task 3), then `R0 ... PASS`, `1 checks, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add tests/FakeTf.cs tests/test-relay.ps1 tests/test-hook.ps1
git commit -m "tests: shared compiled fake tf.exe and the relay harness scaffold" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Find-Tf.ps1 reads any project env setting

**Files:**
- Modify: `plugins/claude-tfvc/skills/tfvc/scripts/Find-Tf.ps1:79-92`
- Test: `tests/test-hook.ps1` (insert before `# ---- static checks`)

**Interfaces:**
- Produces: `Get-ProjectEnvSetting -ProjectDir <string> -Name <string> [-Detailed]` → string value, or with `-Detailed` `[pscustomobject]@{ Value; Source }` where `Source` is `settings.local.json` or `settings.json`; `$null` when unset. `Get-ProjectTfSetting -ProjectDir` keeps its contract (value of `env.TF_EXE`).

- [ ] **Step 1: Add the failing checks to test-hook.ps1**

Insert before the line `# ---- static checks ---...`:

```powershell
# ---- Find-Tf.ps1: Get-ProjectEnvSetting (shared by TF_EXE and TFVC_TRANSPORT) ---------------------
foreach ($exe in $Exes.Keys) {
    $cmd = ". '$FindTf'; Get-ProjectEnvSetting -ProjectDir '$Proj' -Name OTHER"
    $got = (& $Exes[$exe] -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $cmd 2>&1 | Out-String).Trim()
    Check "$exe T25 Get-ProjectEnvSetting reads any env.<Name> from settings.local.json" ($got -eq '1') "got=[$got]"

    $cmd = ". '$FindTf'; (Get-ProjectEnvSetting -ProjectDir '$ProjShared' -Name TF_EXE -Detailed).Source"
    $got = (& $Exes[$exe] -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $cmd 2>&1 | Out-String).Trim()
    Check "$exe T26 Get-ProjectEnvSetting -Detailed names the file the value came from" ($got -eq 'settings.json') "got=[$got]"

    $cmd = ". '$FindTf'; if ((Get-ProjectEnvSetting -ProjectDir '$ProjNoCfg' -Name TF_EXE) -eq `$null) { 'null' } else { 'value' }"
    $got = (& $Exes[$exe] -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $cmd 2>&1 | Out-String).Trim()
    Check "$exe T27 Get-ProjectEnvSetting returns null for a project without .claude settings" ($got -eq 'null') "got=[$got]"
}
```

- [ ] **Step 2: Run test-hook.ps1 to verify T25–T27 fail**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-hook.ps1`
Expected: T25–T27 FAIL ("Get-ProjectEnvSetting is not recognized"), everything else PASS.

- [ ] **Step 3: Replace `Get-ProjectTfSetting` in Find-Tf.ps1**

Replace lines 79–92 with:

```powershell
function Get-ProjectEnvSetting {
    # env.<Name> from the project's Claude Code settings: .claude\settings.local.json wins over
    # .claude\settings.json, like Claude Code's own precedence. Used for TF_EXE (/tf-select) and
    # TFVC_TRANSPORT (/tf-relay). -Detailed also tells which file the value came from.
    param([string]$ProjectDir, [string]$Name, [switch]$Detailed)
    if ($ProjectDir) {
        foreach ($file in 'settings.local.json', 'settings.json') {
            $path = Join-Path (Join-Path $ProjectDir '.claude') $file
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $value = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).env.$Name
                if ($value) {
                    if ($Detailed) { return [pscustomobject]@{ Value = "$value"; Source = $file } }
                    return "$value"
                }
            }
        }
    }
    return $null
}

function Get-ProjectTfSetting {
    # env.TF_EXE from the project's Claude Code settings (written by /tf-select).
    param([string]$ProjectDir)
    return Get-ProjectEnvSetting -ProjectDir $ProjectDir -Name 'TF_EXE'
}
```

Also update the `.DESCRIPTION` comment at the top of the file: after the resolution-order paragraph add the sentence `The same reader (Get-ProjectEnvSetting) serves TFVC_TRANSPORT for Invoke-Tf.ps1.`

- [ ] **Step 4: Run test-hook.ps1 to verify everything passes**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-hook.ps1`
Expected: T25–T27 PASS, all earlier checks PASS, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add plugins/claude-tfvc/skills/tfvc/scripts/Find-Tf.ps1 tests/test-hook.ps1
git commit -m "Find-Tf.ps1: Get-ProjectEnvSetting reads any env.<Name> from the project settings" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Invoke-Tf.ps1 skeleton and transport selection

**Files:**
- Create: `plugins/claude-tfvc/skills/tfvc/scripts/Invoke-Tf.ps1`
- Test: `tests/test-relay.ps1` (insert before `# ---- report`)

**Interfaces:**
- Consumes: `Resolve-TfExe`, `Get-ProjectEnvSetting` from `Find-Tf.ps1` (Task 2).
- Produces (all dot-sourceable, later tasks and `Register-TfRelay.ps1` rely on these names):
  - `$TfvcScriptsDir` (folder of the scripts), `$TfvcRelayTask = 'ClaudeTfvcRelay'`, `$TfvcRelayProtocol = 1`
  - `Get-TfAnsiEncoding` → `[System.Text.Encoding]`
  - `Get-TfPluginVersion` → string from `plugin.json`
  - `Get-TfRelayPaths` → `[pscustomobject]@{ Root; Queue; Worker; Version; Lock; Log; Source }`
  - `Test-TfRemoteSession` → bool; `Test-TfRelayWorkerAlive -Paths` → bool; `Test-TfRelayTaskRegistered` → bool
  - `ConvertTo-TfRelayFailureText -Code <int64>` → string or `$null`
  - `Get-TfRegistrationHint` → string with the exact registration command line
  - `Resolve-TfTransport -ProjectDir` → `[pscustomobject]@{ Transport; Setting; Source; Remote; TaskRegistered }`

- [ ] **Step 1: Add fixtures and the failing R9 checks to test-relay.ps1**

Insert after the line that creates `$ProjNone` (fixtures section):

```powershell
$ProjLocalRelay   = Join-Path $S 'proj-local-relay';   New-Item -ItemType Directory -Path "$ProjLocalRelay\.claude" -Force | Out-Null
$ProjSharedDirect = Join-Path $S 'proj-shared-direct'; New-Item -ItemType Directory -Path "$ProjSharedDirect\.claude" -Force | Out-Null
Set-Content -LiteralPath "$ProjLocalRelay\.claude\settings.local.json" -Value (@{ env = @{ TFVC_TRANSPORT = 'relay' } } | ConvertTo-Json -Depth 5)
Set-Content -LiteralPath "$ProjLocalRelay\.claude\settings.json"       -Value (@{ env = @{ TFVC_TRANSPORT = 'direct' } } | ConvertTo-Json -Depth 5)
Set-Content -LiteralPath "$ProjSharedDirect\.claude\settings.json"     -Value (@{ env = @{ TFVC_TRANSPORT = 'direct' } } | ConvertTo-Json -Depth 5)
```

Insert before `# ---- report`:

```powershell
    # ---- R9 transport selection -----------------------------------------------------------------
    function Get-Transport([string]$Exe, [hashtable]$EnvVars, [string]$ProjectDir) {
        $r = Invoke-InChild $Exe $EnvVars ". '$InvokeTf'; `$t = Resolve-TfTransport -ProjectDir '$ProjectDir'; `"`$(`$t.Transport)|`$(`$t.Setting)|`$(`$t.Source)|`$(`$t.Remote)|`$(`$t.TaskRegistered)`""
        return $r.Out
    }
    foreach ($exe in $Exes.Keys) {
        $base = @{ TFVC_TRANSPORT = $null; SSH_CONNECTION = $null; SSH_CLIENT = $null; CLAUDE_TFVC_RELAY_LAUNCH = 'none'; CLAUDE_TFVC_RELAY_ROOT = $Relay }
        $got = Get-Transport $exe $base $ProjLocalRelay
        Check "$exe R9a settings.local.json TFVC_TRANSPORT beats settings.json" ($got -like 'relay|relay|settings.local.json|*') "got=[$got]"

        $got = Get-Transport $exe (Merge-Env $base @{ TFVC_TRANSPORT = 'relay' }) $ProjSharedDirect
        Check "$exe R9b settings.json TFVC_TRANSPORT beats the environment variable" ($got -like 'direct|direct|settings.json|*') "got=[$got]"

        $got = Get-Transport $exe (Merge-Env $base @{ TFVC_TRANSPORT = 'relay' }) $ProjNone
        Check "$exe R9c TFVC_TRANSPORT env var is used when the project has no setting" ($got -like 'relay|relay|env|*') "got=[$got]"

        $got = Get-Transport $exe $base $ProjNone
        Check "$exe R9d auto in a local session -> direct, registration not even checked" ($got -eq 'direct|auto|default|False|') "got=[$got]"

        $got = Get-Transport $exe (Merge-Env $base @{ SSH_CONNECTION = '10.0.0.1 50000 10.0.0.2 22'; CLAUDE_TFVC_RELAY_LAUNCH = 'child' }) $ProjNone
        Check "$exe R9e auto in an SSH session with the task registered -> relay" ($got -eq 'relay|auto|default|True|True') "got=[$got]"

        $got = Get-Transport $exe (Merge-Env $base @{ SSH_CLIENT = '10.0.0.1 50000 22'; CLAUDE_TFVC_RELAY_LAUNCH = 'none' }) $ProjNone
        Check "$exe R9f auto in an SSH session without the task -> direct" ($got -eq 'direct|auto|default|True|False') "got=[$got]"

        $r = Invoke-InChild $exe (Merge-Env $base @{ TFVC_TRANSPORT = 'sometimes' }) ". '$InvokeTf'; `$t = Resolve-TfTransport -ProjectDir '$ProjNone'; `$t.Setting"
        Check "$exe R9g unknown TFVC_TRANSPORT value -> auto plus one warning line" (($r.Out -match 'sometimes') -and ($r.Out -match '(?m)^auto$')) "out=[$($r.Out)]"

        # A held worker.lock means a worker is alive: auto picks relay without consulting the scheduler.
        New-Item -ItemType Directory -Path $Relay -Force | Out-Null
        $lockFs = [System.IO.File]::Open((Join-Path $Relay 'worker.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        try { $got = Get-Transport $exe (Merge-Env $base @{ SSH_CONNECTION = 'x'; CLAUDE_TFVC_RELAY_LAUNCH = 'none' }) $ProjNone } finally { $lockFs.Close() }
        Check "$exe R9h auto in an SSH session with a live worker (lock held) -> relay even when the task check says no" ($got -eq 'relay|auto|default|True|True') "got=[$got]"
    }
```

- [ ] **Step 2: Run test-relay.ps1 to verify R9 fails**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-relay.ps1`
Expected: R9a–R9h FAIL (script missing / function not recognized), R0 PASS.

- [ ] **Step 3: Create Invoke-Tf.ps1 with the selection functions**

```powershell
<#
.SYNOPSIS
  The one way the claude-tfvc plugin runs tf: directly, or relayed into the user's interactive Windows session.

.DESCRIPTION
  Command line (what the skill and the /tf-* commands run; every token after the script goes to tf as-is):
    powershell -NoProfile -ExecutionPolicy Bypass -File Invoke-Tf.ps1 <tf arguments>

  Transport (TFVC_TRANSPORT = auto | direct | relay, read like TF_EXE: project .claude\settings.local.json,
  .claude\settings.json, then the environment variable):
    direct  tf.exe runs as a child of this process: stdout and stdin are inherited handles (bytes untouched),
            stderr is relayed byte for byte and scanned for TF30063, the exit code is tf's.
    relay   the request goes through %LOCALAPPDATA%\claude-tfvc\relay\queue to Tf-RelayWorker.ps1, which the
            scheduled task ClaudeTfvcRelay runs in the interactive session, where network credentials exist.
    auto    relay when the session is remote (SSH_CONNECTION / SSH_CLIENT set) and the relay is available
            (a worker is alive or the task is registered), else direct.

  Exit codes: tf's own (0, 1, 2, 100); 120 relay unavailable; 124 relay timeout; 127 no tf.exe found.
  Dot-sourcing (". Invoke-Tf.ps1") only defines the functions; the hook calls Invoke-Tf -Capture.
  Test seams (environment only): CLAUDE_TFVC_RELAY_ROOT, CLAUDE_TFVC_RELAY_LAUNCH = child | none | noop.
  Windows PowerShell 5.1 and pwsh. Keep this file pure ASCII (5.1 reads BOM-less files in the ANSI code page).
#>
. (Join-Path $PSScriptRoot 'Find-Tf.ps1')

$TfvcScriptsDir    = $PSScriptRoot
$TfvcRelayTask     = 'ClaudeTfvcRelay'
$TfvcRelayProtocol = 1

function Get-TfAnsiEncoding {
    # The system ANSI code page: what tf.exe uses when its output is redirected. [Text.Encoding]::Default is
    # exactly that on Windows PowerShell 5.1 (.NET Framework) but UTF-8 on pwsh, hence the culture fallback.
    if ($PSVersionTable.PSEdition -eq 'Core') {
        try { return [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage) } catch { }
    }
    return [System.Text.Encoding]::Default
}

function Get-TfPluginVersion {
    $manifest = Join-Path $TfvcScriptsDir '..\..\..\.claude-plugin\plugin.json'
    try { return [string](Get-Content -LiteralPath $manifest -Raw -ErrorAction Stop | ConvertFrom-Json).version } catch { return 'unknown' }
}

function Get-TfRelayPaths {
    # Where the relay lives: %LOCALAPPDATA%\claude-tfvc\relay, or CLAUDE_TFVC_RELAY_ROOT (test seam).
    $root = $env:CLAUDE_TFVC_RELAY_ROOT
    if (-not $root) { $root = Join-Path $env:LOCALAPPDATA 'claude-tfvc\relay' }
    [pscustomobject]@{
        Root    = $root
        Queue   = Join-Path $root 'queue'
        Worker  = Join-Path $root 'Tf-RelayWorker.ps1'
        Version = Join-Path $root 'worker.version'
        Lock    = Join-Path $root 'worker.lock'
        Log     = Join-Path $root 'worker.log'
        Source  = Join-Path $TfvcScriptsDir 'Tf-RelayWorker.ps1'
    }
}

function Test-TfRemoteSession {
    # OpenSSH sets both for every session it starts; Claude Code's tool processes inherit them.
    return [bool]($env:SSH_CONNECTION -or $env:SSH_CLIENT)
}

function Test-TfRelayWorkerAlive {
    # The worker holds worker.lock open with FileShare.None for its whole life; "cannot open" means alive.
    param($Paths)
    if (-not (Test-Path -LiteralPath $Paths.Lock -PathType Leaf)) { return $false }
    try {
        $fs = [System.IO.File]::Open($Paths.Lock, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        $fs.Close()
        return $false
    }
    catch [System.IO.IOException] { return $true }
    catch { return $false }
}

function Test-TfRelayTaskRegistered {
    # Costs one module import (about half a second) on the real path; the seams answer instantly.
    switch ($env:CLAUDE_TFVC_RELAY_LAUNCH) {
        'child' { return $true }
        'noop'  { return $true }
        'none'  { return $false }
    }
    try { $null = Get-ScheduledTask -TaskName $TfvcRelayTask -ErrorAction Stop; return $true } catch { return $false }
}

function ConvertTo-TfRelayFailureText {
    # Task Scheduler LastTaskResult values met in practice (One.Net prototype), in words a user can act on.
    param([int64]$Code)
    switch ($Code) {
        0x00041303 { return 'the relay task could not start because you are not logged on to Windows interactively; connect once over RDP (you may disconnect afterwards, but do not sign out)' }
        0x8007052E { return 'logon failure: the relay task''s user does not match the current account or the password changed; re-run Register-TfRelay.ps1' }
        0x80070569 { return 'this logon type is denied for scheduled tasks by domain policy' }
        0x800710E0 { return 'the relay task refused to start (policy or task conditions); check Task Scheduler' }
    }
    return $null
}

function Get-TfRegistrationHint {
    return "relay task $TfvcRelayTask is not registered; register it once from any session of this user: powershell -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $TfvcScriptsDir 'Register-TfRelay.ps1')`" (or run /tf-relay)"
}

function Resolve-TfTransport {
    # TFVC_TRANSPORT = auto (default) | direct | relay, from the project settings then the environment, same
    # order as TF_EXE. In auto, relay needs a remote session AND an available relay (live worker or registered task).
    param([string]$ProjectDir)
    $setting = 'auto'; $source = 'default'
    $cfg = Get-ProjectEnvSetting -ProjectDir $ProjectDir -Name 'TFVC_TRANSPORT' -Detailed
    if ($cfg) { $setting = $cfg.Value; $source = $cfg.Source }
    elseif ($env:TFVC_TRANSPORT) { $setting = $env:TFVC_TRANSPORT; $source = 'env' }
    $setting = "$setting".Trim().ToLowerInvariant()
    if ($setting -notin 'auto', 'direct', 'relay') {
        [Console]::Error.WriteLine("claude-tfvc: ignoring unknown TFVC_TRANSPORT value '$setting' (expected auto, direct or relay)")
        $setting = 'auto'; $source = 'default'
    }
    $remote = Test-TfRemoteSession
    $registered = $null
    $transport = 'direct'
    if ($setting -eq 'relay') { $transport = 'relay' }
    elseif ($setting -eq 'auto' -and $remote) {
        if (Test-TfRelayWorkerAlive (Get-TfRelayPaths)) { $registered = $true } else { $registered = Test-TfRelayTaskRegistered }
        if ($registered) { $transport = 'relay' }
    }
    [pscustomobject]@{ Transport = $transport; Setting = $setting; Source = $source; Remote = $remote; TaskRegistered = $registered }
}
```

(The script has no body yet; Task 4 adds `Invoke-Tf` and the `if ($MyInvocation.InvocationName -ne '.')` block.)

- [ ] **Step 4: Run test-relay.ps1 to verify R9 passes**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-relay.ps1`
Expected: R9a–R9h PASS for every interpreter, R0 PASS, `0 failed`; the dot-source error from Task 1 is gone.

- [ ] **Step 5: Commit**

```bash
git add plugins/claude-tfvc/skills/tfvc/scripts/Invoke-Tf.ps1 tests/test-relay.ps1
git commit -m "Invoke-Tf.ps1: transport selection (TFVC_TRANSPORT, SSH detection, worker lock, task check)" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Direct mode, command-line quoting, orchestration and the script body

**Files:**
- Modify: `plugins/claude-tfvc/skills/tfvc/scripts/Invoke-Tf.ps1` (append functions and the body)
- Test: `tests/test-relay.ps1` (insert before `# ---- report`)

**Interfaces:**
- Consumes: everything from Task 3.
- Produces:
  - `ConvertTo-CommandLine -Arguments <string[]>` → string (CommandLineToArgvW-exact)
  - `New-TfResult -ExitCode -StdOut -StdErr -Transport -Diagnostic` → `[pscustomobject]@{ ExitCode; StdOut; StdErr; Transport; Diagnostic }`
  - `Invoke-TfDirect -Tf -Arguments -WorkingDirectory [-Capture]` → result object
  - `Invoke-TfRelay -Tf -Arguments -WorkingDirectory -TimeoutSec -PickupTimeoutSec` → result object (stub here, real in Task 7)
  - `Invoke-Tf -Arguments [-ProjectDir] [-WorkingDirectory] [-Capture] [-TimeoutSec 600] [-PickupTimeoutSec 30]` → result object
  - Script body: runs `Invoke-Tf -Arguments $args`, prints relay output as UTF-8, exits with the code.

- [ ] **Step 1: Add the failing checks R13, R1, R3, R14, R15, R32 to test-relay.ps1**

Insert before `# ---- report`:

```powershell
    # ---- R13 command-line quoting (CommandLineToArgvW round trip through the fake's Main) --------------
    $HardArgs = @('plain', 'with space', 'quote"inside', 'trail\', 'trail\\', 'back\slash', '"', '', 'a b"c\', "tab`there",
                  $Sample, '%TEMP%', '&|^<>', '/comment:He said "hi" & left', 'D:\Projects\X\')
    $HardJson = Join-Path $S 'hard-args.json'
    [System.IO.File]::WriteAllText($HardJson, (ConvertTo-Json -InputObject $HardArgs -Compress), $Utf8)
    function Compare-Args([string[]]$Expected, $Got) {
        if ($null -eq $Got) { return "no call logged" }
        if (@($Got).Count -ne $Expected.Count) { return "count $(@($Got).Count) != $($Expected.Count): [$(@($Got) -join '|')]" }
        for ($i = 0; $i -lt $Expected.Count; $i++) { if (@($Got)[$i] -cne $Expected[$i]) { return "arg $i got [$(@($Got)[$i])] want [$($Expected[$i])]" } }
        return ''
    }
    if ($HaveFake) {
        foreach ($exe in $Exes.Keys) {
            Reset-FakeLog
            $r = Invoke-InChild $exe $DirectEnv ". '$InvokeTf'; `$a = [string[]](Get-Content -LiteralPath '$HardJson' -Raw -Encoding UTF8 | ConvertFrom-Json); `$x = Invoke-TfDirect -Tf '$FakeTf' -Arguments `$a -WorkingDirectory '$S' -Capture; `$x.ExitCode"
            $diff = Compare-Args $HardArgs @(Get-FakeCalls)[0]
            Check "$exe R13 ConvertTo-CommandLine round-trips spaces, quotes, trailing backslashes, empty, Hebrew, Cyrillic, %, &" ($diff -eq '' -and $r.Out -match '(?m)^0$') "$diff exit=[$($r.Out)]"
        }
    } else { Skip 'R13 quoting round trip' 'no fake tf.exe' }

    # ---- R1 / R3 / R14 / R15 / R32 direct mode through the real command line (powershell -File) ----------
    if ($HaveFake) {
        foreach ($exe in $Exes.Keys) {
            foreach ($code in 0, 1, 100) {
                $r = Invoke-Launcher $exe $DirectEnv @('status', 'a b', "/exit:$code", '/stdout:hello out', '/stderr:oops err')
                Check "$exe R1 direct: exit $code passes through, stdout and stderr reach the caller, args reach tf" `
                    (($r.Exit -eq $code) -and ($r.Out.Trim() -eq 'hello out') -and ($r.Err -match 'oops err') -and ($r.Calls.Count -eq 1) -and ($r.Calls[0][1] -eq 'a b')) "exit=$($r.Exit) out=[$($r.Out.Trim())] err=[$($r.Err.Trim())] args=[$($r.Calls[0] -join '|')]"
            }

            $core = @('status', 'with space', 'trail\', 'D:\Projects\X\', $Sample, '%TEMP%', '&|^<>', '-noprompt', '/noprompt')
            $r = Invoke-Launcher $exe $DirectEnv $core
            $diff = Compare-Args $core $r.Calls[0]
            Check "$exe R3 powershell -File passes spaces, trailing backslashes, Hebrew, Cyrillic, %, & and both option styles unchanged" ($diff -eq '') $diff

            $quoted = @('checkin', '/comment:He said "hi" & left', 'file.cs')
            $r = Invoke-Launcher $exe $DirectEnv $quoted
            $diff = Compare-Args $quoted $r.Calls[0]
            Check "$exe R3q an embedded double quote survives powershell -File (if this fails, document the limitation in SKILL.md, Task 10)" ($diff -eq '') $diff

            $r = Invoke-Launcher $exe $DirectEnv @('status', '/stderr:TF30063: You are not authorized to access http://tfs:8080/tfs.')
            Check "$exe R15a direct + auto + TF30063 on stderr -> the original line plus one /tf-relay hint line" `
                (($r.Err -match 'TF30063: You are not authorized') -and ($r.Err -match 'Run /tf-relay')) "err=[$($r.Err.Trim())]"

            $r = Invoke-Launcher $exe (Merge-Env $DirectEnv @{ TFVC_TRANSPORT = 'direct' }) @('status', '/stderr:TF30063: nope')
            Check "$exe R15b forced direct -> no hint even on TF30063" (($r.Err -match 'TF30063') -and ($r.Err -notmatch '/tf-relay')) "err=[$($r.Err.Trim())]"

            $r = Invoke-Launcher $exe $DirectEnv @('status', '/stderr:TF10140: no mapping')
            Check "$exe R15c other errors -> stderr relayed, no hint" (($r.Err -match 'TF10140') -and ($r.Err -notmatch '/tf-relay')) "err=[$($r.Err.Trim())]"

            $r = Invoke-Launcher $exe $DirectEnv @('get', '/big')
            Check "$exe R32a direct streaming: 300 KB on each stream, no deadlock, nothing lost" (($r.Exit -eq 0) -and ($r.OutBytes.Length -eq 303000) -and ($r.ErrBytes.Length -eq 303000)) "exit=$($r.Exit) out=$($r.OutBytes.Length) err=$($r.ErrBytes.Length)"

            $r = Invoke-InChild $exe $DirectEnv ". '$InvokeTf'; `$x = Invoke-TfDirect -Tf '$FakeTf' -Arguments @('get','/big') -WorkingDirectory '$S' -Capture; `"`$(`$x.ExitCode)|`$(`$x.StdOut.Length)|`$(`$x.StdErr.Length)`""
            Check "$exe R32b direct capture: both streams read concurrently, 300 KB each" ($r.Out -match '(?m)^0\|303000\|303000$') "out=[$($r.Out)]"
        }

        $PfEmpty = Join-Path $S 'pf-empty'; New-Item -ItemType Directory -Path $PfEmpty -Force | Out-Null
        $MinPath = "$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
        foreach ($exe in $Exes.Keys) {
            # ProgramFiles must be overridden INSIDE the child: Windows re-derives it for every new 64-bit process.
            $prelude = "Remove-Item Env:\TF_EXE -ErrorAction SilentlyContinue; `$env:PATH = '$MinPath'; `$env:ProgramFiles = '$PfEmpty'; `${env:ProgramFiles(x86)} = '$PfEmpty'; `$env:CLAUDE_PROJECT_DIR = '$ProjNone'"
            $r = Invoke-InChild $exe @{} "$prelude; & '$InvokeTf' status; exit `$LASTEXITCODE"
            Check "$exe R14 no tf.exe anywhere -> exit 127 and a one-line explanation" (($r.Exit -eq 127) -and ($r.Out -match 'no tf.exe found')) "exit=$($r.Exit) out=[$($r.Out)]"
        }
    } else { Skip 'R1/R3/R14/R15/R32 direct mode' 'no fake tf.exe' }
```

- [ ] **Step 2: Run test-relay.ps1 to verify the new checks fail**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-relay.ps1`
Expected: R13, R1, R3, R3q, R14, R15a–c, R32a–b FAIL (`Invoke-TfDirect`/`ConvertTo-CommandLine` not recognized, script produces nothing); R0 and R9 PASS.

- [ ] **Step 3: Append the functions and the body to Invoke-Tf.ps1**

Append after `Resolve-TfTransport`:

```powershell
function ConvertTo-CommandLine {
    # Joins arguments into one Windows command line that CommandLineToArgvW (and every .NET Main) parses back
    # into exactly the same strings. An argument is used as-is when it is non-empty and has no space, tab,
    # newline or double quote; otherwise it is quoted, N backslashes before a double quote become 2N+1
    # backslashes plus \", and N trailing backslashes become 2N. .NET Framework's ProcessStartInfo has no
    # ArgumentList, so this is by hand. IDENTICAL COPY in Tf-RelayWorker.ps1 (installed as a single file).
    param([string[]]$Arguments)
    $parts = foreach ($arg in @($Arguments)) {
        $a = "$arg"
        if ($a.Length -gt 0 -and $a -notmatch '[\s"]') { $a; continue }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('"')
        $slashes = 0
        foreach ($ch in $a.ToCharArray()) {
            if ($ch -eq '\') { $slashes++; continue }
            if ($ch -eq '"') { [void]$sb.Append('\', $slashes * 2 + 1).Append('"') }
            else { [void]$sb.Append('\', $slashes).Append($ch) }
            $slashes = 0
        }
        [void]$sb.Append('\', $slashes * 2).Append('"')
        $sb.ToString()
    }
    return (@($parts) -join ' ')
}

function New-TfResult {
    param([int]$ExitCode, [string]$StdOut, [string]$StdErr, [string]$Transport, [string]$Diagnostic)
    [pscustomobject]@{ ExitCode = $ExitCode; StdOut = $StdOut; StdErr = $StdErr; Transport = $Transport; Diagnostic = $Diagnostic }
}

function Invoke-TfDirect {
    # Runs tf.exe as a child process. Streaming (default): stdout and stdin are inherited handles, stderr is
    # copied byte for byte to our stderr and kept for the TF30063 check. -Capture: both streams are read
    # concurrently (no pipe deadlock) and decoded from the system ANSI code page.
    param([string]$Tf, [string[]]$Arguments, [string]$WorkingDirectory, [switch]$Capture)
    $ansi = Get-TfAnsiEncoding
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Tf
    $psi.Arguments = ConvertTo-CommandLine $Arguments
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = [bool]$Capture
    $psi.StandardErrorEncoding = $ansi
    if ($Capture) { $psi.StandardOutputEncoding = $ansi }
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    catch { return New-TfResult -ExitCode 127 -Transport 'direct' -Diagnostic "claude-tfvc: cannot start '$Tf': $($_.Exception.Message)" }
    if ($Capture) {
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        $p.WaitForExit()
        return New-TfResult -ExitCode $p.ExitCode -StdOut $outTask.Result -StdErr $errTask.Result -Transport 'direct'
    }
    $buffer = New-Object byte[] 4096
    $kept   = New-Object System.IO.MemoryStream
    $ours   = [Console]::OpenStandardError()
    $theirs = $p.StandardError.BaseStream
    while (($n = $theirs.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $ours.Write($buffer, 0, $n); $ours.Flush()
        $kept.Write($buffer, 0, $n)
    }
    $p.WaitForExit()
    return New-TfResult -ExitCode $p.ExitCode -StdErr $ansi.GetString($kept.ToArray()) -Transport 'direct'
}

function Invoke-TfRelay {
    # Replaced by the real relay client in the next step of the work (Task 7 of the plan).
    param([string]$Tf, [string[]]$Arguments, [string]$WorkingDirectory, [int]$TimeoutSec = 600, [int]$PickupTimeoutSec = 30)
    return New-TfResult -ExitCode 120 -Transport 'relay' -Diagnostic 'claude-tfvc: relay client not available in this build'
}

function Invoke-Tf {
    # Resolves tf.exe (Find-Tf.ps1), picks the transport, runs tf, returns { ExitCode, StdOut, StdErr, Transport, Diagnostic }.
    # Without -Capture, direct mode streams to the console and StdOut is $null. The hook uses -Capture.
    param([string[]]$Arguments, [string]$ProjectDir, [string]$WorkingDirectory, [switch]$Capture, [int]$TimeoutSec = 600, [int]$PickupTimeoutSec = 30)
    if (-not $ProjectDir) { $ProjectDir = $env:CLAUDE_PROJECT_DIR }
    if (-not $ProjectDir) { $ProjectDir = (Get-Location).Path }
    if (-not $WorkingDirectory) { $WorkingDirectory = (Get-Location).Path }
    $tf = Resolve-TfExe -ProjectDir $ProjectDir
    if (-not $tf) {
        return New-TfResult -ExitCode 127 -Transport 'none' -Diagnostic 'claude-tfvc: no tf.exe found (checked the project .claude\settings*.json env.TF_EXE, TF_EXE, PATH, vswhere and the Visual Studio folders); install Team Explorer or pick one with /tf-select'
    }
    $choice = Resolve-TfTransport -ProjectDir $ProjectDir
    if ($choice.Transport -eq 'relay') {
        if (-not (Test-TfRelayWorkerAlive (Get-TfRelayPaths)) -and -not (Test-TfRelayTaskRegistered)) {
            return New-TfResult -ExitCode 120 -Transport 'relay' -Diagnostic ('claude-tfvc: ' + (Get-TfRegistrationHint))
        }
        return Invoke-TfRelay -Tf $tf -Arguments $Arguments -WorkingDirectory $WorkingDirectory -TimeoutSec $TimeoutSec -PickupTimeoutSec $PickupTimeoutSec
    }
    $r = Invoke-TfDirect -Tf $tf -Arguments $Arguments -WorkingDirectory $WorkingDirectory -Capture:$Capture
    if ($choice.Setting -eq 'auto' -and "$($r.StdErr)" -match 'TF30063') {
        $hint = 'claude-tfvc: TF30063 usually means this session has no network credentials (SSH key logon). Run /tf-relay to route tf through your interactive Windows session.'
        if ($Capture) { $r.Diagnostic = $hint } else { [Console]::Error.WriteLine($hint) }
    }
    return $r
}

if ($MyInvocation.InvocationName -ne '.') {
    $timeout = 600
    if ($env:TFVC_RELAY_TIMEOUT -match '^\d+$') { $timeout = [int]$env:TFVC_RELAY_TIMEOUT }
    $result = Invoke-Tf -Arguments $args -TimeoutSec $timeout
    $utf8 = New-Object System.Text.UTF8Encoding $false
    if ($result.Transport -eq 'relay') {
        # Relay output is Unicode already (the worker decoded tf's ANSI bytes); hand it to Claude Code as UTF-8.
        if ($result.StdOut) { $w = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), $utf8); $w.Write($result.StdOut); $w.Flush() }
        if ($result.StdErr) { $w = New-Object System.IO.StreamWriter([Console]::OpenStandardError(), $utf8); $w.Write($result.StdErr); $w.Flush() }
    }
    if ($result.Diagnostic) { $w = New-Object System.IO.StreamWriter([Console]::OpenStandardError(), $utf8); $w.WriteLine($result.Diagnostic); $w.Flush() }
    exit $result.ExitCode
}
```

Note: `Find-Tf.ps1` sets `$ErrorActionPreference = 'SilentlyContinue'` in whatever scope dot-sources it, so this file inherits it when run as a script and never changes it (the hook relies on `SilentlyContinue` too). Every error this file must react to is a .NET exception inside `try` or a cmdlet called with `-ErrorAction Stop`.

- [ ] **Step 4: Run test-relay.ps1 to verify the direct-mode checks pass**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-relay.ps1`
Expected: R13, R1 (×3), R3, R14, R15a–c, R32a–b PASS on both interpreters, `0 failed`. R3q may FAIL on `powershell` if Windows PowerShell 5.1 re-parses `-File` arguments; if it does, note the exact failing argument in `docs/plans/relay-notes.md` (create it; one line) so Task 10 documents the limitation, and change R3q's `Check` to `Skip` with the reason "5.1 -File re-parses embedded quotes; documented in SKILL.md". Do not change the quoting function for this: R13 proves the quoting is right, the loss happens before the script runs.

- [ ] **Step 5: Run test-hook.ps1 to confirm nothing regressed**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-hook.ps1`
Expected: `0 failed`.

- [ ] **Step 6: Commit**

```bash
git add plugins/claude-tfvc/skills/tfvc/scripts/Invoke-Tf.ps1 tests/test-relay.ps1
git commit -m "Invoke-Tf.ps1: byte-transparent direct mode, CommandLineToArgvW quoting, TF30063 hint, exit codes" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Worker, part 1: processing one request

**Files:**
- Create: `plugins/claude-tfvc/skills/tfvc/scripts/Tf-RelayWorker.ps1`
- Test: `tests/test-relay.ps1` (insert before `# ---- report`)

**Interfaces:**
- Consumes: nothing from other scripts (the worker is installed alone and dot-sources nothing); request/response JSON from design section 7.2.
- Produces (dot-sourceable for tests): `$RelayRoot`, `$RelayQueue`, `$RelayLock`, `$RelayLog`, `$RelayLingerSec`, `$WorkerVersion`; `Get-AnsiEncoding`; `ConvertTo-CommandLine` (identical to the launcher's); `Write-RelayLog -Message`; `Write-JsonAtomic -Path -Object`; `Test-TfExecutable -Path` → `$null` or refusal text; `Invoke-RelayRequest -RunPath` (writes `<id>.res.json`, deletes the `.run.json`, logs one line).

- [ ] **Step 1: Add the worker helpers and failing checks to test-relay.ps1**

Insert before `# ---- report`:

```powershell
    # ---- worker: one request at a time (Invoke-RelayRequest, powershell.exe only) ----------------------
    $Queue = Join-Path $Relay 'queue'
    function New-Request([string[]]$TfArgs, [hashtable]$Overrides) {
        $id = [guid]::NewGuid().ToString('n')
        $now = [DateTime]::UtcNow
        $req = [ordered]@{ protocol = 1; id = $id; tf = $FakeTf; args = $TfArgs; cwd = $S; createdUtc = $now.ToString('o'); expiresUtc = $now.AddSeconds(30).ToString('o') }
        if ($Overrides) { foreach ($k in $Overrides.Keys) { $req[$k] = $Overrides[$k] } }
        return $req
    }
    function Invoke-WorkerRequest($Request, [hashtable]$ExtraEnv, [string]$RawText) {
        # Drops <id>.run.json into the queue and runs Invoke-RelayRequest on it in a child Windows PowerShell.
        Reset-FakeLog
        New-Item -ItemType Directory -Path $Queue -Force | Out-Null
        $id = $Request.id
        $runPath = Join-Path $Queue "$id.run.json"
        if ($RawText) { [System.IO.File]::WriteAllText($runPath, $RawText, $Utf8) }
        else { [System.IO.File]::WriteAllText($runPath, ($Request | ConvertTo-Json -Depth 4 -Compress), $Utf8) }
        $envVars = Merge-Env @{ CLAUDE_TFVC_RELAY_ROOT = $Relay; CLAUDE_TFVC_RELAY_ALLOW_UNSIGNED = '1' } $(if ($ExtraEnv) { $ExtraEnv } else { @{} })
        $r = Invoke-InChild 'powershell' $envVars ". '$Worker'; Invoke-RelayRequest -RunPath '$runPath'"
        $resPath = Join-Path $Queue "$id.res.json"
        $res = if (Test-Path -LiteralPath $resPath) { Get-Content -LiteralPath $resPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
        $log = if (Test-Path -LiteralPath (Join-Path $Relay 'worker.log')) { Get-Content -LiteralPath (Join-Path $Relay 'worker.log') -Raw } else { '' }
        return @{ Res = $res; RunLeft = (Test-Path -LiteralPath $runPath); Calls = @(Get-FakeCalls); Log = $log; Out = $r.Out }
    }
    if ($HaveFake) {
        Reset-Relay
        $w = Invoke-WorkerRequest (New-Request @('status', 'x.cs'))
        Check 'R8a /noprompt is appended when absent' (($w.Calls.Count -eq 1) -and ($w.Calls[0][-1] -eq '/noprompt') -and (@($w.Calls[0] | Where-Object { $_ -match '^[/-]noprompt$' }).Count -eq 1)) "args=[$($w.Calls[0] -join '|')]"
        $w = Invoke-WorkerRequest (New-Request @('status', '/noprompt', 'x.cs'))
        Check 'R8b /noprompt present -> not duplicated' (($w.Calls.Count -eq 1) -and (@($w.Calls[0] | Where-Object { $_ -match '^[/-]noprompt$' }).Count -eq 1)) "args=[$($w.Calls[0] -join '|')]"
        $w = Invoke-WorkerRequest (New-Request @('status', '-noprompt'))
        Check 'R8c -noprompt counts as present' (($w.Calls.Count -eq 1) -and ($w.Calls[0] -notcontains '/noprompt')) "args=[$($w.Calls[0] -join '|')]"

        $w = Invoke-WorkerRequest (New-Request @('checkin', '/comment:secret') @{ expiresUtc = [DateTime]::UtcNow.AddSeconds(-5).ToString('o') })
        Check 'R6 expired request: not run, deleted, logged, no response' (($w.Calls.Count -eq 0) -and (-not $w.RunLeft) -and ($null -eq $w.Res) -and ($w.Log -match 'expired')) "calls=$($w.Calls.Count) runLeft=$($w.RunLeft) res=$($null -ne $w.Res)"

        $w = Invoke-WorkerRequest (New-Request @('status')) @{ CLAUDE_TFVC_RELAY_ALLOW_UNSIGNED = $null }
        Check 'R12a unsigned tf.exe refused without the bypass (error in the response, tf not run)' (($w.Calls.Count -eq 0) -and ($w.Res.error -match 'not a Microsoft-signed')) "error=[$($w.Res.error)] calls=$($w.Calls.Count)"
        $NotTf = Join-Path $FakeDir 'notf.exe'; Copy-Item -LiteralPath $FakeTf -Destination $NotTf -Force
        $w = Invoke-WorkerRequest (New-Request @('status') @{ tf = $NotTf })
        Check 'R12b an executable not named tf.exe is refused even with the bypass' (($w.Calls.Count -eq 0) -and ($w.Res.error -match 'must be named tf.exe')) "error=[$($w.Res.error)]"

        $w = Invoke-WorkerRequest (New-Request @('status', '/ansi'))
        Check 'R4 ANSI (Hebrew/Cyrillic) stdout is decoded to Unicode in the response' ($w.Res.stdout.StartsWith($SampleRT)) "stdout=[$($w.Res.stdout.Trim())] want=[$SampleRT]"

        $w = Invoke-WorkerRequest (New-Request @('status') @{ protocol = 2 })
        Check 'R20 unknown protocol -> error naming both versions, tf not run' (($w.Calls.Count -eq 0) -and ($w.Res.error -match 'protocol 2 is not supported') -and ($w.Res.error -match 'protocol 1')) "error=[$($w.Res.error)]"

        $w = Invoke-WorkerRequest (New-Request @('status', '/exit:100', '/stderr:boom'))
        Check 'R34 exit code and stderr pass through the response' (($w.Res.exitCode -eq 100) -and ($w.Res.stderr -match 'boom') -and (-not $w.RunLeft)) "exit=$($w.Res.exitCode) stderr=[$($w.Res.stderr.Trim())]"

        $w = Invoke-WorkerRequest (New-Request @('checkin', '/comment:secret-comment', 'D:\secret\path.cs'))
        $line = @($w.Log -split "`r?`n" | Where-Object { $_ -match $w.Res.id }) | Select-Object -Last 1
        Check 'R21 log line: utc id verb exit duration; no comment, no path' (($line -match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z [0-9a-f]{32} checkin exit=0 \d+ms$') -and ($w.Log -notmatch 'secret')) "line=[$line]"

        $w = Invoke-WorkerRequest (New-Request @('get', '/big'))
        Check 'R32c worker reads 300 KB on each stream concurrently (no deadlock)' (($w.Res.stdout.Length -eq 303000) -and ($w.Res.stderr.Length -eq 303000)) "out=$($w.Res.stdout.Length) err=$($w.Res.stderr.Length)"

        $w = Invoke-WorkerRequest (New-Request @('status')) @{} '{ this is not json'
        Check 'R35 malformed request file: deleted, logged, no response, tf not run' ((-not $w.RunLeft) -and ($null -eq $w.Res) -and ($w.Log -match 'malformed') -and ($w.Calls.Count -eq 0)) "runLeft=$($w.RunLeft) log=[$($w.Log)]"
    } else { Skip 'R4/R6/R8/R12/R20/R21/R32c/R34/R35 worker request processing' 'no fake tf.exe' }

    # ---- static: the quoting function is one implementation in two files -------------------------------
    function Get-FunctionText([string]$File, [string]$Name) {
        $m = [regex]::Match((Get-Content -LiteralPath $File -Raw), "(?s)\r?\nfunction $Name \{.*?\r?\n\}")
        if ($m.Success) { return ($m.Value -replace '\r', '') } else { return "<missing in $File>" }
    }
    Check 'R36 ConvertTo-CommandLine in Invoke-Tf.ps1 and Tf-RelayWorker.ps1 are identical' `
        ((Get-FunctionText $InvokeTf 'ConvertTo-CommandLine') -eq (Get-FunctionText $Worker 'ConvertTo-CommandLine')) 'copies differ (or one is missing)'
```

- [ ] **Step 2: Run test-relay.ps1 to verify the worker checks fail**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-relay.ps1`
Expected: R8a–c, R6, R12a–b, R4, R20, R34, R21, R32c, R35, R36 FAIL (worker file missing); everything earlier PASS.

- [ ] **Step 3: Create Tf-RelayWorker.ps1 (functions only; the loop comes in Task 6)**

```powershell
<#
.SYNOPSIS
  claude-tfvc relay worker: runs tf.exe inside the user's interactive Windows session on behalf of sessions that
  have no network credentials (SSH). Started on demand by the scheduled task ClaudeTfvcRelay.

.DESCRIPTION
  Queue: <root>\queue\<id>.req.json (waiting) -> <id>.run.json (claimed) -> <id>.res.json (answered), where
  <root> is %LOCALAPPDATA%\claude-tfvc\relay or CLAUDE_TFVC_RELAY_ROOT (test seam).
  Rules: one worker at a time (worker.lock held with FileShare.None); oldest request first; an expired request
  is deleted unrun; only an executable named tf.exe with a valid Microsoft Authenticode signature is started
  (CLAUDE_TFVC_RELAY_ALLOW_UNSIGNED=1 in THIS process's environment is the test bypass; a request cannot set it);
  /noprompt is always present; stdin is closed; output is decoded from the system ANSI code page; the log never
  records comments, further arguments, paths or output. The worker lingers CLAUDE_TFVC_RELAY_LINGER_SEC (default
  15) after the queue empties and stops after 50 minutes of life (the task's limit is 1 hour).
  Installed as ONE file by Invoke-Tf.ps1: it must not dot-source anything. Dot-sourcing it only defines the
  functions (tests). Windows PowerShell 5.1; keep this file pure ASCII.
#>
$ErrorActionPreference = 'Continue'

$RelayProtocol   = 1
$RelayRoot       = if ($env:CLAUDE_TFVC_RELAY_ROOT) { $env:CLAUDE_TFVC_RELAY_ROOT } else { Join-Path $env:LOCALAPPDATA 'claude-tfvc\relay' }
$RelayQueue      = Join-Path $RelayRoot 'queue'
$RelayLock       = Join-Path $RelayRoot 'worker.lock'
$RelayLog        = Join-Path $RelayRoot 'worker.log'
$RelayLingerSec  = if ($env:CLAUDE_TFVC_RELAY_LINGER_SEC -match '^\d+$') { [int]$env:CLAUDE_TFVC_RELAY_LINGER_SEC } else { 15 }
$RelayMaxLifeMin = 50
$RelayOrphanMin  = 60
$WorkerVersion   = 'dev'
$versionFile = Join-Path $PSScriptRoot 'worker.version'
if (Test-Path -LiteralPath $versionFile) {
    $m = [regex]::Match((Get-Content -LiteralPath $versionFile -Raw), '(?m)^version=(.+)$')
    if ($m.Success) { $WorkerVersion = $m.Groups[1].Value.Trim() }
}
$VerifiedTf = @{}

function Get-AnsiEncoding {
    # The system ANSI code page (what tf.exe writes when redirected). Exact on Windows PowerShell 5.1.
    if ($PSVersionTable.PSEdition -eq 'Core') {
        try { return [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage) } catch { }
    }
    return [System.Text.Encoding]::Default
}

function ConvertTo-CommandLine {
    # Joins arguments into one Windows command line that CommandLineToArgvW (and every .NET Main) parses back
    # into exactly the same strings. An argument is used as-is when it is non-empty and has no space, tab,
    # newline or double quote; otherwise it is quoted, N backslashes before a double quote become 2N+1
    # backslashes plus \", and N trailing backslashes become 2N. .NET Framework's ProcessStartInfo has no
    # ArgumentList, so this is by hand. IDENTICAL COPY in Tf-RelayWorker.ps1 (installed as a single file).
    param([string[]]$Arguments)
    $parts = foreach ($arg in @($Arguments)) {
        $a = "$arg"
        if ($a.Length -gt 0 -and $a -notmatch '[\s"]') { $a; continue }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('"')
        $slashes = 0
        foreach ($ch in $a.ToCharArray()) {
            if ($ch -eq '\') { $slashes++; continue }
            if ($ch -eq '"') { [void]$sb.Append('\', $slashes * 2 + 1).Append('"') }
            else { [void]$sb.Append('\', $slashes).Append($ch) }
            $slashes = 0
        }
        [void]$sb.Append('\', $slashes * 2).Append('"')
        $sb.ToString()
    }
    return (@($parts) -join ' ')
}

function Write-RelayLog {
    # One ASCII line per event; rotates to worker.1.log at 1 MB. Never log comments, paths or tf output.
    param([string]$Message)
    try {
        if ((Test-Path -LiteralPath $RelayLog) -and ((Get-Item -LiteralPath $RelayLog).Length -gt 1MB)) {
            Move-Item -LiteralPath $RelayLog -Destination ($RelayLog -replace '\.log$', '.1.log') -Force
        }
        Add-Content -LiteralPath $RelayLog -Value ('{0:yyyy-MM-ddTHH:mm:ss.fff}Z {1}' -f [DateTime]::UtcNow, $Message) -Encoding Ascii
    } catch { }
}

function Write-JsonAtomic {
    # UTF-8 without BOM, written to a .tmp name and renamed into place so a reader never sees a partial file.
    param([string]$Path, $Object)
    $tmp = "$Path.$([guid]::NewGuid().ToString('n')).tmp"
    [System.IO.File]::WriteAllText($tmp, ($Object | ConvertTo-Json -Depth 4 -Compress), (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Test-TfExecutable {
    # $null when the file may run, otherwise the refusal text. Only tf.exe, only Microsoft-signed; cached per path.
    param([string]$Path)
    if ([System.IO.Path]::GetFileName($Path) -ine 'tf.exe') { return "refusing to run '$Path': the executable must be named tf.exe" }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "tf.exe not found at '$Path'" }
    if ($env:CLAUDE_TFVC_RELAY_ALLOW_UNSIGNED -eq '1') { return $null }
    if ($VerifiedTf.ContainsKey($Path)) { return $VerifiedTf[$Path] }
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    $verdict = $null
    if ($sig.Status -ne 'Valid' -or "$($sig.SignerCertificate.Subject)" -notmatch 'O=Microsoft Corporation') {
        $verdict = "refusing to run '$Path': not a Microsoft-signed tf.exe (signature status: $($sig.Status))"
    }
    $VerifiedTf[$Path] = $verdict
    return $verdict
}

function Invoke-RelayRequest {
    # Processes one claimed request (<id>.run.json): validates, runs tf.exe, writes <id>.res.json, logs one line.
    param([string]$RunPath)
    $started = [DateTime]::UtcNow
    $id = [System.IO.Path]::GetFileName($RunPath) -replace '\.run\.json$', ''
    $res = [ordered]@{ id = $id; exitCode = 120; stdout = ''; stderr = ''; error = $null; workerVersion = $WorkerVersion; startedUtc = $started.ToString('o'); finishedUtc = $null }
    $verb = '?'
    try {
        try { $req = Get-Content -LiteralPath $RunPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { Write-RelayLog "$id malformed request, deleted"; Remove-Item -LiteralPath $RunPath -Force -ErrorAction SilentlyContinue; return }
        if ($null -eq $req) { Write-RelayLog "$id malformed request, deleted"; Remove-Item -LiteralPath $RunPath -Force -ErrorAction SilentlyContinue; return }
        $argList = @(@($req.args) | ForEach-Object { "$_" })
        if ($argList.Count -gt 0) { $verb = $argList[0] }
        if ($req.protocol -ne $RelayProtocol) {
            $res.error = "protocol $($req.protocol) is not supported by relay worker $WorkerVersion (protocol $RelayProtocol); update the worker by running any tf command from the plugin or Register-TfRelay.ps1"
        }
        elseif ([DateTime]::Parse("$($req.expiresUtc)", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() -lt [DateTime]::UtcNow) {
            Write-RelayLog "$id $verb expired, deleted unrun"
            Remove-Item -LiteralPath $RunPath -Force -ErrorAction SilentlyContinue
            return
        }
        else {
            $refusal = Test-TfExecutable "$($req.tf)"
            if ($refusal) { $res.error = $refusal }
            else {
                if (-not ($argList | Where-Object { $_ -match '^[/-]noprompt$' })) { $argList += '/noprompt' }
                $ansi = Get-AnsiEncoding
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "$($req.tf)"
                $psi.Arguments = ConvertTo-CommandLine $argList
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $psi.WorkingDirectory = "$($req.cwd)"
                $psi.RedirectStandardInput = $true
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.StandardOutputEncoding = $ansi
                $psi.StandardErrorEncoding = $ansi
                try {
                    $p = [System.Diagnostics.Process]::Start($psi)
                    $p.StandardInput.Close()
                    $outTask = $p.StandardOutput.ReadToEndAsync()
                    $errTask = $p.StandardError.ReadToEndAsync()
                    $p.WaitForExit()
                    $res.stdout = $outTask.Result; $res.stderr = $errTask.Result; $res.exitCode = $p.ExitCode
                } catch { $res.error = "tf.exe failed to start: $($_.Exception.Message)" }
            }
        }
    } catch { $res.error = "worker error: $($_.Exception.Message)" }
    $res.finishedUtc = [DateTime]::UtcNow.ToString('o')
    Write-JsonAtomic -Path (Join-Path $RelayQueue "$id.res.json") -Object $res
    Remove-Item -LiteralPath $RunPath -Force -ErrorAction SilentlyContinue
    $ms = [int]([DateTime]::UtcNow - $started).TotalMilliseconds
    $what = if ($res.error) { 'error' } else { "exit=$($res.exitCode)" }
    Write-RelayLog "$id $verb $what ${ms}ms"
}
```

- [ ] **Step 4: Run test-relay.ps1 to verify the worker checks pass**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-relay.ps1`
Expected: all R4/R6/R8/R12/R20/R21/R32c/R34/R35/R36 PASS, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add plugins/claude-tfvc/skills/tfvc/scripts/Tf-RelayWorker.ps1 tests/test-relay.ps1
git commit -m "Tf-RelayWorker.ps1: process one request (signed tf.exe only, /noprompt, ANSI decode, expiry, log)" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Worker, part 2: lock, loop, sweep, linger

**Files:**
- Modify: `plugins/claude-tfvc/skills/tfvc/scripts/Tf-RelayWorker.ps1` (append)
- Test: `tests/test-relay.ps1` (insert before `# ---- report`)

**Interfaces:**
- Consumes: Task 5 functions.
- Produces: `Remove-RelayOrphans`, `Start-RelayWorker`, and the script body `if ($MyInvocation.InvocationName -ne '.') { Start-RelayWorker }`. Running the file as a script now drains the queue and exits after the linger.

- [ ] **Step 1: Add the failing loop checks**

Insert before `# ---- report`:

```powershell
    # ---- worker: the loop (run as a real child process, powershell.exe) ---------------------------------
    function Start-WorkerChild([hashtable]$ExtraEnv) {
        $envVars = Merge-Env @{ CLAUDE_TFVC_RELAY_ROOT = $Relay; CLAUDE_TFVC_RELAY_ALLOW_UNSIGNED = '1'; CLAUDE_TFVC_RELAY_LINGER_SEC = '1' } $(if ($ExtraEnv) { $ExtraEnv } else { @{} })
        $saved = Set-TestEnv $envVars
        try { return (Start-Process -FilePath $Exes.powershell -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Worker`"" -WindowStyle Hidden -PassThru) }
        finally { Restore-TestEnv $saved }
    }
    function Write-QueuedRequest($Request, [string]$Kind = 'req') {
        New-Item -ItemType Directory -Path $Queue -Force | Out-Null
        $path = Join-Path $Queue "$($Request.id).$Kind.json"
        [System.IO.File]::WriteAllText($path, ($Request | ConvertTo-Json -Depth 4 -Compress), $Utf8)
        return $path
    }
    function Get-WorkerLog { if (Test-Path -LiteralPath (Join-Path $Relay 'worker.log')) { Get-Content -LiteralPath (Join-Path $Relay 'worker.log') } else { @() } }
    if ($HaveFake) {
        Reset-Relay; Reset-FakeLog
        $first = New-Request @('status', '/stdout:first'); $p1 = Write-QueuedRequest $first
        Start-Sleep -Milliseconds 1100   # distinct last-write times
        $second = New-Request @('status', '/stdout:second'); $p2 = Write-QueuedRequest $second
        $proc = Start-WorkerChild
        $exited = $proc.WaitForExit(15000)
        $res1 = Get-Content -LiteralPath (Join-Path $Queue "$($first.id).res.json") -Raw | ConvertFrom-Json
        $res2 = Get-Content -LiteralPath (Join-Path $Queue "$($second.id).res.json") -Raw | ConvertFrom-Json
        $log = @(Get-WorkerLog)
        $order = ($log | Where-Object { $_ -match "($($first.id)|$($second.id)) status exit" } | ForEach-Object { if ($_ -match $first.id) { '1' } else { '2' } }) -join ''
        Check 'R22 worker drains two queued requests oldest first, answers both, exits after the linger' `
            ($exited -and ($res1.stdout.Trim() -eq 'first') -and ($res2.stdout.Trim() -eq 'second') -and ($order -eq '12') -and ($log[0] -match 'start worker') -and ($log[-1] -match 'stop: idle')) "exited=$exited order=$order log=[$($log -join ' / ')]"
        Check 'R22b worker.lock is released at exit (a client probe can open it)' (-not (Test-TfRelayWorkerAlive (Get-RelayPaths))) 'lock still held'

        Reset-Relay; Reset-FakeLog
        $req = New-Request @('status', '/sleep:3'); Write-QueuedRequest $req | Out-Null
        $pa = Start-WorkerChild; Start-Sleep -Milliseconds 700; $pb = Start-WorkerChild
        $null = $pa.WaitForExit(20000); $null = $pb.WaitForExit(20000)
        $starts = @(Get-WorkerLog | Where-Object { $_ -match 'start worker' }).Count
        Check 'R23 a second worker started while the first holds the lock exits at once; the request runs exactly once' (($starts -eq 1) -and (@(Get-FakeCalls).Count -eq 1)) "starts=$starts calls=$(@(Get-FakeCalls).Count)"

        Reset-Relay
        New-Item -ItemType Directory -Path $Queue -Force | Out-Null
        $old = Join-Path $Queue 'old.res.json'; Set-Content -LiteralPath $old -Value '{}'; (Get-Item -LiteralPath $old).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-2)
        $oldTmp = Join-Path $Queue 'x.tmp'; Set-Content -LiteralPath $oldTmp -Value 'x'; (Get-Item -LiteralPath $oldTmp).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-2)
        $fresh = Join-Path $Queue 'fresh.res.json'; Set-Content -LiteralPath $fresh -Value '{}'
        $proc = Start-WorkerChild; $null = $proc.WaitForExit(15000)
        Check 'R24 orphans older than an hour are swept at start; fresh files stay' ((-not (Test-Path -LiteralPath $old)) -and (-not (Test-Path -LiteralPath $oldTmp)) -and (Test-Path -LiteralPath $fresh)) "old=$(Test-Path $old) tmp=$(Test-Path $oldTmp) fresh=$(Test-Path $fresh)"

        Reset-Relay; Reset-FakeLog
        New-Item -ItemType Directory -Path $Queue -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Queue 'garbage.txt') -Value 'ignore me'
        [System.IO.File]::WriteAllText((Join-Path $Queue 'bad.req.json'), '{ not json', $Utf8)
        $good = New-Request @('status', '/stdout:good'); Write-QueuedRequest $good | Out-Null
        $proc = Start-WorkerChild; $null = $proc.WaitForExit(15000)
        $resGood = Get-Content -LiteralPath (Join-Path $Queue "$($good.id).res.json") -Raw | ConvertFrom-Json
        Check 'R33 a corrupt .req.json is deleted, a foreign file is ignored, the good request is still served' `
            (($resGood.stdout.Trim() -eq 'good') -and (-not (Test-Path -LiteralPath (Join-Path $Queue 'bad.req.json'))) -and (-not (Test-Path -LiteralPath (Join-Path $Queue 'bad.run.json'))) -and (Test-Path -LiteralPath (Join-Path $Queue 'garbage.txt'))) "good=[$($resGood.stdout)]"
    } else { Skip 'R22/R23/R24/R33 worker loop' 'no fake tf.exe' }
```

- [ ] **Step 2: Run test-relay.ps1 to verify R22–R24 and R33 fail**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-relay.ps1`
Expected: R22, R22b, R23, R24, R33 FAIL (the worker as a script does nothing yet); all earlier checks PASS.

- [ ] **Step 3: Append the loop to Tf-RelayWorker.ps1**

```powershell
function Remove-RelayOrphans {
    # Requests nobody claimed, responses nobody collected, and temp files, older than $RelayOrphanMin minutes.
    $cutoff = [DateTime]::UtcNow.AddMinutes(-$RelayOrphanMin)
    Get-ChildItem -LiteralPath $RelayQueue -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -lt $cutoff -and ($_.Name -match '\.(req|run|res)\.json$' -or $_.Extension -eq '.tmp') } |
        ForEach-Object { Write-RelayLog "sweep $($_.Name)"; Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

function Start-RelayWorker {
    New-Item -ItemType Directory -Path $RelayQueue -Force | Out-Null
    try { $lock = [System.IO.File]::Open($RelayLock, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None) }
    catch { return }   # another worker is alive and will drain the queue
    try {
        # Pin the console to the ANSI code page: a tf.exe that sees our (hidden) console then writes ANSI, and a
        # tf.exe that sees no console writes ANSI anyway, so Invoke-RelayRequest can decode both the same way.
        try { [Console]::OutputEncoding = Get-AnsiEncoding } catch { }
        Write-RelayLog "start worker $WorkerVersion pid $PID linger ${RelayLingerSec}s"
        $born = [DateTime]::UtcNow
        $idleSince = $born
        $lastSweep = [DateTime]::MinValue
        while ($true) {
            $now = [DateTime]::UtcNow
            if (($now - $lastSweep).TotalSeconds -ge 60) { Remove-RelayOrphans; $lastSweep = $now }
            if (($now - $born).TotalMinutes -ge $RelayMaxLifeMin) { Write-RelayLog 'stop: life limit'; break }
            $next = Get-ChildItem -LiteralPath $RelayQueue -Filter '*.req.json' -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTimeUtc, Name | Select-Object -First 1
            if ($next) {
                $runPath = $next.FullName -replace '\.req\.json$', '.run.json'
                try { [System.IO.File]::Move($next.FullName, $runPath) } catch { continue }   # claimed by another instance
                Invoke-RelayRequest -RunPath $runPath
                $idleSince = [DateTime]::UtcNow
                continue
            }
            if (($now - $idleSince).TotalSeconds -ge $RelayLingerSec) { Write-RelayLog 'stop: idle'; break }
            Start-Sleep -Milliseconds 200
        }
    }
    finally { $lock.Close() }
}

if ($MyInvocation.InvocationName -ne '.') { Start-RelayWorker }
```

The lock file is left in place on exit; it only matters whether it can be opened.

- [ ] **Step 4: Run test-relay.ps1 to verify the loop checks pass**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-relay.ps1`
Expected: R22, R22b, R23, R24, R33 PASS, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add plugins/claude-tfvc/skills/tfvc/scripts/Tf-RelayWorker.ps1 tests/test-relay.ps1
git commit -m "Tf-RelayWorker.ps1: single-instance lock, oldest-first loop, orphan sweep, linger and life cap" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: The relay client in Invoke-Tf.ps1

**Files:**
- Modify: `plugins/claude-tfvc/skills/tfvc/scripts/Invoke-Tf.ps1` (replace the `Invoke-TfRelay` stub, add helpers)
- Test: `tests/test-relay.ps1` (insert before `# ---- report`)

**Interfaces:**
- Consumes: Task 3/4 functions; the worker file (Task 5/6) as `Get-TfRelayPaths().Source`.
- Produces: `Install-TfRelayWorker -Paths` → bool (true when it copied); `Start-TfRelayWorker -Paths` → `$null` or error text; `Get-TfRelayTaskInfo` → `[pscustomobject]@{ Registered; State; LastRunTime; LastTaskResult }` or `$null` under a launch seam; `Format-TfTaskState -Info` → string; `Read-TfRelayJson -Path`; real `Invoke-TfRelay -Tf -Arguments -WorkingDirectory -TimeoutSec -PickupTimeoutSec` → result object. `Register-TfRelay.ps1` (Task 9) uses all of these.

- [ ] **Step 1: Add the failing relay checks**

Insert before `# ---- report`:

```powershell
    # ---- relay client (Invoke-Tf.ps1 relay mode through the real command line) --------------------------
    function Note([string]$Name, [bool]$Ok, [string]$Detail) { [void]$Results.Add([pscustomobject]@{ Result = $(if ($Ok) { 'PASS' } else { 'INFO' }); Name = $Name; Detail = $Detail }) }
    $RelayOn = Merge-Env $RelayEnv @{ TFVC_TRANSPORT = 'relay' }
    if ($HaveFake) {
        Reset-Relay
        foreach ($exe in $Exes.Keys) {
            foreach ($code in 0, 1, 100) {
                $r = Invoke-Launcher $exe $RelayOn @('status', 'a b', "/exit:$code", '/stdout:hello out', '/stderr:oops err')
                Check "$exe R2 relay: exit $code passes through, stdout/stderr come back, /noprompt appended" `
                    (($r.Exit -eq $code) -and ($r.Out.Trim() -eq 'hello out') -and ($r.Err.Trim() -eq 'oops err') -and ($r.Calls.Count -eq 1) -and ($r.Calls[0][1] -eq 'a b') -and ($r.Calls[0][-1] -eq '/noprompt')) "exit=$($r.Exit) out=[$($r.Out.Trim())] err=[$($r.Err.Trim())] args=[$($r.Calls[0] -join '|')]"
            }
            $core = @('status', 'with space', 'trail\', 'D:\Projects\X\', $Sample, '%TEMP%', '&|^<>', '-noprompt')
            $r = Invoke-Launcher $exe $RelayOn $core
            $diff = Compare-Args $core $r.Calls[0]
            Check "$exe R3r relay passes spaces, trailing backslashes, Hebrew, Cyrillic, %, & unchanged (and keeps -noprompt as the only noprompt)" ($diff -eq '') $diff

            $r = Invoke-Launcher $exe $RelayOn @('status', '/ansi')
            Check "$exe R4r ANSI tf output reaches the caller as readable UTF-8" ($r.Out.StartsWith($SampleRT)) "out=[$($r.Out.Trim())] want=[$SampleRT]"
        }

        # R5: ten clients at once, one worker, every answer to its own caller
        Reset-Relay; Reset-FakeLog
        $procs = @()
        $saved = Set-TestEnv $RelayOn
        try {
            for ($i = 1; $i -le 10; $i++) {
                $cl = ConvertTo-CommandLine (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $InvokeTf, 'status', "/stdout:marker-$i"))
                $procs += Start-Process -FilePath $Exes.powershell -ArgumentList $cl -RedirectStandardOutput (Join-Path $S "par-$i.out") -NoNewWindow -PassThru
            }
        } finally { Restore-TestEnv $saved }
        foreach ($p in $procs) { $null = $p.WaitForExit(90000) }
        $okAll = $true
        for ($i = 1; $i -le 10; $i++) {
            $txt = (Get-Content -LiteralPath (Join-Path $S "par-$i.out") -Raw -Encoding UTF8).Trim()
            if ($procs[$i - 1].ExitCode -ne 0 -or $txt -ne "marker-$i") { $okAll = $false }
        }
        $calls = @(Get-FakeCalls)
        $distinct = @($calls | ForEach-Object { $_[1] } | Sort-Object -Unique).Count
        Check 'R5 10 parallel clients: each gets its own answer, 10 calls, none lost or duplicated' ($okAll -and ($calls.Count -eq 10) -and ($distinct -eq 10)) "ok=$okAll calls=$($calls.Count) distinct=$distinct"

        # R7: nobody picks the request up -> 124, request deleted, a later worker finds nothing
        Reset-Relay; Reset-FakeLog
        $r = Invoke-InChild 'powershell' (Merge-Env $RelayOn @{ CLAUDE_TFVC_RELAY_LAUNCH = 'noop' }) ". '$InvokeTf'; `$x = Invoke-Tf -Arguments @('checkin','/comment:late') -PickupTimeoutSec 2 -TimeoutSec 10 -Capture; `"`$(`$x.ExitCode)|`$(`$x.Diagnostic)`""
        $left = @(Get-ChildItem -LiteralPath $Queue -Filter '*.json' -ErrorAction SilentlyContinue).Count
        $proc = Start-WorkerChild; $null = $proc.WaitForExit(15000)
        Check 'R7 pickup timeout: exit 124 with the wait and task state, request deleted, never run later' (($r.Out -match '^124\|') -and ($r.Out -match 'relay timeout') -and ($left -eq 0) -and (@(Get-FakeCalls).Count -eq 0)) "out=[$($r.Out)] left=$left calls=$(@(Get-FakeCalls).Count)"

        # R25: the worker drops a claimed request (expired on claim / crashed) -> 124 quickly, not after TimeoutSec
        Reset-Relay
        $dropScript = Join-Path $S 'drop-client.ps1'
        Set-Content -LiteralPath $dropScript -Encoding Ascii -Value @(". '$InvokeTf'", "`$x = Invoke-Tf -Arguments @('status') -PickupTimeoutSec 8 -TimeoutSec 60 -Capture", 'Write-Output $x.ExitCode', 'Write-Output $x.Diagnostic')
        $dropOut = Join-Path $S 'drop.out'
        $saved = Set-TestEnv (Merge-Env $RelayOn @{ CLAUDE_TFVC_RELAY_LAUNCH = 'noop' })
        try { $dp = Start-Process -FilePath $Exes.powershell -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$dropScript`"" -RedirectStandardOutput $dropOut -NoNewWindow -PassThru } finally { Restore-TestEnv $saved }
        $sw = [System.Diagnostics.Stopwatch]::StartNew(); $reqFile = $null
        while ($sw.Elapsed.TotalSeconds -lt 6 -and -not $reqFile) { $reqFile = Get-ChildItem -LiteralPath $Queue -Filter '*.req.json' -ErrorAction SilentlyContinue | Select-Object -First 1; Start-Sleep -Milliseconds 100 }
        if ($reqFile) { $runFile = $reqFile.FullName -replace '\.req\.json$', '.run.json'; Move-Item -LiteralPath $reqFile.FullName -Destination $runFile; Start-Sleep -Milliseconds 400; Remove-Item -LiteralPath $runFile -Force }
        $null = $dp.WaitForExit(20000); $sw.Stop()
        $lines = @(Get-Content -LiteralPath $dropOut)
        Check 'R25 a claimed request that disappears without a response -> 124 "dropped" within seconds' (($lines[0] -eq '124') -and ($lines[1] -match 'dropped') -and ($sw.Elapsed.TotalSeconds -lt 15)) "lines=[$($lines -join ' / ')] secs=$([int]$sw.Elapsed.TotalSeconds)"

        # R39: tf outlives TimeoutSec -> 124 now, the answer still lands later (tf was not aborted)
        Reset-Relay; Wait-NoWorker
        $r = Invoke-Launcher 'powershell' (Merge-Env $RelayOn @{ TFVC_RELAY_TIMEOUT = '2' }) @('get', '/sleep:4', '/stdout:late')
        Start-Sleep -Seconds 6   # the fake sleeps 4 s from its (later) start; give the worker time to write the answer
        $late = @(Get-ChildItem -LiteralPath $Queue -Filter '*.res.json' -ErrorAction SilentlyContinue).Count
        Check 'R39 TFVC_RELAY_TIMEOUT: 124 with "still running" while tf finishes in the worker and its response is left for the sweep' (($r.Exit -eq 124) -and ($r.Err -match 'still running') -and ($late -eq 1)) "exit=$($r.Exit) err=[$($r.Err.Trim())] late=$late"

        # R16: worker copy refreshed from the plugin when the hash differs, installed when missing
        Reset-Relay; Wait-NoWorker
        New-Item -ItemType Directory -Path $Queue -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Relay 'Tf-RelayWorker.ps1') -Value '# stale worker'
        Set-Content -LiteralPath (Join-Path $Relay 'worker.version') -Value @('version=0.0.0', 'sha256=DEADBEEF')
        $r = Invoke-Launcher 'powershell' $RelayOn @('status', '/stdout:refreshed')
        $srcHash = (Get-FileHash -LiteralPath $Worker -Algorithm SHA256).Hash
        $sameText = (Get-Content -LiteralPath (Join-Path $Relay 'Tf-RelayWorker.ps1') -Raw) -eq (Get-Content -LiteralPath $Worker -Raw)
        $verText = Get-Content -LiteralPath (Join-Path $Relay 'worker.version') -Raw
        Check 'R16a stale worker copy is replaced before the request and worker.version records the new hash' (($r.Exit -eq 0) -and ($r.Out.Trim() -eq 'refreshed') -and $sameText -and ($verText -match "sha256=$srcHash") -and ($verText -match 'version=\d')) "exit=$($r.Exit) same=$sameText ver=[$($verText.Trim())]"
        Reset-Relay; Wait-NoWorker
        $r = Invoke-Launcher 'powershell' $RelayOn @('status', '/stdout:fresh')
        Check 'R16b relay folder absent -> created, worker installed, request served' (($r.Exit -eq 0) -and ($r.Out.Trim() -eq 'fresh') -and (Test-Path -LiteralPath (Join-Path $Relay 'Tf-RelayWorker.ps1'))) "exit=$($r.Exit) out=[$($r.Out.Trim())]"

        # R26: relay forced, task missing -> 120 with the registration command
        $r = Invoke-Launcher 'powershell' (Merge-Env $RelayOn @{ CLAUDE_TFVC_RELAY_LAUNCH = 'none' }) @('status')
        Check 'R26 TFVC_TRANSPORT=relay without the task -> exit 120 and the exact registration command on stderr' (($r.Exit -eq 120) -and ($r.Err -match 'not registered') -and ($r.Err -match 'Register-TfRelay\.ps1') -and ($r.Calls.Count -eq 0)) "exit=$($r.Exit) err=[$($r.Err.Trim())]"

        # R12c: the worker's refusal reaches the caller as 120
        Reset-Relay; Wait-NoWorker
        $r = Invoke-Launcher 'powershell' (Merge-Env $RelayOn @{ CLAUDE_TFVC_RELAY_ALLOW_UNSIGNED = $null }) @('status')
        Check 'R12c unsigned tf.exe refused by the worker -> exit 120 with the reason, tf not run' (($r.Exit -eq 120) -and ($r.Err -match 'not a Microsoft-signed') -and ($r.Calls.Count -eq 0)) "exit=$($r.Exit) err=[$($r.Err.Trim())]"
        Wait-NoWorker
    } else { Skip 'R2/R3r/R4r/R5/R7/R12c/R16/R25/R26/R39 relay client' 'no fake tf.exe' }

    # ---- R3b Git Bash -> powershell -File -> launcher ---------------------------------------------------
    if ($Bash -and $HaveFake) {
        function Invoke-ViaBash([hashtable]$EnvVars, [string[]]$TfArgs) {
            Reset-FakeLog
            $saved = Set-TestEnv $EnvVars
            try {
                $q = ($TfArgs | ForEach-Object { "'" + $_.Replace("'", "'\''") + "'" }) -join ' '
                $cmd = "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '$($InvokeTf.Replace('\', '/'))' $q"
                $null = & $Bash -c $cmd 2>&1
                return @{ Exit = $LASTEXITCODE; Calls = @(Get-FakeCalls) }
            } finally { Restore-TestEnv $saved }
        }
        $bashCore = @('status', 'with space', 'trail\', $Sample, '%TEMP%', '&|^<>', '-noprompt')
        foreach ($mode in 'direct', 'relay') {
            $envVars = if ($mode -eq 'direct') { $DirectEnv } else { $RelayOn }
            $r = Invoke-ViaBash $envVars $bashCore
            $diff = Compare-Args $bashCore $r.Calls[0]
            Check "R3b Git Bash -> powershell -File -> $mode: spaces, trailing backslash, Hebrew, Cyrillic, %, & unchanged" ($diff -eq '') $diff
        }
        Wait-NoWorker
        $r = Invoke-ViaBash $DirectEnv @('status', '/noprompt')
        Note 'R3c Git Bash leaves /noprompt alone (INFO when it becomes a path: then SKILL.md recommends -option from Bash, Task 10)' (($r.Calls.Count -eq 1) -and ($r.Calls[0][1] -eq '/noprompt')) "got=[$($r.Calls[0] -join '|')]"
    } else { Skip 'R3b/R3c Git Bash' 'Git Bash or fake tf.exe missing' }
```

- [ ] **Step 2: Run test-relay.ps1 to verify the relay checks fail**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-relay.ps1`
Expected: R2, R3r, R4r, R5, R7, R25, R39, R16a–b, R26, R12c, R3b FAIL (the stub returns 120); earlier checks PASS.

- [ ] **Step 3: Replace the `Invoke-TfRelay` stub in Invoke-Tf.ps1 with the client**

Delete the stub function and insert, in its place:

```powershell
function Install-TfRelayWorker {
    # Installs or refreshes the single-file worker copy the scheduled task runs. SHA-256 of the plugin's copy
    # versus worker.version decides (not the version number, so development iterations refresh too).
    param($Paths)
    New-Item -ItemType Directory -Path $Paths.Queue -Force | Out-Null
    $hash = (Get-FileHash -LiteralPath $Paths.Source -Algorithm SHA256 -ErrorAction Stop).Hash
    $installed = ''
    if (Test-Path -LiteralPath $Paths.Version -PathType Leaf) {
        $m = [regex]::Match((Get-Content -LiteralPath $Paths.Version -Raw), '(?m)^sha256=(\w+)')
        if ($m.Success) { $installed = $m.Groups[1].Value }
    }
    if ($installed -eq $hash -and (Test-Path -LiteralPath $Paths.Worker -PathType Leaf)) { return $false }
    $tmp = "$($Paths.Worker).$([guid]::NewGuid().ToString('n')).tmp"
    Copy-Item -LiteralPath $Paths.Source -Destination $tmp -ErrorAction Stop
    Move-Item -LiteralPath $tmp -Destination $Paths.Worker -Force -ErrorAction Stop
    Set-Content -LiteralPath $Paths.Version -Value @("version=$(Get-TfPluginVersion)", "sha256=$hash") -Encoding Ascii
    return $true
}

function Start-TfRelayWorker {
    # Kicks the worker: the scheduled task, or under the test seams a child powershell.exe / nothing.
    # Returns $null on success, otherwise the text to show the user.
    param($Paths)
    switch ($env:CLAUDE_TFVC_RELAY_LAUNCH) {
        'child' {
            Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$($Paths.Worker)`"" | Out-Null
            return $null
        }
        'noop' { return $null }
        'none' { return (Get-TfRegistrationHint) }
    }
    try { Start-ScheduledTask -TaskName $TfvcRelayTask -ErrorAction Stop; return $null }
    catch {
        if (-not (Test-TfRelayTaskRegistered)) { return (Get-TfRegistrationHint) }
        return "Start-ScheduledTask $TfvcRelayTask failed: $($_.Exception.Message)"
    }
}

function Get-TfRelayTaskInfo {
    # State and last result of the task; $null under a test seam (no scheduler involved).
    if ($env:CLAUDE_TFVC_RELAY_LAUNCH) { return $null }
    try {
        $task = Get-ScheduledTask -TaskName $TfvcRelayTask -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskName $TfvcRelayTask -ErrorAction Stop
        return [pscustomobject]@{ Registered = $true; State = "$($task.State)"; LastRunTime = $info.LastRunTime; LastTaskResult = [int64]$info.LastTaskResult }
    } catch { return [pscustomobject]@{ Registered = $false; State = 'not registered'; LastRunTime = $null; LastTaskResult = [int64]0 } }
}

function Format-TfTaskState {
    param($Info)
    if (-not $Info) { return 'task state unknown (CLAUDE_TFVC_RELAY_LAUNCH test mode)' }
    if (-not $Info.Registered) { return 'task not registered' }
    $text = "task state $($Info.State), last result 0x$('{0:X8}' -f $Info.LastTaskResult)"
    $why = ConvertTo-TfRelayFailureText $Info.LastTaskResult
    if ($why) { $text += " ($why)" }
    return $text
}

function Read-TfRelayJson {
    # The worker renames complete files into place, but a reader can still race the rename on some filesystems.
    param([string]$Path)
    for ($i = 0; $i -lt 10; $i++) {
        try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) }
        catch { Start-Sleep -Milliseconds 50 }
    }
    return $null
}

function Invoke-TfRelay {
    # Writes <id>.req.json, wakes the worker, waits for <id>.res.json. See the design doc, section 8.
    param([string]$Tf, [string[]]$Arguments, [string]$WorkingDirectory, [int]$TimeoutSec = 600, [int]$PickupTimeoutSec = 30)
    $paths = Get-TfRelayPaths
    try { Install-TfRelayWorker -Paths $paths | Out-Null }
    catch { return New-TfResult -ExitCode 120 -Transport 'relay' -Diagnostic "claude-tfvc: cannot install the relay worker under $($paths.Root): $($_.Exception.Message)" }
    $id = [guid]::NewGuid().ToString('n')
    $reqPath = Join-Path $paths.Queue "$id.req.json"
    $runPath = Join-Path $paths.Queue "$id.run.json"
    $resPath = Join-Path $paths.Queue "$id.res.json"
    $now = [DateTime]::UtcNow
    $request = [ordered]@{ protocol = $TfvcRelayProtocol; id = $id; tf = $Tf; args = @($Arguments); cwd = $WorkingDirectory; createdUtc = $now.ToString('o'); expiresUtc = $now.AddSeconds($PickupTimeoutSec).ToString('o') }
    $tmp = "$reqPath.tmp"
    [System.IO.File]::WriteAllText($tmp, ($request | ConvertTo-Json -Depth 4 -Compress), (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $reqPath -Force

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastKick = $null; $firstKick = $null
    $claimed = $false; $goneSince = $null
    while ($true) {
        if (Test-Path -LiteralPath $resPath) {
            $res = Read-TfRelayJson $resPath
            if ($res) {
                Remove-Item -LiteralPath $resPath -Force -ErrorAction SilentlyContinue
                if ($res.error) { return New-TfResult -ExitCode 120 -Transport 'relay' -StdOut "$($res.stdout)" -StdErr "$($res.stderr)" -Diagnostic "claude-tfvc: relay worker $($res.workerVersion): $($res.error)" }
                return New-TfResult -ExitCode ([int]$res.exitCode) -StdOut "$($res.stdout)" -StdErr "$($res.stderr)" -Transport 'relay'
            }
        }
        if (-not $claimed) {
            if (-not (Test-Path -LiteralPath $reqPath)) { $claimed = $true; continue }
            $alive = Test-TfRelayWorkerAlive $paths
            if (-not $alive -and ($null -eq $lastKick -or ($watch.Elapsed - $lastKick).TotalSeconds -ge 2)) {
                $kickError = Start-TfRelayWorker -Paths $paths     # also closes the lost-wakeup gap on re-kicks
                $lastKick = $watch.Elapsed
                if ($null -eq $firstKick) { $firstKick = $lastKick }
                if ($kickError) {
                    Remove-Item -LiteralPath $reqPath -Force -ErrorAction SilentlyContinue
                    return New-TfResult -ExitCode 120 -Transport 'relay' -Diagnostic "claude-tfvc: $kickError"
                }
            }
            if (-not $alive -and $null -ne $firstKick -and ($watch.Elapsed - $firstKick).TotalSeconds -ge 5) {
                $info = Get-TfRelayTaskInfo
                if ($info -and $info.Registered -and $info.State -ne 'Running' -and (ConvertTo-TfRelayFailureText $info.LastTaskResult)) {
                    Remove-Item -LiteralPath $reqPath -Force -ErrorAction SilentlyContinue
                    return New-TfResult -ExitCode 120 -Transport 'relay' -Diagnostic "claude-tfvc: $(Format-TfTaskState $info)"
                }
            }
            if ($watch.Elapsed.TotalSeconds -ge $PickupTimeoutSec) {
                Remove-Item -LiteralPath $reqPath -Force -ErrorAction SilentlyContinue
                if (-not (Test-Path -LiteralPath $runPath) -and -not (Test-Path -LiteralPath $resPath)) {
                    $workerNote = if (Test-TfRelayWorkerAlive $paths) { 'a worker is running but did not pick the request up (see worker.log in the relay folder)' } else { 'no worker started' }
                    return New-TfResult -ExitCode 124 -Transport 'relay' -Diagnostic "claude-tfvc: relay timeout: waited $PickupTimeoutSec s for pickup; $workerNote; $(Format-TfTaskState (Get-TfRelayTaskInfo))"
                }
                $claimed = $true   # the worker renamed it in that instant
            }
        }
        else {
            if (-not (Test-Path -LiteralPath $runPath) -and -not (Test-Path -LiteralPath $resPath)) {
                if ($null -eq $goneSince) { $goneSince = $watch.Elapsed }
                elseif (($watch.Elapsed - $goneSince).TotalMilliseconds -ge 500) {
                    return New-TfResult -ExitCode 124 -Transport 'relay' -Diagnostic 'claude-tfvc: the relay worker dropped the request (it expired before pickup, or the worker stopped); tf did not run'
                }
            } else { $goneSince = $null }
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSec) {
                return New-TfResult -ExitCode 124 -Transport 'relay' -Diagnostic "claude-tfvc: relay timeout: tf is still running in the interactive session after $TimeoutSec s; it will finish there, this call gives up"
            }
        }
        Start-Sleep -Milliseconds 150
    }
}
```

- [ ] **Step 4: Run test-relay.ps1 to verify the relay checks pass**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-relay.ps1`
Expected: every R2/R3r/R4r/R5/R7/R25/R39/R16/R26/R12c/R3b check PASS, `0 failed`. R3c is INFO or PASS; write its outcome into `docs/plans/relay-notes.md` (create if missing: one line `Git Bash /option: <converted to a path | left alone>`), Task 10 reads it.

- [ ] **Step 5: Run test-hook.ps1 to confirm nothing regressed**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-hook.ps1`
Expected: `0 failed`.

- [ ] **Step 6: Commit**

```bash
git add plugins/claude-tfvc/skills/tfvc/scripts/Invoke-Tf.ps1 tests/test-relay.ps1 docs/plans/relay-notes.md
git commit -m "Invoke-Tf.ps1: relay client (queue, worker install/refresh, kick, poll, timeouts, failure decoding)" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: The hook runs through the launcher and explains failures

**Files:**
- Modify: `plugins/claude-tfvc/hooks/tfvc-checkout.ps1` (whole file), `plugins/claude-tfvc/hooks/hooks.json:10`
- Test: `tests/test-hook.ps1` (static checks), `tests/test-relay.ps1` (insert before `# ---- report`)

**Interfaces:**
- Consumes: `Invoke-Tf -Arguments -ProjectDir -WorkingDirectory -Capture -PickupTimeoutSec -TimeoutSec` (Task 4/7).
- Produces: on failure, stdout JSON `{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"claude-tfvc: tf checkout of <file> failed (<transport>, exit <n>): <reason>[ hint]"}}`; on success nothing; always exit 0.

- [ ] **Step 1: Add the failing checks**

In `tests/test-hook.ps1`, after the T23 check, add:

```powershell
Check "T24 the hook runs tf through Invoke-Tf.ps1 (no direct tf invocation, no own transport logic)" `
    (($hookText -match 'Invoke-Tf\.ps1') -and ($hookText -match 'Invoke-Tf -Arguments') -and ($hookText -notmatch '&\s*\$tf\b')) "loads launcher=$($hookText -match 'Invoke-Tf\.ps1') calls Invoke-Tf=$($hookText -match 'Invoke-Tf -Arguments')"
$hookTimeout = (Get-Content -LiteralPath $HooksJson -Raw | ConvertFrom-Json).hooks.PreToolUse[0].hooks[0].timeout
Check "T28 hooks.json timeout leaves margin over the hook's 20 s relay budget (>= 45)" ($hookTimeout -ge 45) "timeout=$hookTimeout"
```

In `tests/test-relay.ps1`, insert before `# ---- report`:

```powershell
    # ---- hook in relay mode -----------------------------------------------------------------------------
    function New-TestFile([string]$Path, [bool]$ReadOnly) {
        if (Test-Path -LiteralPath $Path) { (Get-Item -LiteralPath $Path).IsReadOnly = $false }
        Set-Content -LiteralPath $Path -Value 'x'
        (Get-Item -LiteralPath $Path).IsReadOnly = $ReadOnly
    }
    function Invoke-HookCase([string]$Exe, [hashtable]$EnvVars, [string]$Path) {
        Reset-FakeLog
        $payload = @{ tool_input = @{ file_path = $Path }; cwd = $Proj } | ConvertTo-Json -Compress
        $saved = Set-TestEnv $EnvVars
        try { $out = ($payload | & $Exes[$Exe] -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Hook 2>&1 | Out-String).Trim(); $code = $LASTEXITCODE }
        finally { Restore-TestEnv $saved }
        return @{ Exit = $code; Out = $out; Calls = @(Get-FakeCalls) }
    }
    $RoFile  = Join-Path $S 'ro.txt';                                 New-TestFile $RoFile $true
    $RoHeb   = Join-Path $S "ro-$([char]0x5E9)$([char]0x5DC).txt";    New-TestFile $RoHeb $true
    $RwFile  = Join-Path $S 'rw.txt';                                 New-TestFile $RwFile $false
    $HookEnv = Merge-Env $RelayEnv @{ CLAUDE_PROJECT_DIR = $Proj }    # $Proj\.claude\settings.local.json says relay
    if ($HaveFake) {
        foreach ($exe in $Exes.Keys) {
            Reset-Relay; Wait-NoWorker
            $r = Invoke-HookCase $exe $HookEnv $RoFile
            Check "$exe R10 hook, relay mode: read-only file -> 'checkout /noprompt <path>' through the queue, exit 0, silent" `
                (($r.Exit -eq 0) -and ($r.Out -eq '') -and ($r.Calls.Count -eq 1) -and (($r.Calls[0] -join ' ') -eq "checkout /noprompt $RoFile")) "exit=$($r.Exit) out=[$($r.Out)] args=[$($r.Calls[0] -join '|')]"
            New-TestFile $RoFile $true

            $r = Invoke-HookCase $exe (Merge-Env $HookEnv @{ CLAUDE_TFVC_RELAY_LAUNCH = 'none' }) $RoHeb
            $json = $null; try { $json = $r.Out | ConvertFrom-Json } catch { }
            $ctx = if ($json) { "$($json.hookSpecificOutput.additionalContext)" } else { '' }
            Check "$exe R27 hook, relay unavailable: exit 0 and valid additionalContext JSON naming the Hebrew path and the registration command" `
                (($r.Exit -eq 0) -and ($json.hookSpecificOutput.hookEventName -eq 'PreToolUse') -and $ctx.Contains($RoHeb) -and ($ctx -match 'not registered') -and ($ctx -match 'Register-TfRelay\.ps1') -and ($r.Calls.Count -eq 0)) "exit=$($r.Exit) out=[$($r.Out)]"

            $r = Invoke-HookCase $exe (Merge-Env $DirectEnv @{ CLAUDE_PROJECT_DIR = $ProjNone }) $RoFile
            Check "$exe R10b hook, direct mode (local session): tf called directly, exit 0, silent" (($r.Exit -eq 0) -and ($r.Out -eq '') -and ($r.Calls.Count -eq 1)) "exit=$($r.Exit) out=[$($r.Out)]"
            New-TestFile $RoFile $true

            # The hook passes only 'checkout /noprompt <file>', so the fake cannot be told to fail; drive a failure
            # through the transport instead: forced relay with the unsigned bypass removed -> worker refusal -> 120.
            Reset-Relay; Wait-NoWorker
            $r = Invoke-HookCase $exe (Merge-Env $HookEnv @{ CLAUDE_TFVC_RELAY_ALLOW_UNSIGNED = $null }) $RoFile
            $json = $null; try { $json = $r.Out | ConvertFrom-Json } catch { }
            $ctx = if ($json) { "$($json.hookSpecificOutput.additionalContext)" } else { '' }
            Check "$exe R27b hook, worker refusal: exit 0 and additionalContext carries the transport, code 120 and the reason" `
                (($r.Exit -eq 0) -and ($ctx -match 'relay, exit 120') -and ($ctx -match 'not a Microsoft-signed')) "exit=$($r.Exit) out=[$($r.Out)]"
            Wait-NoWorker

            $freshRoot = Join-Path $S "relay-r11-$exe"
            $r = Invoke-HookCase $exe (Merge-Env $HookEnv @{ CLAUDE_TFVC_RELAY_ROOT = $freshRoot }) $RwFile
            Check "$exe R11 hook, writable file: nothing runs, no relay folder appears" (($r.Exit -eq 0) -and ($r.Out -eq '') -and ($r.Calls.Count -eq 0) -and (-not (Test-Path -LiteralPath $freshRoot))) "exit=$($r.Exit) out=[$($r.Out)] folder=$(Test-Path -LiteralPath $freshRoot)"
        }
    } else { Skip 'R10/R11/R27 hook in relay mode' 'no fake tf.exe' }
```

- [ ] **Step 2: Run both harnesses to verify the new checks fail**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-hook.ps1` and `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-relay.ps1`
Expected: T24, T28 FAIL; R10 FAIL (the old hook calls `& $tf` directly, so the fake logs `[5] checkout ...` but no `/noprompt`... it does log it; the FAIL comes from R27/R27b (no JSON) and R10 in relay mode (the old hook never relays, calls are direct, still 1 call): at least R27, R27b, T24, T28 FAIL. Everything else PASS.

- [ ] **Step 3: Rewrite the hook**

Replace the whole of `plugins/claude-tfvc/hooks/tfvc-checkout.ps1` with:

```powershell
# PreToolUse hook for Edit|Write: best-effort "tf checkout" of the target file.
#
# Design goals:
#   * SAFE everywhere - in non-TFVC / git projects this is a near-instant no-op.
#   * NEVER blocks an edit. We always exit 0 (allow). When checkout fails we let the edit proceed and hand
#     Claude the reason as additionalContext (TF30063 -> run /tf-relay; task not started -> log in over RDP).
#   * Only acts when the target file is READ-ONLY, which is TFVC's "not checked out" signal. Normal (writable)
#     files are skipped instantly.
#   * Runs on Windows PowerShell 5.1 (built into every Windows) as well as PowerShell 7.
#     Keep this file pure ASCII: 5.1 reads BOM-less files in the ANSI code page.
#   * tf runs through ..\skills\tfvc\scripts\Invoke-Tf.ps1 (direct or relay transport), which itself loads
#     ..\skills\tfvc\scripts\Find-Tf.ps1, the single tf.exe resolver shared with the skill and /tf-select.
#     Both are loaded only once a read-only file is actually seen, so the common no-op path never pays for them.

$ErrorActionPreference = 'SilentlyContinue'

try {
    # Claude Code writes the payload as UTF-8; read it as such whatever the console code page is.
    $stdin = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
    $payload = $stdin.ReadToEnd() | ConvertFrom-Json
    $file = $payload.tool_input.file_path

    if ($file -and (Test-Path -LiteralPath $file) -and (Get-Item -LiteralPath $file).IsReadOnly) {
        . (Join-Path $PSScriptRoot '..\skills\tfvc\scripts\Invoke-Tf.ps1')

        # Project root: CLAUDE_PROJECT_DIR (exported to hooks), else the payload's cwd, else the current directory.
        $projectDir = $env:CLAUDE_PROJECT_DIR
        if (-not $projectDir) { $projectDir = $payload.cwd }
        if (-not $projectDir) { $projectDir = (Get-Location).Path }

        # /noprompt: fail fast instead of opening a credential dialog behind the terminal.
        # 15 s to be picked up, 20 s in all: well inside the 45 s hook timeout in hooks.json.
        $r = Invoke-Tf -Arguments @('checkout', '/noprompt', $file) -ProjectDir $projectDir -WorkingDirectory $projectDir -Capture -PickupTimeoutSec 15 -TimeoutSec 20
        if ($r.ExitCode -ne 0) {
            $why = ((@($r.Diagnostic, $r.StdErr, $r.StdOut) | Where-Object { "$_".Trim() }) -join ' ') -replace '\s+', ' '
            if ($why.Length -gt 600) { $why = $why.Substring(0, 600) + '...' }
            $msg = "claude-tfvc: tf checkout of $file failed ($($r.Transport), exit $($r.ExitCode)): $why"
            if ($why -match 'TF30063' -and $why -notmatch '/tf-relay') {
                $msg += ' This session has no network credentials; run /tf-relay to route tf through your interactive Windows session.'
            }
            # Documented PreToolUse output: additionalContext reaches the model next to the tool result.
            $json = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; additionalContext = $msg } } | ConvertTo-Json -Compress
            $out = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), (New-Object System.Text.UTF8Encoding $false))
            $out.Write($json); $out.Flush()
        }
    }
}
catch {
    # Swallow everything - the hook must never break editing.
}

exit 0
```

In `hooks/hooks.json` change `"timeout": 30` to `"timeout": 45`.

- [ ] **Step 4: Run both harnesses**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-hook.ps1` then `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-relay.ps1`
Expected: every existing test-hook check PASS plus T24/T28; R10, R10b, R11, R27, R27b PASS; `0 failed` in both.

- [ ] **Step 5: Commit**

```bash
git add plugins/claude-tfvc/hooks/tfvc-checkout.ps1 plugins/claude-tfvc/hooks/hooks.json tests/test-hook.ps1 tests/test-relay.ps1
git commit -m "hook: check out through Invoke-Tf.ps1 (direct or relay) and report failures via additionalContext" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Register-TfRelay.ps1 (register, unregister, status)

**Files:**
- Create: `plugins/claude-tfvc/skills/tfvc/scripts/Register-TfRelay.ps1`
- Test: `tests/test-relay.ps1` (insert before `# ---- report`), `tests/test-hook.ps1` (T10 list)

**Interfaces:**
- Consumes: from `Invoke-Tf.ps1`: `$TfvcRelayTask`, `$TfvcScriptsDir`, `Get-TfRelayPaths`, `Install-TfRelayWorker`, `Test-TfRelayWorkerAlive`, `Test-TfRelayTaskRegistered`, `Get-TfRelayTaskInfo`, `Format-TfTaskState`, `Test-TfRemoteSession`, `Resolve-TfTransport`, `Resolve-TfExe`, `Invoke-TfRelay`, `Get-TfPluginVersion`.
- Produces: script modes `Register-TfRelay.ps1` (register + smoke test), `-Unregister`, `-Status [-NoProbe]`; dot-sourceable `Get-TfRelayTaskSpec -WorkerPath` → `[pscustomobject]@{ TaskName; Execute; Argument; WorkingDirectory; UserId; LogonType; RunLevel; MultipleInstances; ExecutionTimeLimit; AllowStartIfOnBatteries; DontStopIfGoingOnBatteries; Triggers }`, `Get-TfRelayStatusReport -Paths [-NoProbe]` → `[pscustomobject]@{ Ok; Lines }`. `/tf-relay` (Task 10) runs `-Status` and the default mode.

- [ ] **Step 1: Add the failing checks**

In `tests/test-hook.ps1` add after the `$FindTf = ...` line near the top:

```powershell
$InvokeTf  = Join-Path $Plugin 'skills\tfvc\scripts\Invoke-Tf.ps1'
$Worker    = Join-Path $Plugin 'skills\tfvc\scripts\Tf-RelayWorker.ps1'
$Register  = Join-Path $Plugin 'skills\tfvc\scripts\Register-TfRelay.ps1'
```

and change the T10 loop header `foreach ($f in @($Hook, $FindTf)) {` to `foreach ($f in @($Hook, $FindTf, $InvokeTf, $Worker, $Register)) {`.

In `tests/test-relay.ps1`, insert before `# ---- report`:

```powershell
    # ---- Register-TfRelay.ps1: -Status under the seams, the task spec, decoded failure codes ---------------
    $StatusEnv = Merge-Env $RelayOn @{ CLAUDE_PROJECT_DIR = $ProjNone }
    if ($HaveFake) {
        Reset-Relay; Wait-NoWorker
        $r = Invoke-InChild 'powershell' $StatusEnv "& '$Register' -Status -NoProbe; exit `$LASTEXITCODE"
        Check 'R17a -Status with the task (simulated) and no probe -> exit 0, reports transport and task' (($r.Exit -eq 0) -and ($r.Out -match '(?m)^Transport:\s+relay') -and ($r.Out -match 'simulated')) "exit=$($r.Exit) out=[$($r.Out)]"

        $r = Invoke-InChild 'powershell' (Merge-Env $StatusEnv @{ CLAUDE_TFVC_RELAY_LAUNCH = 'none' }) "& '$Register' -Status -NoProbe; exit `$LASTEXITCODE"
        Check 'R17b -Status without the task -> exit 1, NOT registered, the exact registration command, the RDP note' (($r.Exit -eq 1) -and ($r.Out -match 'NOT registered') -and ($r.Out -match 'Register-TfRelay\.ps1') -and ($r.Out -match 'interactive Windows session')) "exit=$($r.Exit) out=[$($r.Out)]"

        Reset-FakeLog
        $r = Invoke-InChild 'powershell' $StatusEnv "& '$Register' -Status; exit `$LASTEXITCODE"
        $calls = @(Get-FakeCalls)
        Check 'R17c -Status probes tf workspaces /noprompt through the relay and reports the time' (($r.Exit -eq 0) -and ($r.Out -match 'Probe:\s+tf workspaces /noprompt via relay: exit 0 in [\d.]+ s') -and ($calls.Count -eq 1) -and ($calls[0][0] -eq 'workspaces')) "exit=$($r.Exit) out=[$($r.Out)] calls=$($calls.Count)"
        Wait-NoWorker
    } else { Skip 'R17 Register-TfRelay.ps1 -Status' 'no fake tf.exe' }

    $r = Invoke-InChild 'powershell' @{} ". '$Register'; `$s = Get-TfRelayTaskSpec -WorkerPath 'C:\x\w.ps1'; `"`$(`$s.TaskName)|`$(`$s.Execute)|`$(`$s.Argument)|`$(`$s.LogonType)|`$(`$s.RunLevel)|`$(`$s.MultipleInstances)|`$(`$s.ExecutionTimeLimit.TotalHours)|`$(@(`$s.Triggers).Count)|`$(`$s.WorkingDirectory)|`$(`$s.AllowStartIfOnBatteries)|`$(`$s.DontStopIfGoingOnBatteries)`""
    $want = 'ClaudeTfvcRelay|powershell.exe|-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\x\w.ps1"|Interactive|Limited|IgnoreNew|1|0|C:\x|True|True'
    Check 'R18 task spec: name, hidden non-interactive powershell action, Interactive/Limited, IgnoreNew, 1 h, no triggers, battery OK' ($r.Out -eq $want) "got=[$($r.Out)]"

    $r = Invoke-InChild 'powershell' @{} ". '$InvokeTf'; (ConvertTo-TfRelayFailureText 0x00041303) -match 'RDP'; (ConvertTo-TfRelayFailureText 0x8007052E) -match 'ogon'; (ConvertTo-TfRelayFailureText 0x80070569) -match 'policy'; (ConvertTo-TfRelayFailureText 0x800710E0) -match 'refused'; `$null -eq (ConvertTo-TfRelayFailureText 0)"
    Check 'R19 LastTaskResult codes 0x41303 / 0x8007052E / 0x80070569 / 0x800710E0 decode to actionable text; 0 decodes to nothing' ((($r.Out -replace '\s', '') -eq 'TrueTrueTrueTrueTrue')) "out=[$($r.Out)]"
```

- [ ] **Step 2: Run both harnesses to verify the new checks fail**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-hook.ps1` and `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-relay.ps1`
Expected: T10 for `Register-TfRelay.ps1` FAIL (missing), R17a–c and R18 FAIL; R19 PASS already (Task 3); everything else PASS.

- [ ] **Step 3: Create Register-TfRelay.ps1**

```powershell
<#
.SYNOPSIS
  Registers (default), removes (-Unregister) or reports on (-Status) the claude-tfvc relay: the scheduled task
  ClaudeTfvcRelay that runs Tf-RelayWorker.ps1 in your interactive Windows session.

.DESCRIPTION
  Run once, from any session of the user who will use the relay (an SSH session is fine; /tf-relay offers it):
    powershell -NoProfile -ExecutionPolicy Bypass -File Register-TfRelay.ps1
  The task runs as you: LogonType Interactive, RunLevel Limited, no stored password, no triggers (on demand only),
  one instance at a time, 1 hour limit. Its action points at the worker copy under %LOCALAPPDATA%\claude-tfvc\relay,
  which Invoke-Tf.ps1 keeps current, so plugin updates never need re-registration. The task can only start while
  you have an interactive session (console or RDP; disconnected is fine); after a reboot or sign-out, log in once.
  -Status prints a plain-text report and exits 0 when the relay is usable, 1 otherwise; it includes a timed probe
  (tf workspaces /noprompt through the relay) unless -NoProbe. -Unregister removes the task and the relay folder.
  Dot-sourcing (". Register-TfRelay.ps1") only defines the functions. Windows PowerShell 5.1; keep this file ASCII.
#>
param([switch]$Unregister, [switch]$Status, [switch]$NoProbe)
. (Join-Path $PSScriptRoot 'Invoke-Tf.ps1')

function Get-TfRelayTaskSpec {
    # Everything the task is made of, in one place (tested without touching the scheduler).
    param([string]$WorkerPath)
    [pscustomobject]@{
        TaskName                   = $TfvcRelayTask
        Execute                    = 'powershell.exe'
        Argument                   = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WorkerPath`""
        WorkingDirectory           = Split-Path -Parent $WorkerPath
        UserId                     = "$env:USERDOMAIN\$env:USERNAME"
        LogonType                  = 'Interactive'
        RunLevel                   = 'Limited'
        MultipleInstances          = 'IgnoreNew'
        ExecutionTimeLimit         = [TimeSpan]::FromHours(1)
        AllowStartIfOnBatteries    = $true
        DontStopIfGoingOnBatteries = $true
        Triggers                   = @()
    }
}

function Register-TfRelayTask {
    param($Paths)
    $spec      = Get-TfRelayTaskSpec -WorkerPath $Paths.Worker
    $action    = New-ScheduledTaskAction -Execute $spec.Execute -Argument $spec.Argument -WorkingDirectory $spec.WorkingDirectory
    $principal = New-ScheduledTaskPrincipal -UserId $spec.UserId -LogonType $spec.LogonType -RunLevel $spec.RunLevel
    $settings  = New-ScheduledTaskSettingsSet -MultipleInstances $spec.MultipleInstances -ExecutionTimeLimit $spec.ExecutionTimeLimit -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $spec.TaskName -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
}

function Test-TfRelaySmoke {
    # Starts the task once and waits up to 5 s for the worker to take its lock.
    param($Paths)
    Start-ScheduledTask -TaskName $TfvcRelayTask -ErrorAction Stop
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline) { if (Test-TfRelayWorkerAlive $Paths) { return $true }; Start-Sleep -Milliseconds 200 }
    return (Test-TfRelayWorkerAlive $Paths)
}

function Get-TfRelayStatusReport {
    param($Paths, [switch]$NoProbe)
    $lines = New-Object System.Collections.ArrayList
    $ok = $true
    $remote = Test-TfRemoteSession
    $choice = Resolve-TfTransport -ProjectDir $env:CLAUDE_PROJECT_DIR
    $info = Get-TfRelayTaskInfo
    $registered = if ($info) { $info.Registered } else { Test-TfRelayTaskRegistered }
    [void]$lines.Add("Session:    " + $(if ($remote) { 'remote (SSH_CONNECTION/SSH_CLIENT set)' } else { 'local (no SSH variables)' }))
    [void]$lines.Add("Transport:  $($choice.Transport)  (TFVC_TRANSPORT=$($choice.Setting) from $($choice.Source))")
    if ($info) {
        if ($info.Registered) { [void]$lines.Add("Task:       registered; $(Format-TfTaskState $info); last run $($info.LastRunTime)") }
        else { [void]$lines.Add('Task:       NOT registered'); $ok = $false }
    } else {
        [void]$lines.Add("Task:       simulated by CLAUDE_TFVC_RELAY_LAUNCH=$env:CLAUDE_TFVC_RELAY_LAUNCH (registered: $registered)")
        if (-not $registered) { $ok = $false }
    }
    if (Test-Path -LiteralPath $Paths.Worker -PathType Leaf) {
        $verText = if (Test-Path -LiteralPath $Paths.Version) { Get-Content -LiteralPath $Paths.Version -Raw } else { '' }
        $ver = [regex]::Match($verText, '(?m)^version=(.+)$').Groups[1].Value.Trim()
        $sha = [regex]::Match($verText, '(?m)^sha256=(\w+)').Groups[1].Value
        $same = ($sha -eq (Get-FileHash -LiteralPath $Paths.Source -Algorithm SHA256).Hash)
        [void]$lines.Add("Worker:     installed $ver " + $(if ($same) { '(matches the plugin)' } else { "(plugin is $(Get-TfPluginVersion); refreshed on the next call)" }))
    } else { [void]$lines.Add('Worker:     not installed yet (installed on the first relay call)') }
    $counts = foreach ($kind in 'req', 'run', 'res') { @(Get-ChildItem -LiteralPath $Paths.Queue -Filter "*.$kind.json" -ErrorAction SilentlyContinue).Count }
    [void]$lines.Add("Queue:      $($Paths.Queue)  ($($counts[0]) waiting, $($counts[1]) running, $($counts[2]) answered)")
    [void]$lines.Add("Alive:      " + $(if (Test-TfRelayWorkerAlive $Paths) { 'a worker is running now' } else { 'no worker running now (started on demand)' }))
    if ($NoProbe) { [void]$lines.Add('Probe:      skipped (-NoProbe)') }
    elseif (-not $registered) { [void]$lines.Add('Probe:      skipped (relay not available)') }
    else {
        $tf = Resolve-TfExe -ProjectDir $env:CLAUDE_PROJECT_DIR
        if (-not $tf) { [void]$lines.Add('Probe:      skipped (no tf.exe found; run /tf-select)'); $ok = $false }
        else {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-TfRelay -Tf $tf -Arguments @('workspaces', '/noprompt') -WorkingDirectory (Get-Location).Path -TimeoutSec 60 -PickupTimeoutSec 15
            $watch.Stop()
            $line = "Probe:      tf workspaces /noprompt via relay: exit $($r.ExitCode) in $([math]::Round($watch.Elapsed.TotalSeconds, 1)) s"
            if ($r.Diagnostic) { $line += "; $($r.Diagnostic)" }
            [void]$lines.Add($line)
            if ($r.ExitCode -in 120, 124) { $ok = $false }
        }
    }
    if (-not $registered) {
        [void]$lines.Add('')
        [void]$lines.Add('Register the relay task once (any session of this user):')
        [void]$lines.Add("  powershell -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $TfvcScriptsDir 'Register-TfRelay.ps1')`"")
        [void]$lines.Add('The worker needs an interactive Windows session (console or RDP; a disconnected RDP session is fine).')
    }
    [pscustomobject]@{ Ok = $ok; Lines = @($lines) }
}

if ($MyInvocation.InvocationName -eq '.') { return }
$ErrorActionPreference = 'Stop'
$paths = Get-TfRelayPaths

if ($Status) {
    $report = Get-TfRelayStatusReport -Paths $paths -NoProbe:$NoProbe
    $report.Lines | ForEach-Object { Write-Output $_ }
    if ($report.Ok) { exit 0 } else { exit 1 }
}

if ($Unregister) {
    try { Unregister-ScheduledTask -TaskName $TfvcRelayTask -Confirm:$false -ErrorAction Stop; Write-Output "Removed scheduled task $TfvcRelayTask." }
    catch { Write-Output "Scheduled task $TfvcRelayTask was not registered." }
    $deadline = (Get-Date).AddSeconds(20)
    while ((Test-TfRelayWorkerAlive $paths) -and ((Get-Date) -lt $deadline)) { Start-Sleep -Milliseconds 500 }
    if (Test-Path -LiteralPath $paths.Root) {
        try { Remove-Item -LiteralPath $paths.Root -Recurse -Force -ErrorAction Stop; Write-Output "Removed $($paths.Root)." }
        catch { Write-Output "Could not remove $($paths.Root) (a worker may still be running): $($_.Exception.Message)" }
    }
    exit 0
}

try {
    New-Item -ItemType Directory -Path $paths.Queue -Force | Out-Null
    Install-TfRelayWorker -Paths $paths | Out-Null
    Register-TfRelayTask -Paths $paths
    Write-Output "Registered scheduled task $TfvcRelayTask for $env:USERDOMAIN\$env:USERNAME (LogonType Interactive, RunLevel Limited, no stored password)."
    Write-Output "Worker installed at $($paths.Worker) (plugin version $(Get-TfPluginVersion))."
    if (Test-TfRelaySmoke -Paths $paths) {
        Write-Output 'Smoke test: the worker started in your interactive session. Run /tf-relay inside a project to try it.'
        exit 0
    }
    Write-Output "Smoke test: the worker did not start within 5 s: $(Format-TfTaskState (Get-TfRelayTaskInfo))"
    exit 1
}
catch {
    Write-Output "Registration failed: $($_.Exception.Message)"
    Write-Output 'If this session cannot register tasks, run the same command from an RDP or console session of this user.'
    exit 1
}
```

- [ ] **Step 4: Run both harnesses**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-hook.ps1` and `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-relay.ps1`
Expected: T10 PASS for all five files; R17a–c, R18, R19 PASS; `0 failed` in both.

- [ ] **Step 5: Real registration on this machine (manual, records the answer to design item 19.1)**

From the current Claude Code session (console or SSH, whichever it is), run:

```
powershell -NoProfile -ExecutionPolicy Bypass -File plugins\claude-tfvc\skills\tfvc\scripts\Register-TfRelay.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File plugins\claude-tfvc\skills\tfvc\scripts\Register-TfRelay.ps1 -Status
```

Expected: "Registered scheduled task ClaudeTfvcRelay ...", "Smoke test: the worker started ...", then a status report with `Task: registered; task state Ready ...` and `Probe: ... exit 0 in <n> s` (the real `TF.exe` runs `tf workspaces /noprompt` in the interactive session; from a plain console session this works too). Append to `docs/plans/relay-notes.md` one line: `Registration from <console|SSH> session: <worked | failed: message>`. Leave the task registered; the acceptance checklist (Task 12) uses it.

- [ ] **Step 6: Commit**

```bash
git add plugins/claude-tfvc/skills/tfvc/scripts/Register-TfRelay.ps1 tests/test-relay.ps1 tests/test-hook.ps1 docs/plans/relay-notes.md
git commit -m "Register-TfRelay.ps1: register / -Unregister / -Status with probe and decoded task results" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: `/tf-relay` command, SKILL.md "Running tf", command wording

**Files:**
- Create: `plugins/claude-tfvc/commands/tf-relay.md`
- Modify: `plugins/claude-tfvc/skills/tfvc/SKILL.md` (frontmatter `description`, section "Finding tf.exe" → "Running tf", mistakes table), `plugins/claude-tfvc/commands/tf-status.md`, `tf-checkout.md`, `tf-checkin.md`, `tf-get.md`, `tf-undo.md`
- Test: `tests/test-relay.ps1` (insert before `# ---- report`)

**Interfaces:**
- Consumes: `Register-TfRelay.ps1 -Status` / default mode (Task 9), `Invoke-Tf.ps1` command line (Task 4), `docs/plans/relay-notes.md` (Tasks 4/7: R3q and R3c outcomes).
- Produces: the prompt files Claude follows.

- [ ] **Step 1: Add the failing doc checks**

Insert before `# ---- report`:

```powershell
    # ---- docs: skill and commands ---------------------------------------------------------------------
    $SkillMd = Join-Path $Plugin 'skills\tfvc\SKILL.md'
    $skillText = Get-Content -LiteralPath $SkillMd -Raw
    $fm = [regex]::Match($skillText, '(?s)^---\r?\n(.*?)\r?\n---').Groups[1].Value
    $descLines = @(); $inDesc = $false
    foreach ($l in ($fm -split "`r?`n")) {
        if ($l -match '^description:\s*>?\s*(.*)$') { $inDesc = $true; if ($Matches[1]) { $descLines += $Matches[1] }; continue }
        if ($inDesc) { if ($l -match '^\s+(.*)$') { $descLines += $Matches[1] } else { $inDesc = $false } }
    }
    $desc = ($descLines -join ' ')
    Check 'R28a SKILL.md description stays under 1024 chars and names TF30063, "not authorized", SSH and /tf-relay' `
        (($desc.Length -lt 1024) -and ($desc -match 'TF30063') -and ($desc -match 'not authorized') -and ($desc -match 'SSH') -and ($desc -match '/tf-relay')) "len=$($desc.Length)"
    $body = $skillText.Substring($skillText.IndexOf("`n---", 4) + 4)
    $words = @($body -split '\s+' | Where-Object { $_ }).Count
    Check 'R28b SKILL.md: "Running tf" with the Invoke-Tf.ps1 line replaces "Finding tf.exe"; TF30063 row; body <= 580 words' `
        (($skillText -match '## Running tf') -and ($skillText -match 'scripts/Invoke-Tf\.ps1') -and ($skillText -notmatch '## Finding tf\.exe') -and ($skillText -match '(?m)^\|.*TF30063.*/tf-relay') -and ($words -le 580)) "words=$words"
    foreach ($c in 'tf-status', 'tf-checkout', 'tf-checkin', 'tf-get', 'tf-undo') {
        $t = Get-Content -LiteralPath (Join-Path $Plugin "commands\$c.md") -Raw
        Check "R29 $c.md runs tf per the skill's Running tf (no 'Resolve tf.exe')" (($t -match 'Running tf') -and ($t -notmatch 'Resolve `tf\.exe`')) ''
    }
    $relayCmd = if (Test-Path -LiteralPath (Join-Path $Plugin 'commands\tf-relay.md')) { Get-Content -LiteralPath (Join-Path $Plugin 'commands\tf-relay.md') -Raw } else { '' }
    Check 'R30 tf-relay.md: frontmatter, -Status, explicit yes before registering, settings.local.json merge, never ~/.claude/settings.json' `
        (($relayCmd -match '(?s)^---\r?\ndescription:.*argument-hint:.*?\r?\n---') -and ($relayCmd -match 'Register-TfRelay\.ps1" -Status') -and ($relayCmd -match 'only after an explicit yes') -and ($relayCmd -match 'settings\.local\.json') -and ($relayCmd -match 'Never edit `~/\.claude/settings\.json`')) ''
```

- [ ] **Step 2: Run test-relay.ps1 to verify R28–R30 fail**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-relay.ps1`
Expected: R28a, R28b, R29 (×5), R30 FAIL; everything else PASS.

- [ ] **Step 3: Create commands/tf-relay.md**

```markdown
---
description: Relay tf through your interactive Windows session when this is an SSH session without network credentials (TF30063) — status, on/off, one-time setup
argument-hint: "[status | on | off | auto]  (default: status)"
---

Manage the relay transport that runs `tf` inside your interactive Windows session: $ARGUMENTS

The relay exists for sessions without network credentials (typically an SSH key logon, for example VS Code
Remote-SSH), where `tf.exe` fails with `TF30063: You are not authorized`. Each `tf` call is handed to a worker
that the scheduled task `ClaudeTfvcRelay` starts in your console or RDP session. The scripts live in the `tfvc`
skill's `scripts/` folder, next to `Find-Tf.ps1` (the skill's "Running tf" section names the folder).

1. **status** (the default): run
   `powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>/scripts/Register-TfRelay.ps1" -Status`
   and summarize the report: session kind, effective transport and where the setting comes from, task state and
   last result, worker version, probe timing. Exit code 0 means the relay is usable.
   - If the task is NOT registered: show the exact registration command from the report, explain that the worker
     needs an interactive Windows session (console or RDP; a disconnected RDP session is fine), and ask whether
     to run the registration now. Run it **only after an explicit yes**, from this session, then run `-Status`
     again. If registration fails here, tell the user to run the same command from an RDP or console session.
   - If the last result decodes to "not logged on interactively" (`0x00041303`): tell the user to connect over
     RDP once and just disconnect (do not sign out), then rerun `/tf-relay`.
2. **on** / **off** / **auto**: first do `status` (offering registration when needed), then write
   `env.TFVC_TRANSPORT` in `<project root>/.claude/settings.local.json`: `relay` for `on`, `direct` for `off`,
   remove the key for `auto`. Merge into the existing file (keep every other key, create the folder/file if
   missing, keep the JSON valid with backslashes escaped). Never edit `~/.claude/settings.json`.
3. Report the transport now in effect. It applies immediately: the hook and the skill read the file directly, and
   Claude Code also exports it as `TFVC_TRANSPORT` for shell commands. Do not check anything in.
```

- [ ] **Step 4: Rewrite the SKILL.md description and the "Finding tf.exe" section**

Replace the frontmatter `description` with:

```yaml
description: >
  Use tf.exe (TFVC, TFS, Team Foundation Version Control, also hosted by Azure DevOps Server) instead of git on
  Windows projects. Use this whenever a project has no .git folder, files are read-only until checked out (saving
  fails with EPERM or "access denied"), tf.exe reports "no working folder mapping" or "TF30063: not authorized"
  (typical in an SSH or VS Code Remote-SSH session; see /tf-relay), or the user mentions TFS, TFVC, Team Explorer,
  tf.exe, check-in, checkout, pending changes, shelvesets, workspaces, or which TF.exe or Visual Studio version a
  project should use (/tf-select), even when they say "commit" or "git". Covers running tf.exe (directly, or
  relayed into the interactive session from SSH), the read-only/checkout model, status/checkout/checkin/get/undo/
  shelve, and local-vs-server workspaces with .tfignore.
```

Replace the whole `## Finding tf.exe` section (heading through the paragraph ending "Below, `tf` stands for that resolved path.") with:

````markdown
## Running tf
Run `tf` only through the launcher bundled with this skill. It resolves `tf.exe` and picks the transport: direct,
or a relay into your interactive Windows session when this is an SSH session without network credentials:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/Invoke-Tf.ps1" <tf arguments>
```

Below, `tf` stands for that command line; append `tf`'s own arguments unchanged. The same line works from
PowerShell and from Git Bash. OPTION-SENTENCE Exit codes are `tf`'s own; 120 means the relay is not set up (run
`/tf-relay`), 124 a relay timeout, 127 no `tf.exe` found. `scripts/Find-Tf.ps1 -List` lists every TF.exe with its
file version (15 = VS 2017, 16 = VS 2019, 17 = VS 2022, 18 = VS 18) for `/tf-select`; the resolution order is the
project's `.claude/settings.local.json` (then `settings.json`) `env.TF_EXE`, the `TF_EXE` environment variable,
PATH, vswhere, then the default Visual Studio folders, newest version first.
````

Replace `OPTION-SENTENCE` according to `docs/plans/relay-notes.md`:
- R3c PASS (Git Bash leaves `/noprompt` alone): `` `tf` accepts `-option` as well as `/option` from either shell. ``
- R3c INFO (converted to a path): `` Use `-option` rather than `/option` from Git Bash, which rewrites `/option` into a path. ``
- If R3q was skipped in Task 4 (5.1 `-File` loses embedded double quotes), append: `` Keep double quotes out of check-in comments given on the command line; use single quotes inside the text. ``

Add this row at the end of the "Common mistakes" table:

```markdown
| Retrying `tf` after `TF30063: not authorized` in an SSH / Remote-SSH session | The session has no network credentials; run `/tf-relay` so `tf` runs in your interactive Windows session |
```

Keep the body at or under 580 words (R28b); trim the "Everyday commands" comments if needed, never the rules of engagement.

- [ ] **Step 5: Reword the five commands**

- `tf-status.md`: replace the sentence starting "Resolve `tf.exe` per the `tfvc` skill (project ..." up to "then run" with: ``Run `tf status` per the `tfvc` skill's "Running tf" (the launcher `scripts/Invoke-Tf.ps1` picks the direct or relay transport; works from the PowerShell or Bash tool), optionally scoped to `$ARGUMENTS` if a path is given.`` and delete the now-duplicate "`tf status` (optionally scoped ...)" remainder so the paragraph reads once.
- `tf-checkout.md`, `tf-get.md`: replace ``Resolve `tf.exe` per the `tfvc` skill, then run`` with ``Run, per the `tfvc` skill's "Running tf",``.
- `tf-checkin.md` step 1 and `tf-undo.md` step 1: replace ``Resolve `tf.exe` per the `tfvc` skill and run `tf status` `` with ``Run `tf status` per the `tfvc` skill's "Running tf" ``.

- [ ] **Step 6: Run test-relay.ps1**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-relay.ps1`
Expected: R28a, R28b, R29 ×5, R30 PASS, `0 failed`.

- [ ] **Step 7: Commit**

```bash
git add plugins/claude-tfvc/commands plugins/claude-tfvc/skills/tfvc/SKILL.md tests/test-relay.ps1
git commit -m "skill and commands: run tf through Invoke-Tf.ps1; add /tf-relay" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: README, CHANGELOG, CLAUDE.md, version 0.4.0

**Files:**
- Modify: `README.md`, `CHANGELOG.md`, `CLAUDE.md`, `plugins/claude-tfvc/.claude-plugin/plugin.json:5`, `.claude-plugin/marketplace.json:14`
- Test: `tests/test-relay.ps1` (insert before `# ---- report`); `tests/test-hook.ps1` T11 already checks the versions agree.

**Interfaces:** none (documentation). Consumes `docs/plans/relay-notes.md` for the Git Bash and embedded-quote outcomes.

- [ ] **Step 1: Add the failing doc checks**

Insert before `# ---- report`:

```powershell
    # ---- docs: README, CLAUDE.md, versions ----------------------------------------------------------------
    $readme = Get-Content -LiteralPath (Join-Path $Repo 'README.md') -Raw
    Check 'R31a README has "Remote sessions (SSH)" with TF30063, TFVC_TRANSPORT, /tf-relay, the RDP note and the permissions example' `
        (($readme -match '## Remote sessions \(SSH\)') -and ($readme -match 'TF30063') -and ($readme -match 'TFVC_TRANSPORT') -and ($readme -match '/tf-relay') -and ($readme -match 'RDP') -and ($readme -match 'Invoke-Tf\.ps1\*checkin')) ''
    Check 'R31b README commands table lists /tf-relay and the tests section names test-relay.ps1' (($readme -match '\| `/tf-relay') -and ($readme -match 'test-relay\.ps1')) ''
    $claudeMd = Get-Content -LiteralPath (Join-Path $Repo 'CLAUDE.md') -Raw
    Check 'R31c CLAUDE.md records the new invariants (launcher, byte-transparent direct, signed tf.exe, expired requests, duplicate quoting function)' `
        (($claudeMd -match 'Invoke-Tf\.ps1') -and ($claudeMd -match 'byte') -and ($claudeMd -match 'signed') -and ($claudeMd -match 'expired') -and ($claudeMd -match 'ConvertTo-CommandLine')) ''
    $vPlugin = (Get-Content -LiteralPath (Join-Path $Plugin '.claude-plugin\plugin.json') -Raw | ConvertFrom-Json).version
    Check 'R31d plugin version is 0.4.0' ($vPlugin -eq '0.4.0') "version=$vPlugin"
```

- [ ] **Step 2: Run test-relay.ps1 to verify R31a–d fail**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-relay.ps1`
Expected: R31a–d FAIL; everything else PASS.

- [ ] **Step 3: README**

1. In the "It provides" list add a fourth bullet:
   ``- a **relay for SSH sessions** — when Claude Code runs over SSH without network credentials (`TF30063`), `tf` is executed inside your interactive Windows session through a scheduled task; set up once with `/tf-relay`.``
2. In the Commands table add the row: ``| `/tf-relay [status\|on\|off\|auto]` | Relay `tf` through your interactive session from SSH; status, one-time setup, `TFVC_TRANSPORT` |``
3. In "The auto-checkout hook", replace step 3 with: ``3. runs `tf checkout /noprompt` through the launcher `skills/tfvc/scripts/Invoke-Tf.ps1` (direct, or relayed from an SSH session; see below) — `/noprompt` makes a missing server login fail fast instead of opening a credential dialog,`` and step 4 with: ``4. **always allows the edit to proceed** (it never denies/blocks); when checkout fails it hands Claude the reason as hook context, for example "TF30063 … run /tf-relay".``
4. Insert this section before "## Workspace types & `.tfignore`":

````markdown
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
````

   If the acceptance run (Task 12) cannot confirm the password-logon sentence, delete that parenthesis.
5. In "Tests" add: ``- `tests\test-relay.ps1` exercises the launcher (direct and relay), the worker, `Register-TfRelay.ps1 -Status`, the hook in relay mode and the docs, without touching the scheduler (a child worker and a fake `tf.exe` compiled from `tests\FakeTf.cs`): `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-relay.ps1` `` and note that `test-hook.ps1` now also needs `csc.exe` (ships with .NET Framework 4.x) for the fake.
6. In "Requirements", append to the Git for Windows bullet whatever `docs/plans/relay-notes.md` says about `/option` from Git Bash (keep "works unchanged from both" only if R3c passed; otherwise "use `-option` from Git Bash").

- [ ] **Step 4: CHANGELOG**

Insert above `## [0.3.0]` (use today's date):

```markdown
## [0.4.0] - <YYYY-MM-DD>
### Added
- Relay transport for sessions without network credentials (SSH key logon, VS Code Remote-SSH), where `tf.exe`
  fails with `TF30063: not authorized`: `skills/tfvc/scripts/Invoke-Tf.ps1` hands each `tf` call to
  `Tf-RelayWorker.ps1`, which the scheduled task `ClaudeTfvcRelay` runs in the user's interactive Windows session.
  Per-user file queue, one file per request, expired requests never run, the worker copy is refreshed
  automatically after plugin updates (no re-registration).
- `/tf-relay [status|on|off|auto]`: diagnostics (task state, decoded `LastTaskResult`, timed probe), one-time
  registration after confirmation, and the `TFVC_TRANSPORT` project setting (`auto` by default).
- `skills/tfvc/scripts/Register-TfRelay.ps1`: register / `-Unregister` / `-Status`.
- `tests/test-relay.ps1` and a shared compiled fake `tf.exe` (`tests/FakeTf.cs`) used by both harnesses.
### Changed
- The skill and the `/tf-*` commands run `tf` through `Invoke-Tf.ps1` instead of a resolved `tf.exe` path. In
  direct mode the child inherits stdout, stderr is relayed byte for byte, and exit codes are `tf`'s own; the
  launcher's failures use 120 (relay unavailable), 124 (relay timeout), 127 (no `tf.exe`).
- The hook calls the launcher and, when checkout fails, tells Claude why through `additionalContext` (TF30063 →
  run `/tf-relay`; task not started → log in over RDP once). `hooks.json` timeout 30 s → 45 s.
- `Find-Tf.ps1`: `Get-ProjectEnvSetting` reads any `env.<Name>` from the project settings (`TF_EXE`,
  `TFVC_TRANSPORT`); the resolution order is unchanged.
### Security
- The relay worker runs only a Microsoft-signed executable named `tf.exe`, from an argument array, with
  `/noprompt` forced and stdin closed; no credentials are stored; comments and output are never logged.
```

- [ ] **Step 5: CLAUDE.md**

1. Layout, item 1 (Skill): after "`-List` prints every TF.exe with its version." add: ``The folder also holds `Invoke-Tf.ps1` (the ONLY way the plugin runs `tf`: direct mode, or the relay client), `Tf-RelayWorker.ps1` (installed as a single file under `%LOCALAPPDATA%\claude-tfvc\relay` and run by the scheduled task `ClaudeTfvcRelay`) and `Register-TfRelay.ps1` (register / `-Unregister` / `-Status`).``
2. Layout, item 2 (Commands): "six slash commands" → "seven slash commands", add `/tf-relay` (status, on/off/auto, offers registration) to the list.
3. Layout, item 3 (Hook): replace "runs `tf checkout` on the target file" with "runs `tf checkout` on the target file through `Invoke-Tf.ps1` and reports a failure as `additionalContext`"; "The script loads `Find-Tf.ps1` lazily" → "The script loads `Invoke-Tf.ps1` (which loads `Find-Tf.ps1`) lazily".
4. Invariants: add these bullets:
   - ``**`tf` runs only through `Invoke-Tf.ps1`.** The hook dot-sources it, the skill and commands run it with `powershell -File`. **Direct mode is byte-transparent**: the child `tf.exe` inherits stdout and stdin; stderr is relayed byte for byte; the exit code is `tf`'s. Launcher codes 120/124/127 never overlap `tf`'s.``
   - ``**The worker is a narrow executor.** It runs only an executable named `tf.exe` with a valid Microsoft Authenticode signature (test bypass: `CLAUDE_TFVC_RELAY_ALLOW_UNSIGNED=1` in the worker's own environment, never from a request), only from an argument array, never an expired request (`expiresUtc` in the past is deleted unrun), always with `/noprompt`. It dot-sources nothing: it is installed as one file. `ConvertTo-CommandLine` therefore exists twice (launcher and worker) on purpose; `tests/test-relay.ps1` keeps the copies identical.``
   - ``**The relay lives in the user profile** (`%LOCALAPPDATA%\claude-tfvc\relay`), never in a project or in the versioned plugin cache; the task's action path never changes, the worker copy is refreshed by hash.``
   - ``**Four PowerShell files** (`Find-Tf.ps1`, `Invoke-Tf.ps1`, `Tf-RelayWorker.ps1`, `Register-TfRelay.ps1`) plus the hook: Windows PowerShell 5.1 compatible, pure ASCII, no BOM, dot-source guards.``
   Also change "Both PowerShell files" in the existing bullet to "All PowerShell files".
5. Tests: add ``- `tests/test-relay.ps1` — launcher (direct and relay), worker, `Register-TfRelay.ps1 -Status`, hook in relay mode, docs; the scheduler is never touched (`CLAUDE_TFVC_RELAY_LAUNCH=child`, `CLAUDE_TFVC_RELAY_ROOT`). Both harnesses compile `tests/FakeTf.cs` with `csc.exe`.``

- [ ] **Step 6: Versions**

Set `"version": "0.4.0"` in `plugins/claude-tfvc/.claude-plugin/plugin.json` and in `.claude-plugin/marketplace.json`.

- [ ] **Step 7: Run both harnesses**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-hook.ps1` and `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-relay.ps1`
Expected: T11 PASS (three versions agree), R31a–d PASS, `0 failed` in both.

- [ ] **Step 8: Commit**

```bash
git add README.md CHANGELOG.md CLAUDE.md plugins/claude-tfvc/.claude-plugin/plugin.json .claude-plugin/marketplace.json tests/test-relay.ps1
git commit -m "docs: Remote sessions (SSH), changelog and invariants for the relay; version 0.4.0" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: Full verification, empirical checks, acceptance on the real machine

**Files:**
- Modify: `docs/plans/relay-notes.md` (results), possibly `plugins/claude-tfvc/hooks/tfvc-checkout.ps1` (12.2), `README.md` (12.6)

**Interfaces:** none. This task closes the "verify empirically" list of the design (section 19) and runs the acceptance checklist (section 14.3).

- [ ] **Step 1: Clean full run**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-hook.ps1; powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-relay.ps1`
Expected: `0 failed` in both, SKIP only for tools missing on the machine (none on DEVELOPER4). `git status --short` is empty.

- [ ] **Step 2: systemMessage for PreToolUse (design 19.2)**

Create a throwaway project folder outside the repo with `.claude/settings.json`:

```json
{ "hooks": { "PreToolUse": [ { "matcher": "Edit|Write", "hooks": [ { "type": "command",
  "command": "powershell -NoProfile -Command \"Write-Output '{\\\"systemMessage\\\":\\\"hook systemMessage visible\\\",\\\"hookSpecificOutput\\\":{\\\"hookEventName\\\":\\\"PreToolUse\\\",\\\"additionalContext\\\":\\\"hook additionalContext visible\\\"}}'\"" } ] } ] } }
```

Open Claude Code there, ask it to create a file, and look at the transcript (also with Ctrl+O verbose). Record in `docs/plans/relay-notes.md`: `systemMessage shown for PreToolUse: yes | no`, `additionalContext reached the model: yes | no`. If `systemMessage` is shown, add `systemMessage = $msg` next to `hookSpecificOutput` in the hook's JSON (`@{ systemMessage = $msg; hookSpecificOutput = @{ ... } }`), rerun both harnesses, and mention it in the CHANGELOG hook bullet. Commit if changed.

- [ ] **Step 3: Acceptance over SSH (design 14.3; needs the user)**

From a VS Code Remote-SSH (key) session to DEVELOPER4 with the task registered (Task 9 step 5) and an RDP session that is connected or disconnected but not signed out, inside a TFVC project with a server workspace:

1. `/tf-relay` → `Session: remote`, `Transport: relay`, `Task: registered`, `Probe: ... exit 0`. If `Session:` says local, `SSH_CONNECTION` does not reach the hook/tool processes (design 19.7): implement the fallback `CLAUDE_TFVC_REMOTE=1` read like `TFVC_TRANSPORT` in `Resolve-TfTransport` (`Get-ProjectEnvSetting -Name CLAUDE_TFVC_REMOTE`, then `$env:CLAUDE_TFVC_REMOTE`), add R9i for it, document it in README, commit.
2. Edit a read-only file with Claude: the edit applies without manual steps; `tf status` shows `edit` for it.
3. Edit five different read-only files in one request (Claude edits them in parallel): all five show `edit`.
4. `/tf-status`, `/tf-checkout <file>`, `/tf-get`, `/tf-undo <file>` work; `/tf-checkin` shows the pending set and asks for confirmation; after "yes", check in with the comment `בדיקה "quotes" & ampersand` and confirm with `tf changeset /latest` (or Team Explorer) that the comment is stored unchanged; `tf status` output containing Hebrew paths is readable in the transcript.
5. Sign out of the RDP session (not just disconnect), then edit a read-only file: the hook lets the edit proceed and Claude reports "not logged on to Windows interactively; connect once over RDP"; `/tf-relay` shows the decoded `0x00041303`. Log in over RDP again, disconnect, repeat the edit: it works.
6. In the console session, with no `TFVC_TRANSPORT` set: `/tf-status` runs `tf.exe` directly (`/tf-relay` shows `Transport: direct`), and both harnesses pass.
7. Bump the plugin version to a scratch value in the cached plugin copy's `plugin.json` (or reinstall the plugin after merging): the next relayed `tf` call refreshes `%LOCALAPPDATA%\claude-tfvc\relay\worker.version` and keeps working without re-registration.
8. If the user has password SSH available: `ssh` with a password, run `tf status` directly; no TF30063 keeps the README sentence about password logons, otherwise delete it (Task 11 step 3.4).

Record every outcome in `docs/plans/relay-notes.md` with the date. Anything that fails is a bug to fix with a new failing check first (the harness style above), not a note.

- [ ] **Step 4: Commit the notes**

```bash
git add docs/plans/relay-notes.md README.md plugins/claude-tfvc/hooks/tfvc-checkout.ps1 CHANGELOG.md tests/test-relay.ps1 plugins/claude-tfvc/skills/tfvc/scripts/Invoke-Tf.ps1
git commit -m "relay: empirical checks and acceptance results" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

Then hand the branch over (superpowers:finishing-a-development-branch): a PR from `feat/relay-transport` to `main`, as the repo's history does.

---

## Self-review notes

- **Spec coverage:** design sections 5–13 map to Tasks 1–11; 14.1 checks 1–12 map to R1, R2, R3/R3b/R3r, R4/R4r, R5, R6, R7, R8, R9, R10, R11, R12; 14.2 to Task 1/8/9 changes in `test-hook.ps1`; 14.3 to Task 12; section 19 items to Tasks 4 (3), 7 (4), 9 (1), 12 (2, 5, 6, 7).
- **Names used across tasks:** `Get-ProjectEnvSetting -Detailed` (T2 → T3), `Get-TfRelayPaths`, `Test-TfRelayWorkerAlive`, `Test-TfRelayTaskRegistered`, `ConvertTo-TfRelayFailureText`, `Get-TfRegistrationHint`, `Resolve-TfTransport` (T3 → T4/T7/T9), `ConvertTo-CommandLine`, `New-TfResult`, `Invoke-TfDirect`, `Invoke-Tf` (T4 → T7/T8), `Install-TfRelayWorker`, `Start-TfRelayWorker`, `Get-TfRelayTaskInfo`, `Format-TfTaskState`, `Invoke-TfRelay` (T7 → T9), `Invoke-RelayRequest`, `Start-RelayWorker` (T5/T6), `Get-TfRelayTaskSpec`, `Get-TfRelayStatusReport` (T9 → tests). Harness helpers from Task 1 are used unchanged by every later task; `Note` is defined in Task 7 before its first use; `New-Request`, `Write-QueuedRequest`, `Start-WorkerChild`, `Get-WorkerLog`, `Compare-Args`, `$Queue`, `$HardArgs`, `$RelayOn`, `$StatusEnv` are defined in the task that first uses them and reused later in file order.
- **Review Focus coverage:** 1 → R32a/b/c; 2 → R13, R3, R3r; 3 → R33, R35, R25; 4 → R16a/b; 5 → R27.

