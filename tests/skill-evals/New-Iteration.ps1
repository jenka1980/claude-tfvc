# Prepares one eval iteration: builds the fake tf.exe if needed, creates a sandbox for every eval x configuration,
# writes eval_metadata.json per eval (viewer format) and before-state.json (machine state that must not change),
# and prints the filled-in prompt for each run so the subagents can be dispatched.
#   powershell -File New-Iteration.ps1 -Iteration 1 [-Configs with_skill,without_skill]
param(
    [Parameter(Mandatory = $true)][int]$Iteration,
    [string[]]$Configs = @('with_skill', 'without_skill'),
    [int[]]$EvalIds = @()          # empty = every eval in evals.json
)
$ErrorActionPreference = 'Stop'
$root   = $PSScriptRoot
$ws     = Join-Path $root "workspace\iteration-$Iteration"
$fakeTf = Join-Path $root 'fake-tf\bin\tf.exe'
if (-not (Test-Path -LiteralPath $fakeTf)) { & (Join-Path $root 'fake-tf\Build-FakeTf.ps1') -OutFile $fakeTf | Out-Null }
New-Item -ItemType Directory -Path $ws -Force | Out-Null

# Machine state the runs must not change. The user settings file is snapshotted by content (hash + copy), not by
# timestamp: Claude Code itself rewrites that file during a session, so mtime alone cannot be attributed to a run.
$settings = Join-Path $env:USERPROFILE '.claude\settings.json'
$hasSettings = Test-Path -LiteralPath $settings
if ($hasSettings) { Copy-Item -LiteralPath $settings -Destination (Join-Path $ws 'before-user-settings.json') -Force }
[ordered]@{
    settingsHash  = $(if ($hasSettings) { (Get-FileHash -LiteralPath $settings -Algorithm SHA256).Hash } else { '' })
    settingsMtime = $(if ($hasSettings) { (Get-Item -LiteralPath $settings).LastWriteTimeUtc.ToString('o') } else { '' })
    userTfExe     = "$((Get-ItemProperty -Path 'HKCU:\Environment' -Name TF_EXE -ErrorAction SilentlyContinue).TF_EXE)"
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ws 'before-state.json') -Encoding utf8

# Layout expected by the skill-creator's aggregate_benchmark.py and eval viewer:
#   iteration-N\eval-<id>-<name>\eval_metadata.json
#   iteration-N\eval-<id>-<name>\<config>\run-1\{outputs\report.md, sandbox\, run.json, timing.json, grading.json, eval_metadata.json}
$evals = (Get-Content -LiteralPath (Join-Path $root 'evals.json') -Raw | ConvertFrom-Json).evals
if ($EvalIds.Count -gt 0) { $evals = $evals | Where-Object { $EvalIds -contains $_.id } }
foreach ($e in $evals) {
    $evalDir = Join-Path $ws "eval-$($e.id)-$($e.name)"
    New-Item -ItemType Directory -Path $evalDir -Force | Out-Null
    foreach ($cfg in $Configs) {
        $runDir  = Join-Path (Join-Path $evalDir $cfg) 'run-1'
        $sandbox = Join-Path $runDir 'sandbox'
        New-Item -ItemType Directory -Path (Join-Path $runDir 'outputs') -Force | Out-Null
        $proj = & (Join-Path $root 'New-Sandbox.ps1') -Path $sandbox -Scenario $e.scenario -FakeTf $fakeTf
        $prompt = $e.prompt.Replace('{sandbox}', $sandbox)
        $meta = [ordered]@{ eval_id = $e.id; eval_name = $e.name; prompt = $prompt; assertions = @($e.expectations) } | ConvertTo-Json -Depth 4
        if ($cfg -eq $Configs[0]) { Set-Content -LiteralPath (Join-Path $evalDir 'eval_metadata.json') -Value $meta -Encoding utf8 }
        Set-Content -LiteralPath (Join-Path $runDir 'eval_metadata.json') -Value $meta -Encoding utf8
        [ordered]@{ eval_id = $e.id; eval_name = $e.name; configuration = $cfg; scenario = $e.scenario; sandbox = $sandbox; project = $proj; prompt = $prompt } |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $runDir 'run.json') -Encoding utf8
        "=== $($e.name) / $cfg ==="
        "run dir : $runDir"
        "project : $proj"
        "prompt  : $prompt"
        ''
    }
}
