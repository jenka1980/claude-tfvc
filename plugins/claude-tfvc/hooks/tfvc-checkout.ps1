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
