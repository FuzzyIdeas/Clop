param([switch]$Check)
$ErrorActionPreference = 'Stop'
try {
  $source = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'Bridge.cs')
  Add-Type -TypeDefinition $source -ReferencedAssemblies System.Windows.Forms,System.Drawing,System.Web.Extensions,System.Core,Microsoft.CSharp,Accessibility
  if ($Check) { Write-Output 'Windows bridge compiled successfully'; exit 0 }
  [ClopWindows.Bridge]::Run()
} catch {
  [Console]::Error.WriteLine($_.Exception.ToString())
  exit 1
}
