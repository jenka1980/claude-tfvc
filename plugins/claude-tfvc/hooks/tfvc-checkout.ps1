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
#
# Dot-sourcing this file (". .\tfvc-checkout.ps1") only defines the functions and does
# not run the hook body; the test harness uses that to exercise Resolve-TfExe directly.

$ErrorActionPreference = 'SilentlyContinue'

function Get-TfFileVersion {
    param([System.IO.FileInfo]$File)
    $v = $File.VersionInfo
    New-Object System.Version($v.FileMajorPart, $v.FileMinorPart, $v.FileBuildPart, $v.FilePrivatePart)
}

function Find-TfInVisualStudio {
    # Every TF.exe inside a Visual Studio install we can find, newest file version first.
    $bases = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | Select-Object -Unique
    $patterns = @()

    # vswhere ships with every VS 2017+ installer and also knows installs outside Program Files.
    foreach ($base in $bases) {
        $vswhere = Join-Path $base 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (Test-Path -LiteralPath $vswhere) {
            foreach ($root in @(& $vswhere -all -prerelease -products * -property installationPath 2>$null)) {
                if ($root) { $patterns += Join-Path $root 'Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\TF.exe' }
            }
            break
        }
    }

    # Default layouts: VS 2017+ (the folder is a year like 2022 or a major version like 18; any edition,
    # including BuildTools and TeamExplorer) and VS 2010-2015 (Microsoft Visual Studio <n>.0).
    foreach ($base in $bases) {
        $patterns += Join-Path $base 'Microsoft Visual Studio\*\*\Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\TF.exe'
        $patterns += Join-Path $base 'Microsoft Visual Studio *.0\Common7\IDE\TF.exe'
    }

    $files = foreach ($pattern in $patterns) { Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue }
    @($files) |
        Sort-Object -Property FullName -Unique |
        Sort-Object -Property @{ Expression = { Get-TfFileVersion $_ } } -Descending
}

function Resolve-TfExe {
    # Resolution order (keep in sync with SKILL.md and README):
    #   TF_EXE env var -> tf.exe on PATH -> vswhere -> default Visual Studio folders.
    $tf = "$env:TF_EXE".Trim().Trim('"').Trim("'")
    if ($tf) {
        if (Test-Path -LiteralPath $tf -PathType Leaf) { return $tf }
        $cmd = Get-Command $tf -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and $cmd.Source) { return $cmd.Source }
    }
    $cmd = Get-Command tf.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    $hit = Find-TfInVisualStudio | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        # Claude Code writes the payload as UTF-8; read it as such whatever the console code page is.
        $stdin = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
        $payload = $stdin.ReadToEnd() | ConvertFrom-Json
        $file = $payload.tool_input.file_path

        if ($file -and (Test-Path -LiteralPath $file) -and (Get-Item -LiteralPath $file).IsReadOnly) {
            $tf = Resolve-TfExe
            # /noprompt: fail fast instead of opening a credential dialog behind the terminal.
            if ($tf) { & $tf checkout /noprompt $file 2>$null | Out-Null }
        }
    }
    catch {
        # Swallow everything - the hook must never break editing.
    }
    exit 0
}
