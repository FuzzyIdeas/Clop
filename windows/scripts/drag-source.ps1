param([string]$Image)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using System.Web.Script.Serialization;
public static class ClopDragSource {
  [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll")] static extern void NotifyWinEvent(uint type, IntPtr window, int objectId, int child);
  static void Draggable(Control control, object payload) {
    Point start = Point.Empty;
    control.MouseDown += (sender, args) => { start = args.Location; };
    control.MouseMove += (sender, args) => {
      if (args.Button != MouseButtons.Left || Math.Abs(args.X - start.X) + Math.Abs(args.Y - start.Y) < 12) return;
      NotifyWinEvent(0x000E, control.Handle, -4, 0);
      try { control.DoDragDrop(payload, DragDropEffects.Copy); }
      finally { NotifyWinEvent(0x000F, control.Handle, -4, 0); }
    };
  }
  static object Bounds(Control control) {
    var rect = control.RectangleToScreen(control.ClientRectangle);
    return new { x = rect.X + rect.Width / 2, y = rect.Y + rect.Height / 2 };
  }
  public static void Run(string file) {
    SetProcessDpiAwarenessContext(new IntPtr(-4));
    var form = new Form { Text = "Clop drag regression source.png", Location = new Point(60, 60), ClientSize = new Size(520, 430), StartPosition = FormStartPosition.Manual, AutoScaleMode = AutoScaleMode.None, TopMost = true };
    var picture = new PictureBox { Location = new Point(20, 20), Size = new Size(180, 140), Image = Image.FromFile(file), SizeMode = PictureBoxSizeMode.Zoom, AccessibleRole = AccessibleRole.Graphic, AccessibleName = "source.png" };
    var unsupported = new PictureBox { Location = new Point(230, 20), Size = new Size(180, 140), Image = picture.Image, SizeMode = PictureBoxSizeMode.Zoom, AccessibleRole = AccessibleRole.Graphic, AccessibleName = "unsupported.svg" };
    var text = new TextBox { Location = new Point(20, 190), Size = new Size(460, 65), Multiline = true, Text = "Select this text without opening the image drop target. source.png", AccessibleName = "source.png" };
    var textDrag = new Label { Location = new Point(20, 280), Size = new Size(400, 30), Text = "Drag plain text: source.png", AccessibleRole = AccessibleRole.Text, AccessibleName = "source.png" };
    form.Controls.AddRange(new Control[] { picture, unsupported, text, textDrag });
    var data = new DataObject(); data.SetData(DataFormats.FileDrop, new[] { file });
    Draggable(picture, data); Draggable(unsupported, "unsupported.svg"); Draggable(textDrag, "source.png");
    form.Shown += (sender, args) => {
      form.Activate();
      var rect = form.Bounds;
      var blank = form.PointToScreen(new Point(420, 360));
      Console.WriteLine(new JavaScriptSerializer().Serialize(new { window = form.Handle.ToInt64(), image = Bounds(picture), unsupported = Bounds(unsupported), text = Bounds(text), textDrag = Bounds(textDrag), blank = new { x = blank.X, y = blank.Y }, title = new { x = rect.X + 160, y = rect.Y + 12 }, resize = new { x = rect.Right - 3, y = rect.Bottom - 3 } }));
      Console.Out.Flush();
    };
    Application.Run(form); picture.Image.Dispose(); form.Dispose();
  }
}
'@ -ReferencedAssemblies System.Windows.Forms,System.Drawing,System.Web.Extensions
[ClopDragSource]::Run($Image)
