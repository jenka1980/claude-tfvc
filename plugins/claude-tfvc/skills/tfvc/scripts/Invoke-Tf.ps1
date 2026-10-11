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
    $Code = [int64]$Code -band 0xFFFFFFFFL   # a bare 0x8007052E literal is a negative Int32; the scheduler yields the UInt32 value
    switch ($Code) {
        0x00041303L { return 'the relay task could not start because you are not logged on to Windows interactively; connect once over RDP (you may disconnect afterwards, but do not sign out)' }
        0x8007052EL { return 'logon failure: the relay task''s user does not match the current account or the password changed; re-run Register-TfRelay.ps1' }
        0x80070569L { return 'this logon type is denied for scheduled tasks by domain policy' }
        0x800710E0L { return 'the relay task refused to start (policy or task conditions); check Task Scheduler' }
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

function Invoke-Tf {
    # Resolves tf.exe (Find-Tf.ps1), picks the transport, runs tf, returns { ExitCode, StdOut, StdErr, Transport, Diagnostic }.
    # Without -Capture, direct mode streams to the console and StdOut is $null. The hook uses -Capture.
    param([string[]]$Arguments, [string]$ProjectDir, [string]$WorkingDirectory, [switch]$Capture, [int]$TimeoutSec = 600, [int]$PickupTimeoutSec = 30)
    if (-not $ProjectDir) { $ProjectDir = $env:CLAUDE_PROJECT_DIR }
    if (-not $ProjectDir) { $ProjectDir = (Get-Location).ProviderPath }
    if (-not $WorkingDirectory) { $WorkingDirectory = (Get-Location).ProviderPath }
    $tf = Resolve-TfExe -ProjectDir $ProjectDir
    if (-not $tf) {
        return New-TfResult -ExitCode 127 -Transport 'none' -Diagnostic 'claude-tfvc: no tf.exe found (checked the project .claude\settings*.json env.TF_EXE, TF_EXE, PATH, vswhere and the Visual Studio folders); install Team Explorer or pick one with /tf-select'
    }
    $choice = Resolve-TfTransport -ProjectDir $ProjectDir
    if ($choice.Transport -eq 'relay') {
        $registered = $choice.TaskRegistered
        if ($null -eq $registered -and -not (Test-TfRelayWorkerAlive (Get-TfRelayPaths))) { $registered = Test-TfRelayTaskRegistered }
        if ($null -ne $registered -and -not $registered) {
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
