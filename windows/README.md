# Clop for Windows

A Windows port of Clop's automatic image and clipboard workflow. This is an independent fork of [Clop by the Lowtech Guys](https://github.com/FuzzyIdeas/Clop), under the same GPLv3 license.

## The experience

Run Clop once. It stays in the system tray. There is no workbench, file browser, onboarding dashboard or sample-image screen.

Copy an image or screenshot in another app. Clop automatically optimises it, puts the result back on the clipboard and shows a small thumbnail card in the bottom-right corner. You can keep working in the original app. The card does not steal focus.

The result uses the geometry and interaction model in the original `FloatingResult.swift`:

- A 196 × 148 thumbnail with the image filling its background.
- Size reduction and resolution over the bottom of the thumbnail.
- An 18-pixel format bar beneath it, with the current format preselected. Click PNG, JPG, WebP, AVIF or GIF to convert in place.
- Six small actions revealed on hover: downscale, restore, compression, aggressive optimisation, copy and save.
- Downscaling opens a slider over the same thumbnail. Choose 100%, 75%, 50%, 25% or 10%, or use the slider. No separate editing window opens.
- Dimensions, compare and Show in Explorer live in the corner menu. Drag the thumbnail to another app.

While dragging, a transient 196 × 148 `Drop to optimise` target appears in the corner, matching `DropZone.swift`. Drop an image onto it to optimise. Releasing the drag elsewhere dismisses the target without changing the file. Dragged image URLs from browsers can also be downloaded and optimised after an explicit drop.

Windows accessibility drag events drive the target. Explorer selection detection covers image files, including copied files. A held-mouse movement fallback offers the target for apps that omit Windows drag events. That fallback can also appear during non-image mouse drags; unsupported drops never change the source. The native target cannot know an arbitrary app's dragged payload until it is dropped.

Clipboard cards disappear after ten seconds and file cards after thirty, as in the original defaults. Hovering pauses dismissal. The tray's `Show latest results` or `Ctrl+Shift+Space` brings recent cards back. Up to three cards stack vertically. The tray also provides clipboard controls, optional pinning, settings and access to originals.

Settings stay closed unless requested from the tray. Choose a screen corner, default format, clipboard behaviour or starting with Windows. The current cursor's screen receives automatic popups.

## Install

Download the Windows x64 installer or portable executable from this fork's Windows releases. Windows 10 and Windows 11 are supported. The builds are unsigned. No Node.js, PowerShell module or development setup is required to use them.

## Image and clipboard details

Supported formats are PNG, JPEG, WebP, GIF, AVIF and single-page TIFF. TIFF converts to PNG. Animated GIF and WebP retain their frames and timing. Their format bar disables still-image targets. This version does not process video, audio, PDF, HEIC or SVG and does not include an AI upscaler.

Every resize and format switch starts from the saved original. Restoring recovers its exact bytes. Source files are never overwritten. If a same-format, same-resolution optimisation would increase file size, Clop keeps the original bytes.

The Windows helper writes an encoded PNG, a Windows bitmap and a file-drop list together. File-aware apps receive optimised files; image-aware apps receive an image. Apps that only accept bitmap data may re-encode it themselves. Animation survives file paste and drag; bitmap paste uses the first frame. Copying something else during automatic processing prevents the old image from overwriting the new clipboard contents. Own writes do not trigger another optimisation.

Lossless PNG and WebP preserve decoded pixels. Lossless mode keeps original JPEG bytes when no resize is requested; resizing a JPEG in Lossless mode produces PNG. JPEG conversion uses white behind transparent pixels. Balanced and Smaller compression may discard detail.

Originals and results remain in `%APPDATA%\Clop for Windows\images` for seven days. The app remembers up to 40 images during its session and automatically retires the oldest entries. Its local cache starts fresh on restart. Input limits are 128 MB, 60 million pixels across all frames, 250 animation frames and 20 files per drop.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| `Ctrl+Shift+C` | Optimise current clipboard |
| `Ctrl+Shift+A` | Optimise clipboard more aggressively |
| `Ctrl+Shift+Space` | Bring back recent corner cards |
| `1` through `9` | Resize selected image to 10% through 90% |
| `-` | Reduce selected image by another 10% of original width |
| `C` | Copy selected image |
| `R` | Restore selected image |
| `Escape` | Hide corner cards |

Single-letter shortcuts operate while a card has keyboard focus and no text field is active. Global shortcut conflicts appear as a small notification; tray commands remain available.

## Development and verification

The Windows app uses Electron, TypeScript, React and Sharp, with a small STA helper using built-in Windows PowerShell 5.1 and .NET Framework. It registers Windows drag-event hooks and watches clipboard sequence numbers. The renderer is sandboxed, has no Node.js access and receives a narrow preload API. External navigation is blocked.

Use Node.js 24 or newer. From `windows/`:

```sh
npm ci
npm run desktop
npm test
npm run build
npm run dist:win
```

The packaging command runs on Windows and produces NSIS and portable executables in `release/`. CI tests image processing, compiles the Windows helper, checks native clipboard formats and launches the packaged app. An external clipboard write must produce a corner result automatically. CI checks the 196 × 166 card, selected format, resize, restore and clipboard loop protection, and saves an actual Windows screenshot.

`npm run dev` serves a development-only corner-card preview on loopback port 5274. Its background is a neutral canvas so the transparent cards can be inspected in a browser. Paste an image to inspect a card. There are no browse or sample controls. A browser cannot demonstrate system-wide clipboard watching or native Windows drag detection; those are exercised by the packaged-app test. Preview data stays under `.preview-data/` and can be removed after shutdown.

The desktop app does not upload images or send analytics. Downloading an image URL only occurs when that URL is explicitly dropped onto the target. Managed machines may block the Windows helper; Clop reports the failure, and save and drag operations remain available.

API references: [Electron clipboard](https://www.electronjs.org/docs/latest/api/clipboard), [Electron file paths](https://www.electronjs.org/docs/latest/api/web-utils), [Sharp output](https://sharp.pixelplumbing.com/api-output/) and [Sharp resizing](https://sharp.pixelplumbing.com/api-resize/).

## Attribution

The original macOS source, interaction model and hat icon are by the Lowtech Guys and Clop contributors. The Windows implementation is GPLv3, as is this repository. Dependency licenses remain with their respective authors.
