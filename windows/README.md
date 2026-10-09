# Clop for Windows

A Windows image app inspired by [Clop](https://github.com/FuzzyIdeas/Clop). It watches the clipboard, offers a floating drop target and keeps compression, resizing and format switching on the result card. This is an independent port, not an official Lowtech Guys release. The original macOS app lives in the existing Swift directories.

## Use it

Download the installer or portable executable from this fork's Windows releases. Run it on Windows 10 or Windows 11, x64. Clop opens a workbench and stays in the system tray when you close its windows.

- Copy an image, screenshot or image file. Clop optimises it and shows a floating card. Automatic copying keeps the result ready to paste.
- Drag an image from Explorer. The floating target appears when Clop detects a mouse drag of selected image files. Drop there to optimise. This uses Explorer's selection and a movement threshold; it does not intercept or optimise files moved elsewhere.
- Pin the drop zone to use it with any app. Drag its header to position it. `Ctrl+Shift+Space` brings it forward.
- Switch between Balanced, Smaller and Lossless compression, change the format, choose a percentage or set the longest edge in pixels. Every change starts from the original.
- Drag the preview into another app, copy it, save it or reveal it in Explorer. Compare the original and result with the comparison slider.
- Restore the exact original bytes with the restore button or `R`.

PNG, JPEG, WebP, GIF, AVIF and single-page TIFF are supported. TIFF converts to PNG. Animated GIF and WebP retain their frames and timing. Animated images cannot convert to a still format. HEIC, SVG, PDF, audio and video are outside this version. It only downscales; it does not include an AI upscaler.

The source files are never overwritten. Clop stores originals and results in `%APPDATA%\Clop for Windows\images` for seven days, accessible from the tray menu. The shelf itself starts fresh on restart. Limits are 128 MB per input, 60 million pixels across all frames, 250 animation frames, 20 files per drop and 40 shelf items. These keep large images from overwhelming the desktop.

## Clipboard behavior

The Windows helper writes an encoded PNG, a Windows bitmap and a file-drop list in one clipboard operation. Explorer and file-aware apps receive the optimised files. Image-aware apps receive an image. Applications that accept only bitmap data may re-encode it themselves, so their final attachment size depends on that app. GIF and WebP animation survives file paste and drag; bitmap paste uses the first frame.

Clop ignores its own clipboard writes and checks the Windows clipboard sequence before replacing an automatically optimised image. Copying something else during processing prevents the old image from overwriting it. Other clipboard tools may compete with Clop, and apps running as administrator can reject drops from ordinary apps.

Lossless PNG and WebP preserve decoded pixels. Lossless mode keeps untouched JPEG bytes when no resize is requested. Resizing a JPEG in Lossless mode outputs PNG. JPEG conversion uses a white background for transparency. Balanced and Smaller modes can discard detail; inspect the comparison when that matters.

Explorer drag detection covers ordinary Explorer windows. Third-party file managers, the desktop shell and touch gestures can require the pinned target or shortcut. No file move happens unless you explicitly drop on Clop. The helper uses the Windows PowerShell 5.1 and .NET Framework components included in Windows, not an extra service or installed runtime. Managed machines can block PowerShell; the app reports helper failures and still permits save and drag operations.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| `Ctrl+Shift+C` | Optimise current clipboard |
| `Ctrl+Shift+A` | Optimise clipboard with Smaller compression |
| `Ctrl+Shift+Space` | Show floating shelf |
| `1` through `9` | Resize selected image to 10% through 90% |
| `-` | Reduce selected image by another 10% of original width |
| `C` | Copy selected image |
| `R` | Restore selected image |
| `Escape` | Hide floating shelf |

Letter and resize shortcuts operate in Clop when no text input or select has focus. Global shortcut conflicts appear in the app; tray commands remain available.

## Development

Use Node.js 24 or newer. From `windows/`:

```sh
npm ci
npm run desktop
```

`npm run dev` starts a browser workbench on loopback port 5274. It uses the real Sharp engine with drag, paste, compression, conversion, comparison and downloads. It cannot provide system-wide clipboard watching, native drag out, Explorer detection or a Windows tray. Desktop settings are disabled in the browser. Preview files are task data under `.preview-data/` and can be removed after shutting down the server.

```sh
npm test
npm run build
npm run dist:win
```

The last command runs on Windows and produces an NSIS installer and portable executable in `release/`. The GitHub workflow builds on Windows, tests the engine and validates clipboard image, encoded PNG, file-list formats and clipboard sequence protection through the native helper. It also launches the packaged app and checks its sandboxed preload, real image processing, clipboard, floating result window and restore action. Windows screenshots accompany the executable artifacts. Artifacts are unsigned. A signed release requires the publisher's Windows code-signing certificate.

## Implementation

Electron and React provide the workbench, tray, global shortcuts and movable floating window. Sharp performs compression and resizing through its native image libraries. A small STA Windows helper implements clipboard file formats and detects Explorer selection drags. Processing runs in a serial queue with two Sharp threads. No network upload or analytics is used by the desktop app.

The renderer has context isolation and sandboxing, no Node.js access, a narrow preload API and a content security policy. External navigation is blocked. The main process only exposes operations on image IDs it owns, validates processing options and uses user-selected paths for exports.

API references: [Electron clipboard](https://www.electronjs.org/docs/latest/api/clipboard), [Electron file paths](https://www.electronjs.org/docs/latest/api/web-utils), [Sharp output](https://sharp.pixelplumbing.com/api-output/) and [Sharp resizing](https://sharp.pixelplumbing.com/api-resize/).

## Attribution and license

Clop's workflow and original macOS source are by the Lowtech Guys and Clop contributors. This fork retains the repository's GPLv3 license. The Windows implementation is also GPLv3. Its icon and sample illustration were created for this port. Dependency licenses remain with their respective authors.
