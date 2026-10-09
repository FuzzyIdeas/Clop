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
    static readonly ConcurrentQueue<string> Commands = new ConcurrentQueue<string>();
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    static volatile bool Ended;
    static uint Sequence;
    static bool WasDown, Announced, DetectDrag = true;
    static Point Start;
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
            var paths = new List<string>();
            if (Clipboard.ContainsFileDropList()) foreach (string file in Clipboard.GetFileDropList()) if (Extensions.Contains(Path.GetExtension(file))) paths.Add(file);
            Emit(new { type = "clipboard", sequence = next, paths = paths.ToArray() });
          } catch { /* A different app may temporarily hold the clipboard. Retry on its next change. */ }
        }
        DetectExplorerDrag();
      };
      timer.Start(); Emit(new { type = "ready", sequence = Sequence }); Application.Run(); timer.Dispose();
    }
    static void Handle(string line) {
      string id = null;
      try {
        var command = Json.Deserialize<Dictionary<string, object>>(line);
        id = Convert.ToString(command["id"]);
        string type = Convert.ToString(command["type"]);
        if (type == "settings") { DetectDrag = Convert.ToBoolean(command["explorerDrag"]); Emit(new { type = "reply", id, ok = true }); return; }
        if (type == "sequence") { Emit(new { type = "reply", id, ok = true, sequence = GetClipboardSequenceNumber() }); return; }
        if (type == "read") {
          var paths = new List<string>();
          if (Clipboard.ContainsFileDropList()) foreach (string file in Clipboard.GetFileDropList()) if (Extensions.Contains(Path.GetExtension(file))) paths.Add(file);
          Emit(new { type = "reply", id, ok = true, sequence = GetClipboardSequenceNumber(), paths = paths.ToArray() }); return;
        }
        if (type == "copy") {
          if (command.ContainsKey("expectedSequence") && Convert.ToUInt32(command["expectedSequence"]) != GetClipboardSequenceNumber()) {
            Emit(new { type = "reply", id, ok = true, skipped = true }); return;
          }
          string file = Convert.ToString(command["file"]), png = Convert.ToString(command["png"]);
          var data = new DataObject();
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
        Start = cursor; Announced = false; DragPaths = ExplorerSelection();
      }
      if (DetectDrag && down && !Announced && DragPaths.Length > 0 && (Math.Abs(cursor.X - Start.X) > 12 || Math.Abs(cursor.Y - Start.Y) > 12)) {
        Announced = true; Emit(new { type = "drag-start", paths = DragPaths });
      }
      if (!down && WasDown && Announced) { Announced = false; Emit(new { type = "drag-end" }); }
      WasDown = down;
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
