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
$ProjLocalRelay   = Join-Path $S 'proj-local-relay';   New-Item -ItemType Directory -Path "$ProjLocalRelay\.claude" -Force | Out-Null
$ProjSharedDirect = Join-Path $S 'proj-shared-direct'; New-Item -ItemType Directory -Path "$ProjSharedDirect\.claude" -Force | Out-Null
Set-Content -LiteralPath "$ProjLocalRelay\.claude\settings.local.json" -Value (@{ env = @{ TFVC_TRANSPORT = 'relay' } } | ConvertTo-Json -Depth 5)
Set-Content -LiteralPath "$ProjLocalRelay\.claude\settings.json"       -Value (@{ env = @{ TFVC_TRANSPORT = 'direct' } } | ConvertTo-Json -Depth 5)
Set-Content -LiteralPath "$ProjSharedDirect\.claude\settings.json"     -Value (@{ env = @{ TFVC_TRANSPORT = 'direct' } } | ConvertTo-Json -Depth 5)
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
        # Plain assignments (not if-expressions): an empty byte[] returned from an expression would unroll to $null.
        $outBytes = [byte[]]@(); if (Test-Path -LiteralPath $out) { $outBytes = [System.IO.File]::ReadAllBytes($out) }
        $errBytes = [byte[]]@(); if (Test-Path -LiteralPath $err) { $errBytes = [System.IO.File]::ReadAllBytes($err) }
        return @{ Exit = $p.ExitCode; Out = $Utf8.GetString($outBytes); Err = $Utf8.GetString($errBytes); OutBytes = $outBytes; ErrBytes = $errBytes; Calls = @(Get-FakeCalls) }
    } finally { Restore-TestEnv $saved }
}
function Invoke-InChild([string]$Exe, [hashtable]$EnvVars, [string]$Command) {
    # Runs $Command in a child interpreter with $EnvVars applied; returns stdout+stderr text and the exit code.
    $saved = Set-TestEnv $EnvVars
    try {
        # -EncodedCommand (not -Command) so embedded double quotes survive 5.1. Under 5.1 it also serializes the
        # progress stream as CLIXML on a redirected stderr, so progress is silenced first.
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes("`$ProgressPreference = 'SilentlyContinue'; " + $Command))
        $out = (& $Exes[$Exe] -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1 | ForEach-Object { "$_" } | Out-String).Trim()
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

    # ---- R9 transport selection -----------------------------------------------------------------
    function Get-Transport([string]$Exe, [hashtable]$EnvVars, [string]$ProjectDir) {
        $r = Invoke-InChild $Exe $EnvVars ". '$InvokeTf'; `$t = Resolve-TfTransport -ProjectDir '$ProjectDir'; (`$t.Transport, `$t.Setting, `$t.Source, `$t.Remote, `$t.TaskRegistered) -join '|'"
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

        $r = Invoke-InChild $exe @{} ". '$InvokeTf'; (ConvertTo-TfRelayFailureText 267011) -match 'RDP'; (ConvertTo-TfRelayFailureText 2147943726) -match 'ogon'; (ConvertTo-TfRelayFailureText -2147023570) -match 'ogon'; (ConvertTo-TfRelayFailureText 0x800710E0) -match 'refused'; `$null -eq (ConvertTo-TfRelayFailureText 0)"
        Check "$exe R9i LastTaskResult codes decode whether given as UInt32 values or as Int32 hex literals" ((($r.Out -replace '\s', '') -eq 'TrueTrueTrueTrueTrue')) "out=[$($r.Out)]"
    }

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

    # ---- report (keep this anchor last; later tasks insert their checks above it) --------------------
}
finally { [Console]::InputEncoding = $savedEnc }

$Results | Format-Table -AutoSize -Wrap | Out-String -Width 220
$fail = @($Results | Where-Object Result -eq 'FAIL').Count
$skip = @($Results | Where-Object Result -eq 'SKIP').Count
"$(@($Results).Count) checks, $fail failed, $skip skipped"
exit $fail
