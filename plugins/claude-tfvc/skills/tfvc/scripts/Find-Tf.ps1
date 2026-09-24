<#
.SYNOPSIS
  Finds the TF.exe (TFVC command-line client) a project should use, or lists every TF.exe on the machine.

.DESCRIPTION
  Resolution order (the auto-checkout hook dot-sources this file, so it uses exactly the same order):
    1. env.TF_EXE in <project>\.claude\settings.local.json, then <project>\.claude\settings.json (written by /tf-select)
    2. the TF_EXE environment variable (machine-wide default)
    3. tf.exe on PATH
    4. vswhere.exe (ships with any VS 2017+ installer; also finds installs outside Program Files)
    5. default Visual Studio folders under Program Files / Program Files (x86): VS 2017+ (any version or edition
       folder) and VS 2010-2015 (Microsoft Visual Studio <n>.0\Common7\IDE)
  Configured values (1-2) count only if the file exists (surrounding quotes are tolerated); stale ones fall
  through. When several TF.exe exist (4-5), the newest file version wins.

  Runs on Windows PowerShell 5.1 as well as PowerShell 7. Keep this file pure ASCII: 5.1 reads BOM-less files
  in the ANSI code page. Dot-sourcing it (". Find-Tf.ps1") only defines the functions and prints nothing.

.PARAMETER List
  Print every TF.exe found (Visual Studio installs and PATH) with its file version, newest first.
.PARAMETER ProjectDir
  Project root whose .claude\settings*.json are consulted. Default: CLAUDE_PROJECT_DIR, else the current directory.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File Find-Tf.ps1          # prints the path to use; exit 1 if none
  powershell -NoProfile -ExecutionPolicy Bypass -File Find-Tf.ps1 -List    # table: Version  Path
#>
param([switch]$List, [string]$ProjectDir)

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

function Resolve-TfCandidate {
    # Normalise a configured value (TF_EXE or a project setting): strip quotes, then accept it
    # only if it is an existing file or a command name resolvable on PATH. Stale values fall through.
    param([string]$Value)
    $v = "$Value".Trim().Trim('"').Trim("'")
    if (-not $v) { return $null }
    if (Test-Path -LiteralPath $v -PathType Leaf) { return $v }
    $cmd = Get-Command $v -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    return $null
}

function Get-ProjectTfSetting {
    # env.TF_EXE from the project's Claude Code settings (written by /tf-select):
    # .claude\settings.local.json wins over .claude\settings.json, like Claude Code's own precedence.
    param([string]$ProjectDir)
    if (-not $ProjectDir) { return $null }
    foreach ($name in 'settings.local.json', 'settings.json') {
        $file = Join-Path (Join-Path $ProjectDir '.claude') $name
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            $value = (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).env.TF_EXE
            if ($value) { return $value }
        }
    }
    return $null
}

function Resolve-TfExe {
    # The one resolution order (described in SKILL.md and README):
    #   project .claude\settings*.json env.TF_EXE -> TF_EXE env var -> tf.exe on PATH -> vswhere -> default VS folders.
    param([string]$ProjectDir)
    if (-not $ProjectDir) { $ProjectDir = $env:CLAUDE_PROJECT_DIR }
    if (-not $ProjectDir) { $ProjectDir = (Get-Location).Path }

    $tf = Resolve-TfCandidate (Get-ProjectTfSetting $ProjectDir)
    if ($tf) { return $tf }
    $tf = Resolve-TfCandidate $env:TF_EXE
    if ($tf) { return $tf }
    $cmd = Get-Command tf.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    $hit = Find-TfInVisualStudio | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

function Get-TfCandidateList {
    # Every TF.exe on the machine (Visual Studio installs plus PATH), newest file version first.
    $files = @(Find-TfInVisualStudio)
    $onPath = Get-Command tf.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath -and $onPath.Source) { $files += Get-Item -LiteralPath $onPath.Source }
    $files |
        Sort-Object -Property FullName -Unique |
        Sort-Object -Property @{ Expression = { Get-TfFileVersion $_ } } -Descending |
        ForEach-Object { [pscustomobject]@{ Version = (Get-TfFileVersion $_); Path = $_.FullName } }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($List) {
        $rows = @(Get-TfCandidateList)
        if ($rows.Count -eq 0) { exit 1 }
        Write-Output (($rows | Format-Table -AutoSize | Out-String -Width 4096).TrimEnd())
        exit 0
    }
    $tf = Resolve-TfExe -ProjectDir $ProjectDir
    if ($tf) { Write-Output $tf; exit 0 }
    exit 1
}
