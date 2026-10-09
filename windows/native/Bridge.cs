using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace ClopWindows {
  // Windows PowerShell 5.1 runs this helper on an STA thread. No runtime installation needed.
  public static class Bridge {
    [DllImport("user32.dll")] static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    delegate void WinEventCallback(IntPtr hook, uint eventType, IntPtr window, int objectId, int childId, uint thread, uint time);
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr module, WinEventCallback callback, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr hook);
    static readonly WinEventCallback DragEvents = OnDragEvent;
    static readonly HashSet<long> OwnWindows = new HashSet<long>();
    static readonly ConcurrentQueue<string> Commands = new ConcurrentQueue<string>();
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    static volatile bool Ended;
    static uint Sequence;
    static readonly string ClipboardOwner = Guid.NewGuid().ToString("N");
    static bool WasDown, Announced, OleDrag, DetectDrag = true;
    static Point Start;
    static int PressTime;
    static bool ExternalPress;
    static string[] DragPaths = new string[0];
    static readonly HashSet<string> Extensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { ".png", ".jpg", ".jpeg", ".webp", ".gif", ".avif", ".tif", ".tiff" };
    static void Emit(object value) { Console.WriteLine(Json.Serialize(value)); Console.Out.Flush(); }
    public static void Run() {
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
        DetectExplorerDrag();
      };
      var hook = SetWinEventHook(0x000E, 0x000F, IntPtr.Zero, DragEvents, 0, 0, 2);
      timer.Start(); Emit(new { type = "ready", sequence = Sequence }); Application.Run(); timer.Dispose();
      if (hook != IntPtr.Zero) UnhookWinEvent(hook);
    }
    static void Handle(string line) {
      string id = null;
      try {
        var command = Json.Deserialize<Dictionary<string, object>>(line);
        id = Convert.ToString(command["id"]);
        string type = Convert.ToString(command["type"]);
        if (type == "settings") {
          DetectDrag = Convert.ToBoolean(command["explorerDrag"]);
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
    static void DetectExplorerDrag() {
      bool down = (GetAsyncKeyState(1) & 0x8000) != 0;
      Point cursor; GetCursorPos(out cursor);
      if (DetectDrag && down && !WasDown) {
        Start = cursor; PressTime = Environment.TickCount;
        // A Windows drag event can arrive before the polling timer sees the mouse press.
        // Keep that announcement alive instead of waiting for a second movement threshold.
        if (!OleDrag) Announced = false;
        ExternalPress = !OwnWindows.Contains(GetForegroundWindow().ToInt64());
        DragPaths = ExternalPress ? ExplorerSelection() : new string[0];
      }
      int threshold = DragPaths.Length > 0 ? 12 : 48;
      // WinEvent covers OLE drags. Some applications omit it; a held mouse drag supplies a transient
      // corner target there too. The target never reads or changes the dragged item until a drop.
      if (DetectDrag && down && ExternalPress && !Announced && (DragPaths.Length > 0 || Environment.TickCount - PressTime > 180) && (Math.Abs(cursor.X - Start.X) > threshold || Math.Abs(cursor.Y - Start.Y) > threshold)) {
        Announced = true; Emit(new { type = "drag-start", paths = DragPaths });
      }
      if (!down && WasDown && Announced) { Announced = false; OleDrag = false; Emit(new { type = "drag-end" }); }
      WasDown = down;
    }
    static void OnDragEvent(IntPtr hook, uint eventType, IntPtr window, int objectId, int childId, uint thread, uint time) {
      if (!DetectDrag) return;
      if (eventType == 0x000E) {
        if (OwnWindows.Contains(GetForegroundWindow().ToInt64())) return;
        OleDrag = true;
        if (!Announced) { Announced = true; Emit(new { type = "drag-start", paths = new string[0] }); }
      }
      // The foreground window may now be Clop after a drop. Always finish an external drag.
      if (eventType == 0x000F) { OleDrag = false; if (Announced) { Announced = false; Emit(new { type = "drag-end" }); } }
    }
    static string[] ExplorerSelection() {
      var paths = new List<string>();
      IntPtr window = GetForegroundWindow(); uint process; GetWindowThreadProcessId(window, out process);
      try { if (!String.Equals(Process.GetProcessById((int)process).ProcessName, "explorer", StringComparison.OrdinalIgnoreCase)) return paths.ToArray(); } catch { return paths.ToArray(); }
      object shell = null, windows = null;
      try {
        shell = Activator.CreateInstance(Type.GetTypeFromProgID("Shell.Application"));
        dynamic automation = shell; windows = automation.Windows();
        foreach (dynamic explorer in (dynamic)windows) {
          try {
            if ((long)explorer.HWND != window.ToInt64()) continue;
            foreach (dynamic item in explorer.Document.SelectedItems()) {
              string file = Convert.ToString(item.Path);
              if (Extensions.Contains(Path.GetExtension(file)) && File.Exists(file)) paths.Add(file);
            }
          } catch { }
        }
      } catch { }
      finally { if (windows != null) Marshal.ReleaseComObject(windows); if (shell != null) Marshal.ReleaseComObject(shell); }
      return paths.ToArray();
    }
  }
}
