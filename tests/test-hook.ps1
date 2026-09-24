<#
.SYNOPSIS
  Verification harness for the claude-tfvc plugin: the auto-checkout hook, hooks.json, and the shared
  tf.exe resolver (plugins/claude-tfvc/skills/tfvc/scripts/Find-Tf.ps1).

.DESCRIPTION
  Run from any PowerShell:   powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-hook.ps1
  Every hook case runs under Windows PowerShell 5.1 and, when installed, pwsh, with the console input
  code page forced to 862 (Hebrew OEM) to mimic a stock non-UTF-8 Windows console. A fake tf logs its
  arguments so the checks see exactly what the hook invoked. Fixtures live under -WorkDir (default:
  %TEMP%\claude\tfvc-tests). Exit code = number of failed checks. Checks that need a missing tool
  (pwsh, Git Bash, csc.exe) are reported as SKIP, never as PASS.
#>
param([string]$WorkDir = (Join-Path $env:TEMP 'claude\tfvc-tests'))

$ErrorActionPreference = 'Continue'
$Repo      = Split-Path -Parent $PSScriptRoot
$Plugin    = Join-Path $Repo 'plugins\claude-tfvc'
$Hook      = Join-Path $Plugin 'hooks\tfvc-checkout.ps1'
$HooksJson = Join-Path $Plugin 'hooks\hooks.json'
$FindTf    = Join-Path $Plugin 'skills\tfvc\scripts\Find-Tf.ps1'
$S         = $WorkDir
New-Item -ItemType Directory -Path $S -Force | Out-Null
$Log       = Join-Path $S 'tf-calls.log'
$FakeTf    = Join-Path $S 'fake-tf.ps1'
$FakeTf2   = Join-Path $S 'fake-tf2.ps1'
$Exes      = [ordered]@{ powershell = (Get-Command powershell.exe).Source }
$pwshCmd   = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($pwshCmd) { $Exes.pwsh = $pwshCmd.Source }
$Bash      = @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe", "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe") |
             Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
$Csc       = @("$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe", "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe") |
             Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$Results   = New-Object System.Collections.ArrayList

function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    [void]$Results.Add([pscustomobject]@{ Result = $(if ($Ok) { 'PASS' } else { 'FAIL' }); Name = $Name; Detail = $Detail })
}
function Skip([string]$Name, [string]$Why) { [void]$Results.Add([pscustomobject]@{ Result = 'SKIP'; Name = $Name; Detail = $Why }) }
function Reset-Log { Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue }
function Get-Log { if (Test-Path -LiteralPath $Log) { ((Get-Content -LiteralPath $Log -Encoding utf8) -join ' | ') } else { '' } }
function New-TestFile([string]$Path, [bool]$ReadOnly) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path -LiteralPath $Path) { (Get-Item -LiteralPath $Path).IsReadOnly = $false }
    Set-Content -LiteralPath $Path -Value 'x'
    (Get-Item -LiteralPath $Path).IsReadOnly = $ReadOnly
}
function New-VersionedExe([string]$Path, [string]$Version) {
    # A do-nothing exe carrying a file version, so version ordering can be tested on any machine.
    if (-not $Csc) { return $false }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $src = Join-Path $S ('stub-' + $Version.Replace('.', '_') + '.cs')
    Set-Content -LiteralPath $src -Value "[assembly: System.Reflection.AssemblyFileVersion(`"$Version`")]`nclass P { static void Main() { } }"
    & $Csc /nologo /target:exe "/out:$Path" $src | Out-Null
    return (Test-Path -LiteralPath $Path)
}
function New-Payload([string]$Path, [string]$Cwd) {
    $o = @{ tool_input = @{ file_path = $Path } }
    if ($Cwd) { $o.cwd = $Cwd }
    $o | ConvertTo-Json -Compress
}
function Set-ProjectDirEnv([string]$ProjectDir) {
    if ($ProjectDir) { $env:CLAUDE_PROJECT_DIR = $ProjectDir } else { Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue }
}
function Invoke-Hook([string]$Exe, [string]$Payload, [string]$ProjectDir = $ProjNoCfg) {
    # $ProjectDir = '' removes CLAUDE_PROJECT_DIR so the hook has to fall back to the payload cwd / current dir.
    Reset-Log
    Set-ProjectDirEnv $ProjectDir
    $out = ($Payload | & $Exes[$Exe] -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Hook 2>&1 | Out-String).Trim()
    return @{ Exit = $LASTEXITCODE; Out = $out; Log = (Get-Log) }
}
function New-EnvPrelude([hashtable]$EnvVars) {
    # Environment is set INSIDE the child: Windows re-derives ProgramFiles for every new 64-bit process,
    # so overrides inherited from the parent are lost.
    $lines = foreach ($k in $EnvVars.Keys) {
        if ($null -eq $EnvVars[$k]) { "Remove-Item -LiteralPath 'Env:\$k' -ErrorAction SilentlyContinue" }
        else { "`${env:$k} = '" + $EnvVars[$k].Replace("'", "''") + "'" }
    }
    return @($lines)
}
function Invoke-Resolver([string]$Exe, [hashtable]$EnvVars) {
    # Dot-source Find-Tf.ps1 in a child interpreter and call Resolve-TfExe.
    $cmd = (@(New-EnvPrelude $EnvVars) + @(". '$FindTf'", 'Resolve-TfExe')) -join '; '
    return ((& $Exes[$Exe] -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $cmd 2>&1 | Out-String).Trim())
}
function Invoke-FindTf([string]$Exe, [hashtable]$EnvVars, [string]$ScriptArgs) {
    # Run Find-Tf.ps1 as a script (not dot-sourced) with the given environment; returns output and exit code.
    # (The parameter is not called $Args: that name is PowerShell's automatic variable and binds to nothing here.)
    $cmd = (@(New-EnvPrelude $EnvVars) + @("& '$FindTf' $ScriptArgs", 'exit $LASTEXITCODE')) -join '; '
    $out = (& $Exes[$Exe] -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $cmd 2>&1 | Out-String).Trim()
    return @{ Exit = $LASTEXITCODE; Out = $out }
}

# ---- fixtures ---------------------------------------------------------------------------
Set-Content -LiteralPath $FakeTf  -Encoding utf8 -Value 'param([Parameter(ValueFromRemainingArguments=$true)]$a) ("[" + $PSVersionTable.PSVersion.Major + "] " + ($a -join " ")) | Out-File -Append -Encoding utf8 (Join-Path $PSScriptRoot "tf-calls.log")'
Set-Content -LiteralPath $FakeTf2 -Encoding utf8 -Value 'param([Parameter(ValueFromRemainingArguments=$true)]$a) ("[TF2] " + ($a -join " ")) | Out-File -Append -Encoding utf8 (Join-Path $PSScriptRoot "tf-calls.log")'
$RoAscii  = Join-Path $S 'ro.txt';                    New-TestFile $RoAscii  $true
$RoHebrew = Join-Path $S 'non-ascii-שלום\ro.txt';     New-TestFile $RoHebrew $true
$Rw       = Join-Path $S 'rw.txt';                    New-TestFile $Rw       $false
$Missing  = Join-Path $S 'does-not-exist\new.txt'
$PfVs18   = Join-Path $S 'pf-vs18'; $Tf18 = "$PfVs18\Microsoft Visual Studio\18\Community\Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\TF.exe"; New-TestFile $Tf18 $false
$PfVs14   = Join-Path $S 'pf-vs14'; $Tf14 = "$PfVs14\Microsoft Visual Studio 14.0\Common7\IDE\TF.exe";                                                                New-TestFile $Tf14 $false
$PfEmpty  = Join-Path $S 'pf-empty'; New-Item -ItemType Directory -Path $PfEmpty -Force | Out-Null
$MinPath  = "$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
# Three versioned TF.exe stubs where the NEWEST file version sits in the alphabetically middle folder,
# so neither first-hit nor last-hit folder order can pass, only a version sort.
$PfMix    = Join-Path $S 'pf-mix'
$MixTail  = 'Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\TF.exe'
$MixWant  = "$PfMix\Microsoft Visual Studio\2019\BuildTools\$MixTail"
$HaveMix  = (New-VersionedExe "$PfMix\Microsoft Visual Studio\18\Community\$MixTail" '15.0.0.0') -and
            (New-VersionedExe $MixWant '16.0.0.0') -and
            (New-VersionedExe "$PfMix\Microsoft Visual Studio\2022\Enterprise\$MixTail" '15.0.0.0')
# Project dirs with Claude Code settings: local points at TF2 and shared at TF1, so local must win.
$ProjNoCfg  = Join-Path $S 'proj-nocfg';  New-Item -ItemType Directory -Path $ProjNoCfg -Force | Out-Null
$Proj       = Join-Path $S 'proj';        New-Item -ItemType Directory -Path "$Proj\.claude" -Force | Out-Null
$ProjShared = Join-Path $S 'proj-shared'; New-Item -ItemType Directory -Path "$ProjShared\.claude" -Force | Out-Null
$ProjStale  = Join-Path $S 'proj-stale';  New-Item -ItemType Directory -Path "$ProjStale\.claude" -Force | Out-Null
Set-Content -LiteralPath "$Proj\.claude\settings.local.json"      -Value (@{ permissions = @{ allow = @('Read(x)') }; env = @{ TF_EXE = "`"$FakeTf2`""; OTHER = '1' } } | ConvertTo-Json -Depth 5)
Set-Content -LiteralPath "$Proj\.claude\settings.json"            -Value (@{ env = @{ TF_EXE = $FakeTf } } | ConvertTo-Json -Depth 5)
Set-Content -LiteralPath "$ProjShared\.claude\settings.json"      -Value (@{ env = @{ TF_EXE = $FakeTf2 } } | ConvertTo-Json -Depth 5)
Set-Content -LiteralPath "$ProjStale\.claude\settings.local.json" -Value (@{ env = @{ TF_EXE = (Join-Path $S 'nope\TF.exe') } } | ConvertTo-Json -Depth 5)

"host: PowerShell $($PSVersionTable.PSVersion)   interpreters: $($Exes.Keys -join ', ')   git bash: $(if ($Bash) { 'yes' } else { 'no' })   csc: $(if ($Csc) { 'yes' } else { 'no' })"

# ---- hook behaviour (every interpreter, console CP 862) -----------------------------------
$savedEnc  = [Console]::InputEncoding
$savedTf   = $env:TF_EXE
$savedProj = $env:CLAUDE_PROJECT_DIR
$env:TF_EXE = $FakeTf
[Console]::InputEncoding = [System.Text.Encoding]::GetEncoding(862)
try {
    foreach ($exe in $Exes.Keys) {
        $r = Invoke-Hook $exe (New-Payload $RoAscii)
        Check "$exe T1 read-only ASCII path -> tf called as 'checkout /noprompt <path>', exit 0, no output" `
            (($r.Exit -eq 0) -and $r.Log.Contains("checkout /noprompt $RoAscii") -and ($r.Out -eq '')) "exit=$($r.Exit) out=[$($r.Out)] log=[$($r.Log)]"

        $r = Invoke-Hook $exe (New-Payload $RoHebrew)
        Check "$exe T2 read-only non-ASCII path under CP 862 -> tf receives the correct path" `
            (($r.Exit -eq 0) -and $r.Log.Contains("checkout /noprompt $RoHebrew")) "exit=$($r.Exit) out=[$($r.Out)] log=[$($r.Log)]"

        $r = Invoke-Hook $exe (New-Payload $Rw)
        Check "$exe T3a writable file -> tf not called, exit 0" (($r.Exit -eq 0) -and ($r.Log -eq '') -and ($r.Out -eq '')) "exit=$($r.Exit) out=[$($r.Out)] log=[$($r.Log)]"

        $r = Invoke-Hook $exe (New-Payload $Missing)
        Check "$exe T3b file not yet existing -> tf not called, exit 0" (($r.Exit -eq 0) -and ($r.Log -eq '') -and ($r.Out -eq '')) "exit=$($r.Exit) out=[$($r.Out)] log=[$($r.Log)]"

        $r = Invoke-Hook $exe ''
        Check "$exe T3c empty stdin -> exit 0, no output" (($r.Exit -eq 0) -and ($r.Log -eq '') -and ($r.Out -eq '')) "exit=$($r.Exit) out=[$($r.Out)] log=[$($r.Log)]"

        # ---- per-project override (TF_EXE env still points at fake tf #1 throughout) ----
        $r = Invoke-Hook $exe (New-Payload $RoAscii) $Proj
        Check "$exe T12 project .claude\settings.local.json env.TF_EXE (quoted) beats TF_EXE env and settings.json" `
            (($r.Exit -eq 0) -and $r.Log.StartsWith("[TF2] checkout /noprompt $RoAscii")) "exit=$($r.Exit) out=[$($r.Out)] log=[$($r.Log)]"

        $r = Invoke-Hook $exe (New-Payload $RoAscii) $ProjShared
        Check "$exe T13 project .claude\settings.json env.TF_EXE is honored when no local file exists" `
            (($r.Exit -eq 0) -and $r.Log.StartsWith("[TF2] checkout")) "exit=$($r.Exit) out=[$($r.Out)] log=[$($r.Log)]"

        $r = Invoke-Hook $exe (New-Payload $RoAscii) $ProjStale
        Check "$exe T14 project setting pointing at a missing file falls through to TF_EXE env" `
            (($r.Exit -eq 0) -and ($r.Log.StartsWith("[5] checkout") -or $r.Log.StartsWith("[7] checkout"))) "exit=$($r.Exit) out=[$($r.Out)] log=[$($r.Log)]"

        $r = Invoke-Hook $exe (New-Payload $RoAscii) $ProjNoCfg
        Check "$exe T15 project without .claude folder uses TF_EXE env as before" `
            (($r.Exit -eq 0) -and ($r.Log.StartsWith("[5] checkout") -or $r.Log.StartsWith("[7] checkout"))) "exit=$($r.Exit) out=[$($r.Out)] log=[$($r.Log)]"

        $r = Invoke-Hook $exe (New-Payload $RoAscii -Cwd $Proj) ''
        Check "$exe T16 CLAUDE_PROJECT_DIR unset -> the payload's cwd locates the project settings" `
            (($r.Exit -eq 0) -and $r.Log.StartsWith("[TF2] checkout")) "exit=$($r.Exit) out=[$($r.Out)] log=[$($r.Log)]"

        Push-Location -LiteralPath $Proj
        try { $r = Invoke-Hook $exe (New-Payload $RoAscii) '' } finally { Pop-Location }
        Check "$exe T17 CLAUDE_PROJECT_DIR unset and no cwd in payload -> current directory locates the project settings" `
            (($r.Exit -eq 0) -and $r.Log.StartsWith("[TF2] checkout")) "exit=$($r.Exit) out=[$($r.Out)] log=[$($r.Log)]"
    }

    # ---- hooks.json command string ---------------------------------------------------------
    $hookCmd = (Get-Content -LiteralPath $HooksJson -Raw | ConvertFrom-Json).hooks.PreToolUse[0].hooks[0].command
    Check "T4a hooks.json launches Windows PowerShell (powershell, not pwsh) non-interactively" `
        (($hookCmd -match '^powershell(\.exe)? ') -and ($hookCmd -match '-NonInteractive') -and ($hookCmd -match '-NoProfile') -and ($hookCmd -match '-ExecutionPolicy Bypass')) $hookCmd

    $env:CLAUDE_PLUGIN_ROOT = $Plugin
    Set-ProjectDirEnv $ProjNoCfg
    if ($Bash) {
        Reset-Log
        $out = ((New-Payload $RoAscii) | & $Bash -c $hookCmd 2>&1 | Out-String).Trim(); $code = $LASTEXITCODE; $logText = Get-Log
        Check "T4b hooks.json command works when Git Bash runs it (CLAUDE_PLUGIN_ROOT expanded by sh)" `
            (($code -eq 0) -and $logText.Contains("checkout /noprompt $RoAscii") -and ($out -eq '')) "exit=$code out=[$out] log=[$logText]"
    } else { Skip 'T4b hooks.json command works when Git Bash runs it' 'Git Bash not installed' }

    $expanded = $hookCmd.Replace('${CLAUDE_PLUGIN_ROOT}', $Plugin)
    foreach ($exe in $Exes.Keys) {
        Reset-Log
        $out = ((New-Payload $RoAscii) | & $Exes[$exe] -NoProfile -Command $expanded 2>&1 | Out-String).Trim(); $code = $LASTEXITCODE; $logText = Get-Log
        Check "$exe T4c hooks.json command works when PowerShell runs it (no Git Bash fallback)" `
            (($code -eq 0) -and $logText.Contains("checkout /noprompt $RoAscii") -and ($out -eq '')) "exit=$code out=[$out] log=[$logText]"
    }
}
finally {
    [Console]::InputEncoding = $savedEnc
    $env:TF_EXE = $savedTf
    Set-ProjectDirEnv $savedProj
    Remove-Item Env:\CLAUDE_PLUGIN_ROOT -ErrorAction SilentlyContinue
}

# ---- shared resolver: skills/tfvc/scripts/Find-Tf.ps1 --------------------------------------
foreach ($exe in $Exes.Keys) {
    $got = Invoke-Resolver $exe @{ TF_EXE = "`"$FakeTf`""; PATH = $MinPath; CLAUDE_PROJECT_DIR = $ProjNoCfg }
    Check "$exe T5 TF_EXE wrapped in quotes -> unquoted existing path" ($got -eq $FakeTf) "got=[$got]"

    $got = Invoke-Resolver $exe @{ TF_EXE = $null; PATH = $MinPath; CLAUDE_PROJECT_DIR = $ProjNoCfg }
    if ($got -eq '') { Skip "$exe T6 real machine probe finds a TF.exe" 'no Visual Studio TF.exe on this machine' }
    else { Check "$exe T6 no TF_EXE, tf not on PATH, real Program Files -> finds an existing TF.exe" ((Test-Path -LiteralPath $got) -and ((Split-Path -Leaf $got) -ieq 'TF.exe')) "got=[$got]" }

    $got = Invoke-Resolver $exe @{ TF_EXE = $null; PATH = $MinPath; CLAUDE_PROJECT_DIR = $ProjNoCfg; ProgramFiles = $PfVs18; 'ProgramFiles(x86)' = $PfVs18 }
    Check "$exe T6a VS folder named '18' (not a year) is found by the default-layout probe" ($got -eq $Tf18) "got=[$got]"

    $got = Invoke-Resolver $exe @{ TF_EXE = $null; PATH = $MinPath; CLAUDE_PROJECT_DIR = $ProjNoCfg; ProgramFiles = $PfVs14; 'ProgramFiles(x86)' = $PfVs14 }
    Check "$exe T6b VS 2015 legacy layout (Microsoft Visual Studio 14.0\Common7\IDE) is found" ($got -eq $Tf14) "got=[$got]"

    if ($HaveMix) {
        $got = Invoke-Resolver $exe @{ TF_EXE = $null; PATH = $MinPath; CLAUDE_PROJECT_DIR = $ProjNoCfg; ProgramFiles = $PfMix; 'ProgramFiles(x86)' = $PfMix }
        Check "$exe T6c newest TF.exe file version wins (16.0 in the middle folder beats 15.0 in first and last)" ($got -eq $MixWant) "got=[$got]"
    } else { Skip "$exe T6c newest TF.exe file version wins" 'csc.exe not available to build versioned stubs' }

    $got = Invoke-Resolver $exe @{ TF_EXE = (Join-Path $S 'nope\TF.exe'); PATH = $MinPath; CLAUDE_PROJECT_DIR = $ProjNoCfg; ProgramFiles = $PfVs18; 'ProgramFiles(x86)' = $PfVs18 }
    Check "$exe T7 TF_EXE pointing at a missing file falls through to probing" ($got -eq $Tf18) "got=[$got]"

    $got = Invoke-Resolver $exe @{ TF_EXE = $null; PATH = $MinPath; CLAUDE_PROJECT_DIR = $ProjNoCfg; ProgramFiles = $PfEmpty; 'ProgramFiles(x86)' = $PfEmpty }
    Check "$exe T8 nothing installed anywhere -> returns nothing, no error output" ($got -eq '') "got=[$got]"

    $got = Invoke-Resolver $exe @{ TF_EXE = $FakeTf; CLAUDE_PROJECT_DIR = $Proj }
    Check "$exe T18 Resolve-TfExe prefers the project's settings.local.json over TF_EXE env" ($got -eq $FakeTf2) "got=[$got]"

    # ---- Find-Tf.ps1 run as a script (what the skill tells Claude to do) ----
    $r = Invoke-FindTf $exe @{ TF_EXE = $FakeTf; CLAUDE_PROJECT_DIR = $Proj } ''
    Check "$exe T20 Find-Tf.ps1 prints the resolved path (project override) and exits 0" (($r.Exit -eq 0) -and ($r.Out -eq $FakeTf2)) "exit=$($r.Exit) out=[$($r.Out)]"

    if ($HaveMix) {
        $r = Invoke-FindTf $exe @{ TF_EXE = $null; PATH = $MinPath; CLAUDE_PROJECT_DIR = $ProjNoCfg; ProgramFiles = $PfMix; 'ProgramFiles(x86)' = $PfMix } '-List'
        $rows = @($r.Out -split "`r?`n" | Where-Object { $_ -match '^\s*\d+\.\d+\.\d+\.\d+\s' })
        Check "$exe T21 Find-Tf.ps1 -List prints every TF.exe with its version, newest first, exit 0" `
            (($r.Exit -eq 0) -and ($rows.Count -eq 3) -and ($rows[0] -match '^\s*16\.0\.0\.0\s')) "exit=$($r.Exit) rows=$($rows.Count) out=[$($r.Out)]"
    } else { Skip "$exe T21 Find-Tf.ps1 -List prints versions" 'csc.exe not available to build versioned stubs' }

    $r = Invoke-FindTf $exe @{ TF_EXE = $null; PATH = $MinPath; CLAUDE_PROJECT_DIR = $ProjNoCfg; ProgramFiles = $PfEmpty; 'ProgramFiles(x86)' = $PfEmpty } ''
    Check "$exe T22 Find-Tf.ps1 with no TF.exe anywhere -> no output, exit 1" (($r.Exit -eq 1) -and ($r.Out -eq '')) "exit=$($r.Exit) out=[$($r.Out)]"
}

# ---- static checks ------------------------------------------------------------------------
foreach ($f in @($Hook, $FindTf)) {
    $name = Split-Path -Leaf $f
    if (Test-Path -LiteralPath $f) {
        $nonAscii = @([System.IO.File]::ReadAllBytes($f) | Where-Object { $_ -gt 0x7F }).Count
        Check "T10 $name is pure ASCII (safe for Windows PowerShell 5.1 without a BOM)" ($nonAscii -eq 0) "non-ASCII bytes=$nonAscii"
    } else { Check "T10 $name exists" $false "missing: $f" }
}
$hookText = Get-Content -LiteralPath $Hook -Raw
Check "T23 the hook loads Find-Tf.ps1 instead of carrying its own resolver (single implementation)" `
    (($hookText -match 'Find-Tf\.ps1') -and ($hookText -notmatch 'function\s+Resolve-TfExe')) "references Find-Tf.ps1=$($hookText -match 'Find-Tf\.ps1') defines Resolve-TfExe=$($hookText -match 'function\s+Resolve-TfExe')"

$vPlugin = (Get-Content -LiteralPath (Join-Path $Plugin '.claude-plugin\plugin.json') -Raw | ConvertFrom-Json).version
$vMarket = (Get-Content -LiteralPath (Join-Path $Repo '.claude-plugin\marketplace.json') -Raw | ConvertFrom-Json).plugins[0].version
$vLog    = [regex]::Match((Get-Content -LiteralPath (Join-Path $Repo 'CHANGELOG.md') -Raw), '## \[(\d+\.\d+\.\d+)\]').Groups[1].Value
Check "T11 plugin.json, marketplace.json and newest CHANGELOG entry agree on the version" (($vPlugin -eq $vMarket) -and ($vPlugin -eq $vLog)) "plugin=$vPlugin marketplace=$vMarket changelog=$vLog"

# ---- report -------------------------------------------------------------------------------
$Results | Format-Table -AutoSize -Wrap | Out-String -Width 220
$fail = @($Results | Where-Object Result -eq 'FAIL').Count
$skip = @($Results | Where-Object Result -eq 'SKIP').Count
"$(@($Results).Count) checks, $fail failed, $skip skipped"
exit $fail
