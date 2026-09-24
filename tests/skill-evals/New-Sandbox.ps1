# Creates a throwaway "LegacyBilling" TFVC project for one eval run: a fake TFS 2010 server-workspace layout
# (tracked files read-only) plus the fake tf.exe in tools\. Prints the project path.
#   powershell -File New-Sandbox.ps1 -Path <run-sandbox-dir> -Scenario commit|readonly|version -FakeTf <path\tf.exe>
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][ValidateSet('commit', 'readonly', 'version')][string]$Scenario,
    [Parameter(Mandatory = $true)][string]$FakeTf
)
$ErrorActionPreference = 'Stop'
$proj = Join-Path $Path 'LegacyBilling'
if (Test-Path -LiteralPath $proj) {
    Get-ChildItem -LiteralPath $proj -Recurse -File | ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item -LiteralPath $proj -Recurse -Force
}
New-Item -ItemType Directory -Path (Join-Path $proj 'Config') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $proj 'tools')  -Force | Out-Null

Set-Content -LiteralPath (Join-Path $proj 'LegacyBilling.sln') -Value @"
Microsoft Visual Studio Solution File, Format Version 11.00
# Visual Studio 2010
Project("{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}") = "LegacyBilling", "LegacyBilling.csproj", "{6C3E4B2A-0D1F-4E7B-9C51-2B8E3F1A7D42}"
EndProject
"@

$invoiceFixed = $Scenario -eq 'commit'
Set-Content -LiteralPath (Join-Path $proj 'Invoice.cs') -Value @"
using System;

namespace LegacyBilling
{
    public class Invoice
    {
        public decimal Net { get; set; }
        public decimal TaxRate { get; set; }

        public decimal Total()
        {
            $(if ($invoiceFixed) { 'return Math.Round(Net * (1 + TaxRate), 2, MidpointRounding.AwayFromZero); // bug 4532: bankers rounding lost cents' } else { 'return Math.Round(Net * (1 + TaxRate), 2);' })
        }
    }
}
"@

if ($Scenario -eq 'commit') {
    Set-Content -LiteralPath (Join-Path $proj 'TaxCalc.cs') -Value @"
using System;

namespace LegacyBilling
{
    public static class TaxCalc
    {
        public static decimal Vat(decimal net, decimal rate)
        {
            return Math.Round(net * rate, 2, MidpointRounding.AwayFromZero);
        }
    }
}
"@
}

Set-Content -LiteralPath (Join-Path $proj 'Config\App.config') -Value @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <appSettings>
    <add key="Environment" value="Production" />
    <add key="CommandTimeout" value="30" />
    <add key="RetryCount" value="3" />
  </appSettings>
  <connectionStrings>
    <add name="Billing" connectionString="Server=BILLDB01;Database=Billing;Integrated Security=true" />
  </connectionStrings>
</configuration>
"@

Copy-Item -LiteralPath $FakeTf -Destination (Join-Path $proj 'tools\tf.exe') -Force
Set-Content -LiteralPath (Join-Path $proj 'tools\tracked.txt') -Value "LegacyBilling.sln`r`nInvoice.cs`r`nConfig\App.config"
Set-Content -LiteralPath (Join-Path $proj 'tools\added.txt')   -Value ''
Remove-Item -LiteralPath (Join-Path $proj 'tools\tf-calls.log') -ErrorAction SilentlyContinue

# Server workspace: tracked files are read-only unless checked out. In the commit scenario Invoice.cs is
# already checked out (the user "fixed" it); TaxCalc.cs is new and untracked.
foreach ($rel in 'LegacyBilling.sln', 'Invoice.cs', 'Config\App.config') {
    (Get-Item -LiteralPath (Join-Path $proj $rel)).IsReadOnly = -not ($invoiceFixed -and $rel -eq 'Invoice.cs')
}
Write-Output $proj
