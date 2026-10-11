<#
.SYNOPSIS
  claude-tfvc relay worker: runs tf.exe inside the user's interactive Windows session on behalf of sessions that
  have no network credentials (SSH). Started on demand by the scheduled task ClaudeTfvcRelay.

.DESCRIPTION
  Queue: <root>\queue\<id>.req.json (waiting) -> <id>.run.json (claimed) -> <id>.res.json (answered), where
  <root> is %LOCALAPPDATA%\claude-tfvc\relay or CLAUDE_TFVC_RELAY_ROOT (test seam).
  Rules: one worker at a time (worker.lock held with FileShare.None); oldest request first; an expired request
  is deleted unrun; only an executable named tf.exe, under Program Files, a Visual Studio installation (vswhere)
  or a folder listed in CLAUDE_TFVC_RELAY_TRUSTED_ROOTS (semicolon-separated), with a valid Microsoft Authenticode
  signature is started (CLAUDE_TFVC_RELAY_ALLOW_UNSIGNED=1 is the test bypass for the signature only; both
  variables are read from THIS process's environment, a request cannot set them);
  /noprompt is always present; stdin is closed; output is decoded from the system ANSI code page; the log never
  records comments, further arguments, paths or output (a first argument that is not a plain word is logged as
  '?'). The worker lingers CLAUDE_TFVC_RELAY_LINGER_SEC (default
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
$VsInstallRoots = @{}   # 'list' -> the vswhere installationPath values, queried once per worker life

function Get-AnsiEncoding {
    # The system ANSI code page (what tf.exe writes when redirected). [Text.Encoding]::Default on Windows
    # PowerShell 5.1; GetEncoding(0) on pwsh, where Default is UTF-8.
    if ($PSVersionTable.PSEdition -eq 'Core') {
        try { return [System.Text.Encoding]::GetEncoding(0) } catch { }
    }
    return [System.Text.Encoding]::Default
}

function Get-TrustedTfRoots {
    # Where a tf.exe may live: both Program Files folders, every Visual Studio installation vswhere knows, and the
    # semicolon-separated CLAUDE_TFVC_RELAY_TRUSTED_ROOTS of this process (the user's own environment).
    if (-not $VsInstallRoots.ContainsKey('list')) {
        $found = @()
        foreach ($base in @(@($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ })) {
            $vswhere = Join-Path $base 'Microsoft Visual Studio\Installer\vswhere.exe'
            if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
                try { $found = @(& $vswhere -all -prerelease -products * -property installationPath 2>$null | Where-Object { $_ }) } catch { }
                break
            }
        }
        $VsInstallRoots['list'] = $found
    }
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) + @($VsInstallRoots['list']) + @("$env:CLAUDE_TFVC_RELAY_TRUSTED_ROOTS" -split ';')
    return @($roots | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
}

function Test-TrustedTfLocation {
    # $true when the full path lies under one of Get-TrustedTfRoots (case-insensitive, whole folder names).
    param([string]$FullPath)
    foreach ($root in Get-TrustedTfRoots) {
        try { $r = [System.IO.Path]::GetFullPath($root) } catch { continue }
        if (-not $r.EndsWith('\')) { $r += '\' }
        if ($FullPath.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
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
    # $null when the file may run, otherwise the refusal text. Only tf.exe, only an absolute path, only from a
    # trusted location, only Microsoft-signed; the signature verdict is cached per path and file version (a
    # replaced file is checked again).
    param([string]$Path)
    if ([System.IO.Path]::GetFileName($Path) -ine 'tf.exe') { return "refusing to run '$Path': the executable must be named tf.exe" }
    if (-not [System.IO.Path]::IsPathRooted($Path)) { return "refusing to run '$Path': the tf.exe path must be absolute" }
    $Path = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "tf.exe not found at '$Path'" }
    if (-not (Test-TrustedTfLocation $Path)) { return "refusing to run '$Path': tf.exe must live under Program Files or a Visual Studio installation (set CLAUDE_TFVC_RELAY_TRUSTED_ROOTS in your own environment to allow another folder)" }
    if ($env:CLAUDE_TFVC_RELAY_ALLOW_UNSIGNED -eq '1') { return $null }
    $item = Get-Item -LiteralPath $Path
    $key = "$Path|$($item.LastWriteTimeUtc.Ticks)|$($item.Length)"
    if ($VerifiedTf.ContainsKey($key)) { return $VerifiedTf[$key] }
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    $verdict = $null
    if ($sig.Status -ne 'Valid' -or "$($sig.SignerCertificate.Subject)" -notmatch '(^|, )O=Microsoft Corporation(,|$)') {
        $verdict = "refusing to run '$Path': not a Microsoft-signed tf.exe (signature status: $($sig.Status))"
    }
    $VerifiedTf[$key] = $verdict
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
        if ($argList.Count -gt 0 -and $argList[0] -match '^[A-Za-z]+$') { $verb = $argList[0] }   # a path or anything else stays '?'
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
                $psi.FileName = [System.IO.Path]::GetFullPath("$($req.tf)")
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
        $skip = @{}   # names of requests this run will not retry
        while ($true) {
            $now = [DateTime]::UtcNow
            if (($now - $lastSweep).TotalSeconds -ge 60) { Remove-RelayOrphans; $lastSweep = $now }
            if (($now - $born).TotalMinutes -ge $RelayMaxLifeMin) { Write-RelayLog 'stop: life limit'; break }
            $next = Get-ChildItem -LiteralPath $RelayQueue -Filter '*.req.json' -File -ErrorAction SilentlyContinue |
                    Where-Object { -not $skip.ContainsKey($_.Name) } |
                    Sort-Object LastWriteTimeUtc, Name | Select-Object -First 1
            if ($next) {
                $runPath = $next.FullName -replace '\.req\.json$', '.run.json'
                $claimed = $false
                try { [System.IO.File]::Move($next.FullName, $runPath); $claimed = $true }
                catch {
                    # stale .run.json or sharing violation; skipped for this run, the sweep removes stale files after an hour
                    Write-RelayLog "claim failed $($next.Name): $($_.Exception.Message)"
                    $skip[$next.Name] = $true
                    $idleSince = [DateTime]::UtcNow
                }
                if ($claimed) {
                    Invoke-RelayRequest -RunPath $runPath
                    $idleSince = [DateTime]::UtcNow
                    continue
                }
            }
            if (($now - $idleSince).TotalSeconds -ge $RelayLingerSec) { Write-RelayLog 'stop: idle'; break }
            Start-Sleep -Milliseconds 200
        }
    }
    finally { $lock.Close() }
}

if ($MyInvocation.InvocationName -ne '.') { Start-RelayWorker }
