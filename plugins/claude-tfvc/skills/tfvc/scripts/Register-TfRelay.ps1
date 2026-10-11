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
        [void]$lines.Add("Task:       " + $(if ($registered) { 'registered' } else { 'NOT registered' }) + " (simulated by CLAUDE_TFVC_RELAY_LAUNCH=$env:CLAUDE_TFVC_RELAY_LAUNCH)")
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
