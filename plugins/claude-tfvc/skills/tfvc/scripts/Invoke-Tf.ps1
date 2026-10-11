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
