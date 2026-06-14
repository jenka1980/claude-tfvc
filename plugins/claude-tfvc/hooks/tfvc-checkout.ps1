# PreToolUse hook for Edit|Write: best-effort `tf checkout` of the target file.
#
# Design goals:
#   * SAFE everywhere — in non-TFVC / git projects this is a near-instant no-op.
#   * NEVER blocks an edit. We always exit 0 (allow); if checkout fails we let the
#     normal flow proceed so the user sees the real error rather than a blocked tool.
#   * Only acts when the target file is READ-ONLY, which is TFVC's "not checked out"
#     signal. Normal (writable) files are skipped instantly.

$ErrorActionPreference = 'SilentlyContinue'

try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $file = $payload.tool_input.file_path

    if ($file -and (Test-Path -LiteralPath $file) -and (Get-Item -LiteralPath $file).IsReadOnly) {

        # Resolve tf.exe: TF_EXE env var -> PATH -> common Visual Studio install paths.
        $tf = $env:TF_EXE
        if (-not $tf) {
            $cmd = Get-Command tf.exe -ErrorAction SilentlyContinue
            if ($cmd) { $tf = $cmd.Source }
        }
        if (-not $tf) {
            $bases = @(${env:ProgramFiles}, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
            foreach ($base in $bases) {
                foreach ($year in '2022', '2019', '2017') {
                    $glob = Join-Path $base "Microsoft Visual Studio\$year\*\Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\TF.exe"
                    $hit = Get-ChildItem -Path $glob -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($hit) { $tf = $hit.FullName; break }
                }
                if ($tf) { break }
            }
        }

        if ($tf) { & $tf checkout $file 2>$null | Out-Null }
    }
}
catch {
    # Swallow everything — the hook must never break editing.
}

exit 0
