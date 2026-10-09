param([long]$Window, [int]$X, [int]$Y, [int]$MoveX = 90, [int]$MoveY = 40, [int]$Hold = 600, [switch]$Escape)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ClopDragGesture {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
}
'@
[ClopDragGesture]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
[ClopDragGesture]::SetWindowPos([IntPtr]$Window, [IntPtr]::Zero, 60, 60, 0, 0, 5) | Out-Null
[ClopDragGesture]::SetForegroundWindow([IntPtr]$Window) | Out-Null
[ClopDragGesture]::SetCursorPos($X, $Y) | Out-Null
Start-Sleep -Milliseconds 150
try {
  [ClopDragGesture]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
  Start-Sleep -Milliseconds 300
  [ClopDragGesture]::SetCursorPos($X + $MoveX, $Y + $MoveY) | Out-Null
  Start-Sleep -Milliseconds $Hold
  if ($Escape) {
    [ClopDragGesture]::keybd_event(27,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 300
    [ClopDragGesture]::keybd_event(27,0,2,[UIntPtr]::Zero)
    [ClopDragGesture]::SetCursorPos($X + $MoveX + 60, $Y + $MoveY) | Out-Null
    Start-Sleep -Milliseconds 500
  }
} finally {
  [ClopDragGesture]::keybd_event(27,0,2,[UIntPtr]::Zero)
  [ClopDragGesture]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
}
