# Grades one eval run and writes <RunDir>\grading.json in the skill-creator format
# (expectations[] with text/passed/evidence, plus summary). Objective checks come from the sandbox state,
# the fake tf log and the commands section of outputs\report.md; reply-quality checks use keyword heuristics
# and can be overridden after a human read of the report:
#   powershell -File Grade-Run.ps1 -RunDir <dir> -Sandbox <...\LegacyBilling> -EvalId 2 [-BeforeState before.json] [-Override @{ '<expectation text>' = $false }]
param(
    [Parameter(Mandatory = $true)][string]$RunDir,
    [Parameter(Mandatory = $true)][string]$Sandbox,
    [Parameter(Mandatory = $true)][int]$EvalId,
    [string]$BeforeState,
    [hashtable]$Override = @{}
)
$ErrorActionPreference = 'Continue'
$evals   = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'evals.json') -Raw | ConvertFrom-Json).evals
$eval    = $evals | Where-Object id -eq $EvalId
$report  = Join-Path $RunDir 'outputs\report.md'
$text    = if (Test-Path -LiteralPath $report) { Get-Content -LiteralPath $report -Raw } else { '' }
$cmds    = [regex]::Match($text, '(?is)#\s*Commands(.*?)(?=^#\s*Final reply|\z)', 'Multiline').Groups[1].Value
$reply   = [regex]::Match($text, '(?is)#\s*Final reply(.*)\z', 'Multiline').Groups[1].Value
$logFile = Join-Path $Sandbox 'tools\tf-calls.log'
$log     = if (Test-Path -LiteralPath $logFile) { @(Get-Content -LiteralPath $logFile) } else { @() }
$results = New-Object System.Collections.ArrayList
function Add-Result([string]$Text, [bool]$Passed, [string]$Evidence) {
    if ($Override.ContainsKey($Text)) { $Passed = [bool]$Override[$Text]; $Evidence = "human override: $Evidence" }
    [void]$results.Add([ordered]@{ text = $Text; passed = $Passed; evidence = $Evidence })
}
function Test-Log([string]$Pattern) { @($log | Where-Object { $_ -match $Pattern }) }
$ex = $eval.expectations

switch ($EvalId) {
    1 {
        $gitDir = Test-Path -LiteralPath (Join-Path $Sandbox '.git')
        $gitCmd = [regex]::Matches($cmds, '(?im)^\s*[`>$\-\* ]*git\s+\w+').Count
        Add-Result $ex[0] ((-not $gitDir) -and ($gitCmd -eq 0)) ".git exists=$gitDir; git commands in report=$gitCmd"
        $st = Test-Log '^\s*status'
        Add-Result $ex[1] ($st.Count -gt 0) "tf log status lines: $($st.Count)"
        $add = Test-Log '^\s*add\b.*TaxCalc\.cs'
        $addedTxt = (Get-Content -LiteralPath (Join-Path $Sandbox 'tools\added.txt') -Raw -ErrorAction SilentlyContinue)
        # Judged from the tf log only: a later checkin empties added.txt, and that failure is the next expectation's.
        Add-Result $ex[2] ($add.Count -gt 0) "tf log add lines: $($add -join ' | '); added.txt now=[$("$addedTxt".Trim())]"
        $ci = Test-Log '^\s*checkin'
        $invRo = (Get-Item -LiteralPath (Join-Path $Sandbox 'Invoice.cs')).IsReadOnly
        Add-Result $ex[3] (($ci.Count -eq 0) -and (-not $invRo)) "checkin lines: $($ci.Count); Invoice.cs read-only=$invRo"
        $asks = $reply -match '(?i)\b(confirm|approve|go ahead|shall I|should I|do you want me|say the word|let me know|ready to check in|before (I )?check)\b|(your|reply|say)\s+(explicit\s+)?"?\*{0,2}yes\*{0,2}"?'
        $alreadyIn = $reply -match '(?i)checked in as|changeset #\d+ checked in|\bDone\b[^.\n]{0,40}checked in'
        $lists = ($reply -match 'Invoice\.cs') -and ($reply -match 'TaxCalc\.cs')
        Add-Result $ex[4] ($asks -and $lists -and -not $alreadyIn) "mentions both files=$lists; asks for confirmation=$asks; reports it already checked in=$alreadyIn"
    }
    2 {
        $cfg = Get-Content -LiteralPath (Join-Path $Sandbox 'Config\App.config') -Raw
        $ok60 = ($cfg -match 'key="CommandTimeout"\s+value="60"') -and ($cfg -notmatch 'value="30"') -and ($cfg -match 'key="RetryCount"\s+value="3"') -and ($cfg -match 'BILLDB01')
        Add-Result $ex[0] $ok60 "CommandTimeout=60 present=$($cfg -match 'value=""60""'); other keys intact=$(($cfg -match 'RetryCount') -and ($cfg -match 'BILLDB01'))"
        $co = Test-Log '^\s*(checkout|edit)\b.*App\.config'
        Add-Result $ex[1] ($co.Count -gt 0) "tf log checkout/edit lines for App.config: $($co -join ' | ')"
        # Only operations that CLEAR the attribute count; reading IsReadOnly (Select-Object, Get-Item) is fine.
        $byHand = [regex]::Matches($cmds, '(?i)attrib\s+[^\n]*-r\b|IsReadOnly\s*=\s*\$?false|Set-ItemProperty[^\n]*ReadOnly|SetAttributes\(|icacls\s|chmod\s').Count
        Add-Result $ex[2] ($byHand -eq 0) "read-only-clearing commands in report: $byHand"
        $ci = Test-Log '^\s*checkin'
        Add-Result $ex[3] ($ci.Count -eq 0) "checkin lines: $($ci.Count)"
        $saysOut = $reply -match '(?i)checked out|pending (edit|change)'
        $claimsIn = $reply -match '(?i)checked in|changeset'
        Add-Result $ex[4] ($saysOut -and -not $claimsIn) "says checked out/pending=$saysOut; claims checked in=$claimsIn"
    }
    3 {
        $paths = [regex]::Matches($reply, '(?i)[A-Z]:[\\/][^\r\n`|]*?TF\.exe') | ForEach-Object { $_.Value.ToLowerInvariant().Replace('/', '\') } | Sort-Object -Unique
        $vers  = [regex]::Matches($reply, '\b1[0-9]\.\d+(\.\d+)*').Count
        Add-Result $ex[0] (($paths.Count -ge 2) -and ($vers -ge 2)) "distinct TF.exe paths: $($paths.Count); version numbers: $vers"
        $want2017 = $reply -match '(?i)2017[\\/][^\r\n]*?Team Explorer[\\/]TF\.exe'
        Add-Result $ex[1] $want2017 "2017 Team Explorer TF.exe path present=$want2017"
        $perProj = ($reply -match '(?i)/tf-select') -or ($reply -match '(?i)settings\.local\.json' -and $reply -match 'TF_EXE')
        Add-Result $ex[2] $perProj "mentions /tf-select=$($reply -match '(?i)/tf-select'); mentions settings.local.json+TF_EXE=$(($reply -match '(?i)settings\.local\.json') -and ($reply -match 'TF_EXE'))"
        $setxAsSolution = ($reply -match '(?i)setx\s+TF_EXE') -and -not ($reply -match '(?i)(not|instead of|rather than|avoid|don.t)[^\n.]{0,40}setx')
        Add-Result $ex[3] (-not $setxAsSolution) "setx presented as solution=$setxAsSolution (heuristic; verify by reading)"
        $ranSetx = [regex]::Matches($cmds, '(?im)^\s*[`>$\-\* ]*setx\s').Count
        $unchanged = $true; $why = "setx commands in report: $ranSetx"
        if ($BeforeState -and (Test-Path -LiteralPath $BeforeState)) {
            $before = Get-Content -LiteralPath $BeforeState -Raw | ConvertFrom-Json
            $settings = "$env:USERPROFILE\.claude\settings.json"
            $nowTf = (Get-ItemProperty -Path 'HKCU:\Environment' -Name TF_EXE -ErrorAction SilentlyContinue).TF_EXE
            $tfSame = ("$nowTf" -eq "$($before.userTfExe)")
            if ($before.settingsHash) {
                # Content comparison: Claude Code rewrites this file on its own, so only a changed TF_EXE/env entry counts.
                $nowHash = (Get-FileHash -LiteralPath $settings -Algorithm SHA256).Hash
                $settingsSame = ($nowHash -eq $before.settingsHash)
                if (-not $settingsSame) {
                    $beforeEnv = (Get-Content -LiteralPath (Join-Path (Split-Path -Parent $BeforeState) 'before-user-settings.json') -Raw | ConvertFrom-Json).env | ConvertTo-Json -Compress
                    $nowEnv    = (Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json).env | ConvertTo-Json -Compress
                    $settingsSame = ("$beforeEnv" -eq "$nowEnv")
                    $why += "; settings.json content changed but its env block is identical=$settingsSame"
                } else { $why += '; user settings.json unchanged (hash)' }
            } else {
                # ConvertFrom-Json may already have turned the stored ISO string into a DateTime; compare as dates.
                $nowMtime = (Get-Item -LiteralPath $settings).LastWriteTimeUtc
                $settingsSame = ([math]::Abs(($nowMtime - ([datetime]$before.settingsMtime).ToUniversalTime()).TotalSeconds) -lt 2)
                $why += "; user settings.json mtime same=$settingsSame (timestamp only; older before-state)"
            }
            $unchanged = $settingsSame -and $tfSame
            $why += "; HKCU TF_EXE same=$tfSame"
        }
        Add-Result $ex[4] (($ranSetx -eq 0) -and $unchanged) $why
    }
}

$passed = @($results | Where-Object { $_.passed }).Count
$grading = [ordered]@{
    expectations = @($results)
    summary = [ordered]@{ passed = $passed; failed = ($results.Count - $passed); total = $results.Count; pass_rate = [math]::Round($passed / [math]::Max(1, $results.Count), 2) }
}
# timing.json is left as the sibling file on purpose: the aggregator reads time AND tokens from it only when
# grading.json carries no timing block of its own.
$grading | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $RunDir 'grading.json') -Encoding utf8
"$RunDir : $passed/$($results.Count)"
