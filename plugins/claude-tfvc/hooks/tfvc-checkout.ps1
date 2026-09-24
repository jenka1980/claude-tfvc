# PreToolUse hook for Edit|Write: best-effort "tf checkout" of the target file.
#
# Design goals:
#   * SAFE everywhere - in non-TFVC / git projects this is a near-instant no-op.
#   * NEVER blocks an edit. We always exit 0 (allow); if checkout fails we let the
#     normal flow proceed so the user sees the real error rather than a blocked tool.
#   * Only acts when the target file is READ-ONLY, which is TFVC's "not checked out"
#     signal. Normal (writable) files are skipped instantly.
#   * Runs on Windows PowerShell 5.1 (built into every Windows) as well as PowerShell 7.
#     Keep this file pure ASCII: 5.1 reads BOM-less files in the ANSI code page.
#   * tf.exe resolution lives in ..\skills\tfvc\scripts\Find-Tf.ps1, shared with the skill
#     and /tf-select. It is loaded only once a read-only file is actually seen, so the
#     common no-op path never pays for it.

$ErrorActionPreference = 'SilentlyContinue'

try {
    # Claude Code writes the payload as UTF-8; read it as such whatever the console code page is.
    $stdin = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
    $payload = $stdin.ReadToEnd() | ConvertFrom-Json
    $file = $payload.tool_input.file_path

    if ($file -and (Test-Path -LiteralPath $file) -and (Get-Item -LiteralPath $file).IsReadOnly) {
        . (Join-Path $PSScriptRoot '..\skills\tfvc\scripts\Find-Tf.ps1')

        # Project root: CLAUDE_PROJECT_DIR (exported to hooks), else the payload's cwd, else the current directory.
        $projectDir = $env:CLAUDE_PROJECT_DIR
        if (-not $projectDir) { $projectDir = $payload.cwd }
        $tf = Resolve-TfExe -ProjectDir $projectDir

        # /noprompt: fail fast instead of opening a credential dialog behind the terminal.
        if ($tf) { & $tf checkout /noprompt $file 2>$null | Out-Null }
    }
}
catch {
    # Swallow everything - the hook must never break editing.
}

exit 0
