# Compiles tf.cs into a fake tf.exe with the given file version, using the csc.exe that ships with
# .NET Framework 4.x (present on every Windows 10/11).
#   powershell -File Build-FakeTf.ps1 -OutFile C:\path\tools\tf.exe [-FileVersion 15.0.0.0]
param(
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$FileVersion = '15.0.0.0'
)
$ErrorActionPreference = 'Stop'
$csc = @("$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe", "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe") |
       Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { throw 'csc.exe (.NET Framework 4.x) not found' }
$dir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$ver = Join-Path $env:TEMP ('fake-tf-ver-' + [guid]::NewGuid().ToString('N') + '.cs')
Set-Content -LiteralPath $ver -Value "[assembly: System.Reflection.AssemblyFileVersion(`"$FileVersion`")]"
try {
    & $csc /nologo /target:exe "/out:$OutFile" (Join-Path $PSScriptRoot 'tf.cs') $ver
    if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }
}
finally { Remove-Item -LiteralPath $ver -ErrorAction SilentlyContinue }
Write-Output $OutFile
