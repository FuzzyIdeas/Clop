using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Accessibility;

namespace ClopWindows {
  // Windows PowerShell 5.1 runs this helper on an STA thread. No runtime installation needed.
  public static class Bridge {
    [DllImport("user32.dll")] static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point point);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder name, int length);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wparam, IntPtr lparam, uint flags, uint timeout, out IntPtr result);
    [DllImport("oleacc.dll")] static extern int AccessibleObjectFromPoint(Point point, out IAccessible accessible, [MarshalAs(UnmanagedType.Struct)] out object child);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    delegate IntPtr MouseCallback(int code, IntPtr message, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] struct MouseData { public Point Point; public uint Mouse, Flags, Time; public UIntPtr Extra; }
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int type, MouseCallback callback, IntPtr module, uint thread);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
    delegate void WinEventCallback(IntPtr hook, uint eventType, IntPtr window, int objectId, int childId, uint thread, uint time);
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr module, WinEventCallback callback, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr hook);
    static readonly WinEventCallback DragEvents = OnDragEvent;
    static readonly MouseCallback MouseEvents = OnMouseEvent;
    sealed class Press { public Point Point; public IntPtr Window; public bool Down; }
    static readonly ConcurrentQueue<Press> Presses = new ConcurrentQueue<Press>();
    static readonly HashSet<long> OwnWindows = new HashSet<long>();
    static readonly ConcurrentQueue<string> Commands = new ConcurrentQueue<string>();
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    static volatile bool Ended;
    static uint Sequence;
    static readonly string ClipboardOwner = Guid.NewGuid().ToString("N");
    static bool Announced, Eligible, DetectDrag = true;
    static Point Start;
    static string[] DragPaths = new string[0];
    static readonly HashSet<string> Extensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { ".png", ".jpg", ".jpeg", ".webp", ".gif", ".avif", ".tif", ".tiff" };
    static void Emit(object value) { Console.WriteLine(Json.Serialize(value)); Console.Out.Flush(); }
    public static void Run() {
      SetProcessDpiAwarenessContext(new IntPtr(-4));
      // Electron pipes UTF-8 JSON. Windows PowerShell's inherited console code page varies
      // by machine, so read and write the pipe streams explicitly to preserve file names.
      Console.SetIn(new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false)));
      Console.SetOut(new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true });
      Sequence = GetClipboardSequenceNumber();
      var reader = new Thread(() => { string line; while ((line = Console.ReadLine()) != null) Commands.Enqueue(line); Ended = true; });
      reader.IsBackground = true; reader.Start();
      var timer = new System.Windows.Forms.Timer { Interval = 100 };
      timer.Tick += (sender, args) => {
        if (Ended) { timer.Stop(); Application.ExitThread(); return; }
        string line;
        while (Commands.TryDequeue(out line)) Handle(line);
        uint next = GetClipboardSequenceNumber();
        if (next != Sequence) {
          Sequence = next;
          try {
            var contents = Clipboard.GetDataObject();
            // OLE can bump the sequence again when delayed clipboard formats render. Tag ownership
            // explicitly rather than relying only on the sequence captured by SetDataObject.
            if (contents != null && Convert.ToString(contents.GetData("ClopWindows.Owner")) == ClipboardOwner) return;
            var paths = new List<string>();
            if (Clipboard.ContainsFileDropList()) foreach (string file in Clipboard.GetFileDropList()) if (Extensions.Contains(Path.GetExtension(file))) paths.Add(file);
            Emit(new { type = "clipboard", sequence = next, paths = paths.ToArray() });
          } catch { /* A different app may temporarily hold the clipboard. Retry on its next change. */ }
        }
        DetectImageDrag();
      };
      // Capture the original press before the cursor leaves the item. The mouse hook only
      // queues coordinates; COM/accessibility work stays outside the input callback.
      var mouseHook = SetWindowsHookEx(14, MouseEvents, GetModuleHandle(null), 0);
      var hook = SetWinEventHook(0x000F, 0x000F, IntPtr.Zero, DragEvents, 0, 0, 2);
      timer.Start(); Emit(new { type = "ready", sequence = Sequence }); Application.Run(); timer.Dispose();
      if (hook != IntPtr.Zero) UnhookWinEvent(hook);
      if (mouseHook != IntPtr.Zero) UnhookWindowsHookEx(mouseHook);
    }
    static void Handle(string line) {
      string id = null;
      try {
        var command = Json.Deserialize<Dictionary<string, object>>(line);
        id = Convert.ToString(command["id"]);
        string type = Convert.ToString(command["type"]);
        if (type == "settings") {
          DetectDrag = Convert.ToBoolean(command["explorerDrag"]);
          if (!DetectDrag) FinishDrag();
          if (command.ContainsKey("ownWindows")) { OwnWindows.Clear(); foreach (object window in (System.Collections.IEnumerable)command["ownWindows"]) OwnWindows.Add(Convert.ToInt64(window)); }
          Emit(new { type = "reply", id, ok = true }); return;
        }
        if (type == "sequence") { Emit(new { type = "reply", id, ok = true, sequence = GetClipboardSequenceNumber() }); return; }
        if (type == "read") {
          var paths = new List<string>();
          if (Clipboard.ContainsFileDropList()) foreach (string file in Clipboard.GetFileDropList()) if (Extensions.Contains(Path.GetExtension(file))) paths.Add(file);
          var contents = Clipboard.GetDataObject();
          bool owned = contents != null && Convert.ToString(contents.GetData("ClopWindows.Owner")) == ClipboardOwner;
          Emit(new { type = "reply", id, ok = true, sequence = GetClipboardSequenceNumber(), paths = paths.ToArray(), owned }); return;
        }
        if (type == "copy") {
          if (command.ContainsKey("expectedSequence") && Convert.ToUInt32(command["expectedSequence"]) != GetClipboardSequenceNumber()) {
            Emit(new { type = "reply", id, ok = true, skipped = true }); return;
          }
          string file = Convert.ToString(command["file"]), png = Convert.ToString(command["png"]);
          var data = new DataObject();
          data.SetData("ClopWindows.Owner", false, ClipboardOwner);
          var paths = new StringCollection();
          if (command.ContainsKey("files") && command["files"] != null) foreach (object item in (System.Collections.IEnumerable)command["files"]) paths.Add(Convert.ToString(item));
          if (paths.Count == 0) paths.Add(file);
          data.SetFileDropList(paths);
          using (var image = new Bitmap(png)) using (var stream = new MemoryStream(File.ReadAllBytes(png))) {
            data.SetImage(image);
            data.SetData("PNG", false, stream);
            Clipboard.SetDataObject(data, true, 5, 100);
          }
          Sequence = GetClipboardSequenceNumber();
          Emit(new { type = "reply", id, ok = true, sequence = Sequence }); return;
        }
        throw new InvalidOperationException("Unknown Windows bridge command.");
      } catch (Exception error) { Emit(new { type = "reply", id, ok = false, error = error.Message }); }
    }
    static IntPtr OnMouseEvent(int code, IntPtr message, IntPtr data) {
      if (code >= 0 && (message.ToInt64() == 0x0201 || message.ToInt64() == 0x0202)) {
        var mouse = (MouseData)Marshal.PtrToStructure(data, typeof(MouseData));
        Presses.Enqueue(new Press { Point = mouse.Point, Window = GetAncestor(WindowFromPoint(mouse.Point), 2), Down = message.ToInt64() == 0x0201 });
      }
      return CallNextHookEx(IntPtr.Zero, code, message, data);
    }
    static void FinishDrag() {
      Eligible = false; DragPaths = new string[0];
      if (Announced) { Announced = false; Emit(new { type = "drag-end" }); }
    }
    static void DetectImageDrag() {
      Press press;
      while (Presses.TryDequeue(out press)) {
        FinishDrag();
        if (!DetectDrag || !press.Down || press.Window == IntPtr.Zero || OwnWindows.Contains(press.Window.ToInt64())) continue;
        Start = press.Point;
        Eligible = ImageAtPress(press.Window, press.Point, out DragPaths);
      }
      if (!DetectDrag || !Eligible) return;
      // Escape cancels a real drag even when the mouse remains held. Releasing the mouse
      // also cleans up if a source application never sends a drag-end event.
      if ((GetAsyncKeyState(1) & 0x8000) == 0 || (GetAsyncKeyState(27) & 0x8000) != 0) { FinishDrag(); return; }
      Point cursor; if (!GetCursorPos(out cursor)) return;
      int threshold = Math.Max(12, Math.Max(SystemInformation.DragSize.Width, SystemInformation.DragSize.Height));
      if (!Announced && (Math.Abs(cursor.X - Start.X) > threshold || Math.Abs(cursor.Y - Start.Y) > threshold)) {
        Announced = true; Emit(new { type = "drag-start", paths = DragPaths });
      }
    }
    static void OnDragEvent(IntPtr hook, uint eventType, IntPtr window, int objectId, int childId, uint thread, uint time) {
      if (eventType == 0x000F) FinishDrag();
    }
    static bool ImageAtPress(IntPtr window, Point point, out string[] paths) {
      paths = new string[0];
      // A selected image in Explorer must not make its title bar, search field, blank
      // folder space or resize handles eligible. First hit-test the actual mouse origin.
      IntPtr hit;
      var packedPoint = new IntPtr(unchecked((int)(((uint)(ushort)point.Y << 16) | (ushort)point.X)));
      if (SendMessageTimeout(window, 0x0084, IntPtr.Zero, packedPoint, 2, 100, out hit) == IntPtr.Zero || hit.ToInt64() != 1) return false;
      IAccessible accessible = null; object child;
      try {
        if (AccessibleObjectFromPoint(point, out accessible, out child) != 0 || accessible == null) return false;
        for (int depth = 0; depth < 5; depth++) {
          int role = Convert.ToInt32(accessible.get_accRole(child));
          // Editable/selectable text is never a candidate, even if its name ends in .png.
          if (role == 0x2A) return false;
          string name = accessible.get_accName(child) ?? "";
          if (role == 0x22 || role == 0x24 || role == 0x28) {
            paths = ExplorerSelection(window, name);
            if (paths.Length > 0) return true;
            if (role == 0x28 && !IsExplorer(window)) {
              string value = accessible.get_accValue(child) ?? "";
              // Image objects cover browser/native image drags. Reject a known unsupported
              // suffix; some apps only expose an image description, with no source URL.
              return SupportedGraphic(value) && SupportedGraphic(name);
            }
          }
          // Only descend from a file label/thumbnail to its containing item. Walking up
          // from an arbitrary control could mistake a whole window for an image.
          if (role != 0x29 && role != 0x28) return false;
          var parent = accessible.accParent as IAccessible;
          if (parent == null) return false;
          Marshal.ReleaseComObject(accessible); accessible = parent; child = 0;
        }
      } catch { /* Unknown/inaccessible sources stay quiet rather than guessing a drag. */ }
      finally { if (accessible != null && Marshal.IsComObject(accessible)) Marshal.ReleaseComObject(accessible); }
      return false;
    }
    static bool SupportedGraphic(string value) {
      Uri uri;
      if (Uri.TryCreate(value, UriKind.Absolute, out uri)) {
        if (uri.Scheme == "data") return value.StartsWith("data:image/png", StringComparison.OrdinalIgnoreCase) || value.StartsWith("data:image/jpeg", StringComparison.OrdinalIgnoreCase) || value.StartsWith("data:image/webp", StringComparison.OrdinalIgnoreCase) || value.StartsWith("data:image/gif", StringComparison.OrdinalIgnoreCase) || value.StartsWith("data:image/avif", StringComparison.OrdinalIgnoreCase);
        value = uri.AbsolutePath;
      }
      string extension = Path.GetExtension(value);
      return String.IsNullOrEmpty(extension) || Extensions.Contains(extension);
    }
    static bool IsExplorer(IntPtr window) {
      uint process; GetWindowThreadProcessId(window, out process);
      try { return String.Equals(Process.GetProcessById((int)process).ProcessName, "explorer", StringComparison.OrdinalIgnoreCase); } catch { return false; }
    }
    static bool ItemNameMatches(string name, string file, string displayName) {
      return String.Equals(name, displayName, StringComparison.OrdinalIgnoreCase) || String.Equals(name, Path.GetFileName(file), StringComparison.OrdinalIgnoreCase) || String.Equals(name, Path.GetFileNameWithoutExtension(file), StringComparison.OrdinalIgnoreCase);
    }
    static string[] ExplorerSelection(IntPtr window, string name) {
      var paths = new List<string>();
      if (!IsExplorer(window) || String.IsNullOrEmpty(name)) return paths.ToArray();
      bool hitSelectedImage = false;
      object shell = null, windows = null;
      try {
        shell = Activator.CreateInstance(Type.GetTypeFromProgID("Shell.Application"));
        dynamic automation = shell; windows = automation.Windows();
        foreach (dynamic explorer in (dynamic)windows) {
          try {
            if ((long)explorer.HWND != window.ToInt64()) continue;
            foreach (dynamic item in explorer.Document.SelectedItems()) {
              string file = Convert.ToString(item.Path);
              if (Extensions.Contains(Path.GetExtension(file)) && File.Exists(file)) {
                paths.Add(file);
                if (ItemNameMatches(name, file, Convert.ToString(item.Name))) hitSelectedImage = true;
              }
            }
          } catch { }
        }
      } catch { }
      finally { if (windows != null) Marshal.ReleaseComObject(windows); if (shell != null) Marshal.ReleaseComObject(shell); }
      if (hitSelectedImage) return paths.ToArray();
      // The desktop is an Explorer list but is not returned by Shell.Application.Windows().
      var className = new StringBuilder(256); GetClassName(window, className, className.Capacity);
      if (className.ToString() == "Progman" || className.ToString() == "WorkerW") {
        foreach (var directory in new[] { Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), Environment.GetFolderPath(Environment.SpecialFolder.CommonDesktopDirectory) }) {
          try { foreach (var file in Directory.EnumerateFiles(directory)) if (Extensions.Contains(Path.GetExtension(file)) && ItemNameMatches(name, file, Path.GetFileName(file))) return new[] { file }; } catch { }
        }
      }
      return new string[0];
    }
  }
}
