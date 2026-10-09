param([string]$Image)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,WindowsBase
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ClopExplorerSource {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
}
'@
[ClopExplorerSource]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$shell = New-Object -ComObject Shell.Application
$before = @($shell.Windows() | ForEach-Object { $_.HWND })
$folder = Split-Path -Parent $Image
$filename = Split-Path -Leaf $Image
$owned = $null
try {
  Start-Process explorer.exe -ArgumentList "/n,`"$folder`""
  $deadline = [DateTime]::UtcNow.AddSeconds(25)
  do {
    foreach ($candidate in $shell.Windows()) {
      try { if ($before -notcontains $candidate.HWND -and $candidate.Document.Folder.Self.Path -eq $folder) { $owned = $candidate; break } } catch {}
    }
    if ($null -eq $owned) { Start-Sleep -Milliseconds 250 }
  } while ($null -eq $owned -and [DateTime]::UtcNow -lt $deadline)
  if ($null -eq $owned) { throw 'The task-owned Explorer window did not open' }
  $hwnd = [IntPtr]([long]$owned.HWND)
  [ClopExplorerSource]::SetWindowPos($hwnd,[IntPtr]::Zero,60,60,800,600,0) | Out-Null
  [ClopExplorerSource]::SetForegroundWindow($hwnd) | Out-Null
  $owned.Document.CurrentViewMode = 4
  $file = $owned.Document.Folder.ParseName($filename)
  $owned.Document.SelectItem($file,29)
  Start-Sleep -Milliseconds 1000
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  $listCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::ListItem)
  $item = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,$listCondition) | Where-Object { $_.Current.Name -eq $file.Name -or $_.Current.Name -eq $filename -or $_.Current.Name -eq [IO.Path]::GetFileNameWithoutExtension($filename) } | Select-Object -First 1
  if ($null -eq $item) { throw 'The supported image item was not exposed by Explorer accessibility' }
  $rect = $item.Current.BoundingRectangle
  $editCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::Edit)
  $search = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,$editCondition) | Where-Object { $_.Current.Name -like 'Search*' } | Select-Object -First 1
  if ($null -eq $search) { throw 'Explorer search field was not exposed' }
  $searchRect = $search.Current.BoundingRectangle
  @{ window = [long]$hwnd; image = @{ x = [int]($rect.X + 30); y = [int]($rect.Y + $rect.Height/2) }; text = @{ x = [int]($searchRect.X + 30); y = [int]($searchRect.Y + $searchRect.Height/2) }; title = @{x = 260; y = 72}; blank = @{x = 740; y = 540}; resize = @{x = 857; y = 657} } | ConvertTo-Json -Compress
  # Keep only this Explorer window alive until Node closes its stdin.
  [Console]::In.ReadLine() | Out-Null
} finally {
  if ($null -ne $owned) { $owned.Quit(); [Runtime.InteropServices.Marshal]::ReleaseComObject($owned) | Out-Null }
  [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
}
