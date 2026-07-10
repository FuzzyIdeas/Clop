# 3.3.0

**[Download Clop 3.3.0 →](https://files.lowtechguys.com/releases/Clop-3.3.0.dmg)**
## Features

- **Format bar**: change a file's format with one click from a bar at the bottom of each floating result
    > The previous picker (hover on the file extension) can be brought back in Settings > Floating results
- **Extreme compression** at the top of the compression slider, for all formats
- **Fit under size**: compress a file under a chosen size limit
    > Available as an action button on results and in the file's right-click menu
- Floating results move to the screen where the cursor is
    > Disable with *Follow the cursor across screens* in Settings > Floating results

## Fixes

- Animated GIFs copied as image data from other apps keep their animation when optimised, instead of being flattened to their first frame
    > As a safety net, any optimisation that would leave a single frame out of an animated GIF now fails and keeps the original file untouched
- With the optimised file location set to *Same folder*, files dropped on Clop or picked up from watched folders no longer produce a doubled-suffix duplicate like `photo-optim-optim.png` next to `photo-optim.png`
    > The naming pattern was applied twice: the real optimised file got the doubled name, while the normally named copy was left unoptimised

## Improvements

- Floating results can also be dragged out when the drag starts on an empty `+` button slot; a plain click still opens the menu that assigns an action to the slot
    > To keep the press free for dragging, the menu opens when the mouse is released instead of when it is pressed

# 3.2.3

**[Download Clop 3.2.3 →](https://files.lowtechguys.com/releases/Clop-3.2.3.dmg)**
## Features

- **Compression slider for every format**: dragging the compression button on a converted result re-encodes it in its current format at the chosen quality, instead of silently switching it back to the original format
    > Works for HEVC, AV1 and WebM video conversions and for image conversions like WEBP
- **Codec badges**: the format chip shows the real codec when the extension alone can't (`mp4 · HEVC`, `mkv · AV1`, `m4a · AAC`, `ogg · OPUS`), including for files that arrive already encoded that way

## Fixes

- Converting a file to the codec it is already in is no longer offered; it used to re-encode the file for nothing

- Converting audio to a lossless format (WAV, FLAC, AIFF) no longer shows a nonsense bitrate like `192 kbps → 0 kbps`; lossless files have no bitrate to tune, so none is shown

- Cleaning up old working files no longer freezes the app when the disk is slow

## Improvements

- Floating results can be dragged out even when the drag starts on one of the action buttons (a plain click still triggers the button). Downscale and compression keep their press-and-drag slider behaviour

# 3.2.2

**[Download Clop 3.2.2 →](https://files.lowtechguys.com/releases/Clop-3.2.2.dmg)**
## Fixes

- QR codes no longer disappear when optimising PDFs (Canva and similar exports draw them through a transparency mask that was being dropped)
- Fixed a crash that could happen when turning floating results or the cursor drop zone off and back on
- Fixed a crash when keeping metadata while converting some images
- Fixed several causes of the app freezing or briefly hanging: clipboard monitoring waiting on a slow pasteboard, watching folders on slow or network volumes, dropping very large images, converting HDR HEIC photos, and saving optimised files to slow destinations
- Large drops of image or video files open the batch window, not only folders
- Share menu on a floating result stays open while you move the cursor onto it, instead of closing the moment the result's buttons fade

## Improvements

- Batch mode settings moved to the Drop zone settings

# 3.2.1

**[Download Clop 3.2.1 →](https://files.lowtechguys.com/releases/Clop-3.2.1.dmg)**
## Features

- **Preset zone** entry in a pipeline's *Add to* menu assigns it to a preset zone for one file type or all types
- **Go to pipeline** in a preset zone's menu jumps to the assigned pipeline in the Pipelines list

## Fixes

- **Drag all** now drops every file, not just the first one, whether you use the drag handle on a result or drag a multi-row selection in the compact list
- Audio preset zones no longer show up under Image, Video, and PDF

# 3.2.0

**[Download Clop 3.2.0 →](https://files.lowtechguys.com/releases/Clop-3.2.0.dmg)**
## Features

- **Pipelines tab** builds and assigns automations: create a pipeline, then pin it to the clipboard, drop zone, watched folders or preset zones, view where each pipeline is assigned.
- **One result card per pipeline**: the floating result updates in place as steps run instead of spawning a new card each step. A `fork` step peels off a second file you can drag out while the pipeline keeps going.
- **File handling** tab sets where optimised and converted files land, per type: next to the original, a specific folder, in place, or temporary, each with its own name template.
- **Per-format audio conversion**: out of the box WAV becomes MP3, AIFF and FLAC become M4A; anything you don't pick keeps its own format.
- **Tappable result chips**: click a result's name to rename or its extension to convert in one click. A new conversion replaces the last; hold **Option** to keep both.

## Fixes

- Pipeline editors and previews follow light and dark mode instead of getting stuck
- Converting an image to the format it already is no longer re-encodes it
- PDF optimisation keeps transparency-group icons instead of dropping them
- `clop strip-exif` finds its bundled tools again

## Improvements

- Right-click a result to see the pipeline that produced it and jump straight to it in the Pipelines tab
- **Send with AirDrop** straight from a result's right-click menu
- Crop and downscale pipelines run in one pass and never grow the file, even for flat graphics
- **Send securely** delivers to several receivers at once
- `clop pipeline list`, `run` and `prompt` read in plain language and gain show/hide-result flags

# 3.1.0

**[Download Clop 3.1.0 →](https://files.lowtechguys.com/releases/Clop-3.1.0.dmg)**
## Batch mode

Drop a folder or a big pile of files and Clop opens a dedicated window built for thousands of files, without a floating card for each one.

![The batch optimisation window](https://files.lowtechguys.com/clop-3.1.0-batch.png)

Before anything runs, each original is cloned to a safe backup, so you can re-compress the whole set with different settings or roll it all back.

Drop a folder with more files than the threshold you set in Settings and it opens here automatically. You can also open it from the menubar and drag files in.

## Redesigned floating results

Every optimised file is now a thumbnail card, audio included, with album cover art when the file has it. Hover a card for its action buttons, or press `Space` to QuickLook it.

![Floating results for an image, video, PDF and audio file](https://files.lowtechguys.com/clop-3.1.0-floating-results.png)

## Pick files in the compact list

Click a hover checkbox to start selecting, then click any row to add it. A bar appears for the whole set: a handle to drag them all out, plus save, crop, downscale, bitrate and more. `⌘A` selects all, `Esc` clears.

![Selecting files in the compact list](https://files.lowtechguys.com/clop-3.1.0-compact-results.png)

## Audio

Audio gets first-class controls this release.

- **Cover art**: choose whether embedded art is optimised, removed, or left untouched, instead of always being dropped. Optimising recompresses it at aggressive settings while keeping its resolution, so it stops bloating the file.
- **Extract cover art** as its own image result, ready to save or drag out, and **downscale** it with a slider that shows the target resolution as you drag.
- **Loudness normalisation**: even out volume to a target (Streaming, Apple Music, Podcast, Broadcast).
- **Speed up audio**: the playback speed change now works on audio files, not just video.
- **Compression slider**: one percentage trades quality for size, with the resulting bitrate shown as you move it.
- **Compare (A/B)**: play the original and the optimised version back to back.

![Comparing the original and optimised audio side by side](https://files.lowtechguys.com/clop-3.1.0-audio-compare.png)

## Edit with external app

Hand an optimised file to an editor of your choice with `⌘E` or the right-click menu. Pick a per-type app in Settings, for example Pixelmator Pro for images, LosslessCut for video, or Audacity for audio.

![Edit with external app setting](https://files.lowtechguys.com/clop-3-1-0-edit-external-app.png)

## New menubar icon

A fresh default menubar icon, with a picker if you'd rather keep the classic one or switch to the flat geometric style.

![Menubar icon styles](https://files.lowtechguys.com/clop-3-1-0-menubar-icon-selector.png)

## Secure send link expiration

Choose how long a "Send securely" link stays alive, from `1m` up to `3d`, or never. Set it as you send (a slider on the floating result, a popover in compact mode), or change it later from the live link button.

![Send securely link expire](https://files.lowtechguys.com/clop-3-1-0-send-link-expire.png)

## More for power users

- **Inline pipeline scripts**: run shell commands straight from a step with `runScript(code: "sips -Z 800 $1")`, no separate script file needed.
- **`clop pipeline prompt`**: print a paste-ready reference of the whole pipeline language for an AI assistant, then describe a task and get a working pipeline back. Add `-c` to copy it to the clipboard.

## Fixes

- `--copy` always copies a file path, even when optimisation or conversion fails (it copies the original), so you get back as many files as you put in
- *Optimised file location* is respected when re-optimising from the floating result
- The close (x) button reliably dismisses a floating result
- Audio bitrate is never raised above the file's original, even when the configured bitrate is higher
- Aggressive optimisation on audio steps the bitrate down a level instead of doing nothing
- Files worked on with an `Option`-drag copy keep their real name instead of a temporary `clop-dropzone-…` name
- The Cmd-minus on hover hotkey now lowers PDF resolution and audio bitrate, instead of only flashing the value
- Restoring the original clears the stale size, bitrate and resolution comparison
- The downscale button no longer looks disabled for WebP, HEIC, AVIF and TIFF images
- PDF results no longer show a second, greyed-out compression button next to the working one
- The "drag all" handle works again instead of grabbing the result above it, and shows a stack of file thumbnails
- Dragging a single result shows its thumbnail instead of a plain dark rectangle
- The filename on an audio result is centred at its natural width instead of stretching across the card

## Improvements

- The filename on a card grows to full width and shrinks to fit while you hover it, so long names stay readable
- Audio results show the cover art resolution under the bitrate
- Launching Clop while it's already running opens Settings
- The drop zone preview in Settings scrolls, and includes audio preset zones
- Menubar menu hides keyboard shortcut hints for actions whose hotkeys are turned off
- The compact result list stays smooth with many results and shows the space saved as a percentage, matching the batch window
- Selecting files in the compact list keeps your single-file actions and never reshuffles the list out from under you

# 3.0.0

**[Download Clop 3.0.0 →](https://files.lowtechguys.com/releases/Clop-3.0.0.dmg)**
## Audio optimisation

Clop now handles audio files: `WAV`, `FLAC`, `AIFF`, high-bitrate `MP3`s.

Drop audio files and Clop converts them to `AAC`, `MP3` or `Opus` at a bitrate you pick. `WAV` downsizing is also possible if the decoder supports `adpcm` encoding.

*New **Audio** tab in Settings for watched folders, output format, bitrate and skip rules.*

## Drop zone at cursor

Tap `⌥ Option` to show the drop zone below your cursor. Tap again to dismiss.

No need to drag files across the screen to reach a corner.

## Video encoder picker

The old *Aggressive / CPU-intensive* toggles are now a single picker:

- **Fast, battery efficient, larger file** -- hardware encoder, almost no CPU usage
- **Slow, high quality, smaller file** -- software encoder, high CPU usage
- **Visually lossless** -- best quality, largest files

## Collect clipboard results

New setting to collect all clipboard optimisation results instead of always replacing the last one.

Every image you copy gets optimised and added to a list. Paste them all at once into apps that accept multiple files.

There's also a new drag handle that can drag all results at once.

## PDF pages as images

Right-click a PDF result to extract its pages as optimised JPEG or PNG files.

Single-page PDFs get a **Convert to image** option that creates a new draggable result. Multi-page PDFs get **Extract pages as images** which saves all pages to a folder you choose, with a progress bar on the PDF result.

## Send files securely

Share any optimised file over an encrypted peer-to-peer connection. No upload, no server storage, unlimited size.

Click **Send file securely** from the right-click menu or the side button, and a link is copied to your clipboard. The receiver opens the link in a browser and downloads directly from your Mac over WebRTC. The link stays active until you stop it or quit Clop.

Active sends appear in the menubar menu where you can copy the link again or stop individual sends.

## Configurable action buttons

The side buttons on floating and compact results can now be rearranged and customised. Add, remove or reorder actions from Settings.

## JPEG XL support

Clop can now read and write JPEG XL files. Drop a JPEG XL file to convert it to a more widely supported format, or export an optimised image as JPEG XL for maximum quality and compression. The resulting file will have the `.jxl` extension.

## AV1 video support

Clop can now read and write AV1 video files. Drop an AV1 file to convert it to a more widely supported format, or convert any format to AV1 for maximum quality and compression.

AV1 does not have its own file extension, I decided to use the MKV container for AV1 encoding to make it easily distinguishable from the more common H.264 and HEVC formats that use MP4. The resulting file will have the `.mkv` extension.

## Pipelines, Automation and more powerful presets

Every action done by Clop is now part of a fully editable pipeline with steps like `optimise`, `convert`, `downscale` etc.

This allows us to always work on the original file and avoid double encoding and losing quality. It also makes backups more resilient to encoder failures.

### Automation

The fiddly Shortcuts approach for automation was replaced with a pipeline editor that can do things like:

- `on image arriving in ~/Desktop/lowtechguys`
    - -> `crop(width: 1600)` -> `optimise(encoder: lossless)`
        - -> `copy(to: "~/lowtechguys/img")` -> `convert(to: webp, location: sameFolder)`
- `on video copied to clipboard`
    - -> `crop(width: 1200)` -> `optimise(encoder: fast, location: tempFolder)`
        - -> `copyLinkForSending()`
- `on PDF arriving in ~/Downloads`
    - `if(nameContains: "invoice")` -> `copy(to: "~/Documents/Invoices/%y-%m-%d_%f")`
        - `extractPagesAsImages(format: jpeg, quality: medium, location: sameFolder)`

### Presets

Same idea for presets, they're no longer limited to running Shortcuts. They can run full pipelines which are also saved in a library for reuse in automation if needed.

Making a Preset Zone that converts the dropped image to `webp` is as simple as writing `convert(to: webp)`.

## PDF DPI control

PDF optimisation DPI can now be adjusted:

- The minus button on a PDF result opens a slider with stops at `300`, `250`, `200`, `150`, `100`, `72` and `48` DPI
    - Drag to re-run the optimisation at the chosen DPI.
- Aggressive optimisation uses **adaptive** DPI by default
    - Clop inspects the image resolutions inside each PDF and picks a DPI that compresses the most without visibly hurting quality
    - Pick a fixed value from the slider or the **PDF** settings to opt out.
- Two new settings under **PDF** let you set the default DPI for normal and aggressive optimisation
    - `300` means no downsampling.
- Pipelines accept a `dpi` parameter on the optimise step, e.g. `optimise(dpi: 150)`.

## Parallel PDF optimisation

Large PDFs (larger than 150 pages) will be split into PDFs of 100 pages and optimisation will run in parallel on those splits. This should make PDF optimisation 4x faster on large PDFs and fix cases where it might not work on >200 pages.

## Hidden results without losing the drop zone

Floating results are now optional in more places, without taking the drop zone with them.

- **Per watched folder**, toggle floating results off in the watch paths lists. Optimisation still runs, the result just doesn't pop up
- **Per pipeline**, the new `hideResult` flag lets an automation copy a file, run a Shortcut, or send something silently
- The **drop zone keeps working** even when floating results are disabled globally

## Ignore clipboard from specific apps

A new **Ignored apps** list under clipboard settings blocks selected apps from triggering optimisation.

## Improvements

- **Re-optimise with encoder...** submenu for videos, replacing the old aggressive toggle
- Dragging files from results now provides the real file path instead of a SwiftUI temp file
- Add a **Reset** button for the working directory path
- Optimised images copied to clipboard no longer trigger a second optimisation pass
- Settings now use a sidebar list instead of the old top tab bar
- Fall back to native resizing when `vipsthumbnail` fails so downscaling no longer errors out

# 2.11.6

**[Download Clop 2.11.6 →](https://files.lowtechguys.com/releases/Clop-2.11.6.dmg)**
## Fixes

- Fix *PDF Optimisation Failed* because Ghostscript was using old definitions of the encoder
- Remove the *Downscale HiDPI images to 72 DPI* setting as it is misbehaving on latest macOS 26.3

## Improvements

- Add support for HDR HEICs: they now get converted to valid HDR JPEGs

# 2.11.5

**[Download Clop 2.11.5 →](https://files.lowtechguys.com/releases/Clop-2.11.5.dmg)**
## Fixes

- Fix *PDF Optimisation Failed* because decompressing binaries might leave unwanted old files

# 2.11.4

**[Download Clop 2.11.4 →](https://files.lowtechguys.com/releases/Clop-2.11.4.dmg)**
## Fixes

- Fix PDF optimisation for the new Ghostscript version
- Fix CLI exiting prematurely after 10 minutes because of a misconfigured timeout

# 2.11.3

**[Download Clop 2.11.3 →](https://files.lowtechguys.com/releases/Clop-2.11.3.dmg)**
## Fixes

- Fix keyboard shortcuts modifiers not working correctly
- Fix iCloud watched files being duplicated or optimised in a loop in specific scenarios ([#71](https://github.com/FuzzyIdeas/Clop/pull/71))
- Improve app hang detection

# 2.11.2

**[Download Clop 2.11.2 →](https://files.lowtechguys.com/releases/Clop-2.11.2.dmg)**
## Fixes

- Fix `webp` conversion

# 2.11.1

**[Download Clop 2.11.1 →](https://files.lowtechguys.com/releases/Clop-2.11.1.dmg)**
## Fixes

- Use ImageIO to copy metadata natively when **Strip EXIF Metadata** is disabled
- Avoid bad tone mapping by not trying to preserve color profile on HDR photos *(unfortunately preserving HDR gain maps is not yet supported)*

# 2.11.0

**[Download Clop 2.11.0 →](https://files.lowtechguys.com/releases/Clop-2.11.0.dmg)**
## Features

- Add to [Dropover](https://dropoverapp.com/) by right clicking on the result
- **Convert audio to AAC** setting under the Compatibility section of the Video tab
- Update `jpegoptim` and `jpegli` encoder to fix high CPU usage and improve encoding speed
- Update `vipsthumbnail` to improve HDR image support when resizing and cropping
- Photos.app clipboard integration based on Kevin Lynagh's idea: [copy-resized-from-mac-photos-app](https://github.com/lynaghk/copy-resized-from-mac-photos-app)
    - Copy images from Photos.app to have Clop automatically optimise them, downscale to a specific size then copy them back as optimised images
    - Setting can be enabled from the *Images* tab of the *Settings* window of Clop

# 2.10.7

**[Download Clop 2.10.7 →](https://files.lowtechguys.com/releases/Clop-2.10.7.dmg)**
## Fixes

- Fix webm conversion to mp4 in specific files
- Fix high CPU usage when a video file is dropped in a watched folder and its format is not supported
- Work around macOS issue where the license code text field is not visible until clicked

# 2.10.6

**[Download Clop 2.10.6 →](https://files.lowtechguys.com/releases/Clop-2.10.6.dmg)**
## Improvements

- Improve compatibility with JPEGs that contain extraneous data
- Show filename when optimising videos in the Compact Results view
- Show when files are already fully compressed
- Add "Re-optimise" option to right-click menu

# 2.10.5

**[Download Clop 2.10.5 →](https://files.lowtechguys.com/releases/Clop-2.10.5.dmg)**
## Fixes

- Fix **Same folder** optimisation not replacing renamed file with the optimised one on videos
- Fix **Same folder** conversion creating a duplicate file of the same format

# 2.10.4

**[Download Clop 2.10.4 →](https://files.lowtechguys.com/releases/Clop-2.10.4.dmg)**
## Fixes

- Fix issue with Paddle license activation window not showing correctly

# 2.10.3

**[Download Clop 2.10.3 →](https://files.lowtechguys.com/releases/Clop-2.10.3.dmg)**
## Improvements

- Add an Internet Access Policy plist file to define network access requirements for the app (can be checked with [IAP Viewer](https://apps.apple.com/us/app/internet-access-policy-viewer/id1482630322))

## Fixes

- Fix drop zone not disappearing correctly

# 2.10.2

**[Download Clop 2.10.2 →](https://files.lowtechguys.com/releases/Clop-2.10.2.dmg)**
## Fixes

- Fix PDF optimisation on specific files
- Fix downscaling on specific systems
- Dramatically lower CPU usage in certain workloads like long-running optimisations

# 2.10.1

**[Download Clop 2.10.1 →](https://files.lowtechguys.com/releases/Clop-2.10.1.dmg)**
## Fixes

- Fix backups being cleaned up based on content modification time instead of file modification time
- Fix PDF optimisation on Intel systems

# 2.10.0

**[Download Clop 2.10.0 →](https://files.lowtechguys.com/releases/Clop-2.10.0.dmg)**
## Improvements

### PDF

- Update Ghostscript v9 to v10.05.1 to replace the old Postscript PDF interpreter and its security issues with the new C-based PDF interpreter
- Replace old JPEG encoder inside Ghostscript with the new Jpegli encoder for even smaller image-heavy PDFs

### JPEG

- Replace all remaining old JPEG encoders with the new Jpegli encoder
- Resizing and cropping should keep more visual quality now because of Jpegli being integrated into `libvips`

### CLI

- Fix double extension when using `.<extension>` in the `--output` argument

## Fixes

- Fix cropping to aspect ratio after downscaling
- Check for file validity before trying to read it
- Fix **Optimisation failed** when exporting more than 2 videos from Photos in a watched folder

# 2.9.4

**[Download Clop 2.9.4 →](https://files.lowtechguys.com/releases/Clop-2.9.4.dmg)**
## Fixes

- Fix CLI exiting prematurely after 10 minutes because of a misconfigured timeout

# 2.9.3

**[Download Clop 2.9.3 →](https://files.lowtechguys.com/releases/Clop-2.9.3.dmg)**
## Fixes

- Prevent "Recovered files" from appearing by closing the file descriptors on process exit
- Fix color profile not being completely preserved

# 2.9.2

**[Download Clop 2.9.2 →](https://files.lowtechguys.com/releases/Clop-2.9.2.dmg)**
## Improvements

- Keep the restore button showing in the floating result, even if it's disabled
- Force player set to QuickTime if it was previously set to Clop wrongly by macOS

## Fixes

- Fix downscaling factor not being reset between clipboard operations
- Add support for WEBM and MKV files that were registered by IINA

# 2.9.1

**[Download Clop 2.9.1 →](https://files.lowtechguys.com/releases/Clop-2.9.1.dmg)**
## Fixes

- Fix DPI not being kept between optimisations

# 2.9.0

**[Download Clop 2.9.0 →](https://files.lowtechguys.com/releases/Clop-2.9.0.dmg)**
## Improvements

- Better quality on downscaling and cropping images
- Sort `Open with...` apps alphabetically
- Show output and errors of encoders in the logs
- Honor the **Ignore images/videos with extension** setting when copying images/videos

## Fixes

- Ignore transient and concealed clipboard types for videos and PDF paths as well
- Allow click through the Compact Results window when it is hidden
- Properly restore originals in the case of video conversion

# 2.8.7

**[Download Clop 2.8.7 →](https://files.lowtechguys.com/releases/Clop-2.8.7.dmg)**
## Features

- Allow tapping Control instead of holding it for showing Preset Zones

## Improvements

- More visible styling for Preset Zones
- Ignore transient and concealed clipboard types

## Fixes

- Proactively change the window sharing type when `Show Clop UI in screenshots` is toggled
- Fix **Same folder** name template not adding extension to the file

# 2.8.6

**[Download Clop 2.8.6 →](https://files.lowtechguys.com/releases/Clop-2.8.6.dmg)**
## Fixes

- Fix optimisation of copied images from browsers

# 2.8.5

**[Download Clop 2.8.5 →](https://files.lowtechguys.com/releases/Clop-2.8.5.dmg)**
## Improvements

- Fix WPS Office non-image data optimisation

# 2.8.4

**[Download Clop 2.8.4 →](https://files.lowtechguys.com/releases/Clop-2.8.4.dmg)**
## Hotfix 2.8.4

- Fix shell quoting issue in Shortcuts command

## Fixes

- Fix possible crash on file events
- Fix PDF getting deleted on specific failed optimizations
- Fix shell quoting issue in Shortcuts command

## Improvements

- Add support for dragging videos from Photos.app into the drop zone
- Add `Downscale` action in Shortcuts

# 2.8.3

**[Download Clop 2.8.3 →](https://files.lowtechguys.com/releases/Clop-2.8.3.dmg)**
## Fixes

- Fix possible crash on file events
- Fix PDF getting deleted on specific failed optimizations

## Improvements

- Add support for dragging videos from Photos.app into the drop zone
- Add `Downscale` action in Shortcuts

# 2.8.2

**[Download Clop 2.8.2 →](https://files.lowtechguys.com/releases/Clop-2.8.2.dmg)**
## Hotfix 2.8.2

- Fix **Add Preset** button not working in the **Drop Zone** settings
- Fix "Check for updates" window not focusing
- Fix shortcut picker overlapping the type field

# 2.8.1

**[Download Clop 2.8.1 →](https://files.lowtechguys.com/releases/Clop-2.8.1.dmg)**
## Features

### Drop zone presets

*Do multiple actions in one go by setting up drop zone presets.*

<video width=500 src="https://files.lowtechguys.com/clop-presets.mp4" autoplay loop muted playsinline disablepictureinpicture></video>

You can now configure the drop zone to automatically pass the optimised file through an Apple Shortcut when a file is dropped on it.

## Improvements

- Add support for DJI drone video optimisation
- Make adaptive optimisation faster by computing entropy on JPEGs first
- Workaround for a problem with the Finder **Optimise with Clop** extension that can result in missing files
- Add default **Watermark image** Shortcut for automations and presets

# 2.8.0

**[Download Clop 2.8.0 →](https://files.lowtechguys.com/releases/Clop-2.8.0.dmg)**
## Features

### Drop zone presets

*Do multiple actions in one go by setting up drop zone presets.*

<video width=500 src="https://files.lowtechguys.com/clop-presets.mp4" autoplay loop muted playsinline disablepictureinpicture></video>

You can now configure the drop zone to automatically pass the optimised file through an Apple Shortcut when a file is dropped on it.

## Improvements

- Add support for DJI drone video optimisation
- Make adaptive optimisation faster by computing entropy on JPEGs first
- Workaround for a problem with the Finder **Optimise with Clop** extension that can result in missing files
- Add default **Watermark image** Shortcut for automations and presets

# 2.7.2

**[Download Clop 2.7.2 →](https://files.lowtechguys.com/releases/Clop-2.7.2.dmg)**
## Fixes

- Fix Cleanshot screenshots being optimised only before annotations and not after
- Fix "Restore Original" not working correctly for specific PNG and JPEG images

# 2.7.1

**[Download Clop 2.7.1 →](https://files.lowtechguys.com/releases/Clop-2.7.1.dmg)**
## Improvements

- Make picker buttons more visible in the settings UI
- Keep folders sorted in the Automations tab
- Ignore both `.jpg` and `.jpeg` files when **jpeg** is enabled for skipping

# 2.7.0

**[Download Clop 2.7.0 →](https://files.lowtechguys.com/releases/Clop-2.7.0.dmg)**
## Features

- Keep color profile when stripping EXIF metadata
- Integration with [Dockside](https://hachipoo.com/dockside-app) and [Yoink](https://eternalstorms.at/yoink/mac/) for file shelving

## Improvements

- Ignore Final Cut Pro drags
- Stop using temp folder to avoid getting "Recovered Items" folder after reboot
- Ensure Clop doesn't end up as the default MP4 opener app
- Add iPhone 16 Pro for PDF crop sizes

# 2.6.5

**[Download Clop 2.6.5 →](https://files.lowtechguys.com/releases/Clop-2.6.5.dmg)**
## Improvements

- Do the binary decompression asynchronously on first launch
- Settings UI improvements on macOS Sequoia
- Improve onboarding

## Fixes

- Ignore vectorial Freeform clipboard data

# 2.6.4

**[Download Clop 2.6.4 →](https://files.lowtechguys.com/releases/Clop-2.6.4.dmg)**
## Fixes

- Fix working directory being cleaned up too aggressively
- Fix activation window appearing in the wrong place
- Fix license code field not being editable sometimes
- Fix additional operations not working on a converted video

# 2.6.3

**[Download Clop 2.6.3 →](https://files.lowtechguys.com/releases/Clop-2.6.3.dmg)**
## Features

- Add new menu items:
    - **Open working directory**: opens the folder where Clop stores intermediate images/videos/PDFs
    - **Force clean working directory**: deletes the working directory and re-creates it in case there are filesystem errors
- Add Clop as destination for **"Open with..."** and **"Edit with..."** menu items of files

## Fixes

- Fix video optimisation when video does not have any audio
- Fix dropzone not appearing sometimes

# 2.6.2

**[Download Clop 2.6.2 →](https://files.lowtechguys.com/releases/Clop-2.6.2.dmg)**
## Notice

The current macOS Sequoia version has capped the settings contents to a width of 600px for some reason.
There seems to be no way to get around this, for now I'll wait and see if the next macOS update will revert the change.

## Improvements

- Add **Show Clop UI in screenshots** setting in the menu

## Fixes

- Ensure folders are left alone when cleaning up workdir
- Fix Settings window not opening

# 2.6.1

**[Download Clop 2.6.1 →](https://files.lowtechguys.com/releases/Clop-2.6.1.dmg)**
## Improvements

- Always check and recreate workdir folder structure if it gets deleted by external processes
    - This helps with keeping Clop running instead of showing *Optimisation failed* randomly
- Keep all audio tracks instead of just one when optimising video files (fixes #34)

## Fixes

- Fix some macOS Sequoia styling issues
- Fix EXIF stripping on latest macOS Sequoia

# 2.6.0

**[Download Clop 2.6.0 →](https://files.lowtechguys.com/releases/Clop-2.6.0.dmg)**
## Side-by-side comparison

You can now compare images, videos and PDFs side by side to see the difference between the original and the optimised version.

- right click on the thumbnail and click **Compare**
- or hover the thumbnail and press `Cmd-D`

<video controls src="https://files.lowtechguys.com/clop-compare-view-release-demo.mp4" width=1800></video>

## Optimised file location

There is now a way to set where the optimised files will be placed:

- **Temporary folder**: they will be placed in the system temp folder that gets cleaned up periodically by the system
- **In-place (replace original)**: the default, moves the original file into Clop's backup folder and replaces it with the optimised file
- **Same folder (as original)**: places the optimised file alongside the original, renaming it based on the configured template
- **Specific folder**: places the optimised file in a specific path anywhere on disk, configured with a template

<video controls src="https://files.lowtechguys.com/clop-optimised-file-location-release-demo.mp4" width=481></video>

## Flexible template paths for the `--output` CLI

When using commands like `clop optimise --output <some path>`, the output path now uses the new templating engine.

To understand this better, here are some examples when resizing the PNG files on Desktop using something like:

```css
# the command is being run from ~/Documents/
~/Documents ❯ clop crop --size 1600x900 --output <template> ~/Desktop/screenshots/*.png
```

... where `<template>` can be:

- `resized_to_%z` -> path relative to current dir, places files in `~/Documents/resized_to_1600x900/`
- `~/Pictures/twitter/%f_%z.%e` -> absolute path, files will get paths like `~/Pictures/twitter/shot_1600x900.png`
- `%P/../twitter/` -> path relative to image dir, places files in `~/Desktop/twitter/`


## Features

- Use the new **[Jpegli](https://opensource.googleblog.com/2024/04/introducing-jpegli-new-jpeg-coding-library.html?hnid=39920644)** perceptive encoder from Google for even smaller JPEG images
- Update `ffmpeg` to version 7.0 for better video encoding
- Allow configuring the location where Clop stores temporary files and backups and when to clean up files
- Allow disabling floating results UI
- The global `Ctrl-Shift-P` hotkey can now toggle between:
    - **Running**: Clop is listening to clipboard and file events
    - **Paused**: Clop is paused for the next clipboard/file event and will resume automatically
    - **Stopped**: All automatic optimisations are stopped until manually resumed by user


## Improvements

- Add `--adaptive-optimisation` and `--no-adaptive-optimisation` options to CLI commands that can act on images
- Speed up PNG optimisation by using `pngquant`'s `--speed 3` option
- Improve EXIF metadata handling when optimising images and videos
- Detect files that are in progress of being created/modified and wait for the operation to settle before optimising

## Fixes

- Fix `--downscale-factor` parsing on `clop optimise` CLI
- Fix automation not triggering shortcuts for videos and PDFs
- Fix: if a previously optimised file was replaced with a new file, an old backup was being used for optimisations instead of the new file
- Fix creation/modification date not being preserved for videos

# 2.5.5

**[Download Clop 2.5.5 →](https://files.lowtechguys.com/releases/Clop-2.5.5.dmg)**
## Features

- Add `--types` and `--exclude-types` options to CLI commands that can act on multiple types of files

## Fixes

- Don't optimise copied PDF paths
- Fix selecting WEBP format would instead select AVIF

# 2.5.4

**[Download Clop 2.5.4 →](https://files.lowtechguys.com/releases/Clop-2.5.4.dmg)**
## Features

- **Bring back default sizes** button in the crop sizes popover
- **Smart**/**Center** framing selector in the crop popover
- Multiplier buttons for the crop size
- Image format selector

![image format selector](https://files.lowtechguys.com/image-format-selector.jpeg)

## Fixes

- Notarize all utility binaries to avoid macOS warnings
- Fix `HEIC` conversion

# 2.5.3

**[Download Clop 2.5.3 →](https://files.lowtechguys.com/releases/Clop-2.5.3.dmg)**
## Features

- Add `clop crop --smart-crop` option to use smart crop instead of center crop
- Allow using aspect ratio in `clop crop` command *(e.g. clop crop --size 16:9 *.png)*

## Improvements

- Show final resolution in the `clop crop` output
- Ignore and show error on encrypted PDFs

## Fixes

- Fix Clop CLI not working in the Setapp build

# 2.5.2

**[Download Clop 2.5.2 →](https://files.lowtechguys.com/releases/Clop-2.5.2.dmg)**
## Improvements

- Compress more types of PDFs *(even without aggressive optimisation needed)*

# 2.5.1

**[Download Clop 2.5.1 →](https://files.lowtechguys.com/releases/Clop-2.5.1.dmg)**
## Features

- Implement `clop convert` CLI command for easy converting to `avif`, `heic` and `webp` formats

## Fixes

- Fix app hang on computing file hash
- Fix app hang on specific clipboard optimisation cases
- Fix unwanted app restarts
- Fix file output template on the Convert action

# 2.5.0

**[Download Clop 2.5.0 →](https://files.lowtechguys.com/releases/Clop-2.5.0.dmg)**
## Features

- Colorize CLI output
- Add `--json` flag to CLI to output JSON instead of a human-readable list
- Add `clop strip-exif` command to strip EXIF data from images and videos
- Add *Strip EXIF metadata* to right-click menu on results
- Add `Convert to...` to right-click menu on results, supporting:
    - avif
    - webp
    - heic
- Add **Convert image to...** Shortcut
- Allow dragging folders into the drop zone
    - Optimises all images, videos and PDFs from the folder and its subfolders
    - Press `⌥ Option` once while dragging the folder to make the drop zone appear

<video width=576 height=360 src="https://files.lowtechguys.com/dragging-folder-dropzone.mp4" controls title="demo video of dragging a folder into the drop zone"></video>

## Improvements

- Disable **Adaptive optimisation** by default to avoid confusion on why PNGs are suddenly converted to JPEGs and vice versa
    - This setting can still be enabled manually in the **Images** tab of the **Settings** window
- Detect the correct number of Media Engine video encode cores
- Extract more metadata from videos when copying EXIF data between them
- Use a timeout of 5 seconds on xattrs instead of letting the app hang indefinitely
- Check for spurious file change events on first launch

## Fixes

- Fix side button tooltip appearing behind the thumbnail
- Fix memory leaks and improve performance on batch processing
- Fix missing DPI and color profile metadata from optimised JPEGs
- Don't optimise clipboard coming from copying Excel cells in Parallels

# 2.4.0

**[Download Clop 2.4.0 →](https://files.lowtechguys.com/releases/Clop-2.4.0.dmg)**
## Features

- Crop by aspect ratio
- Crop PDFs from the UI
- Batch cropping from the UI

<video autoplay controls loop muted playsinline disablepictureinpicture width=712 height=466>
    <source src="https://files.lowtechguys.com/clop-batch-cropping-ui-h265.mp4" type="video/mp4; codecs=hvc1">
    <source src="https://files.lowtechguys.com/clop-batch-cropping-ui-h264.mp4" type="video/mp4">
</video>

## Improvements

- **Compact Results** re-styling: better contrast and more visual organization
- Allow *already optimised* files to be dropped for subsequent actions (cropping, downscaling, uploading etc.)
- Create an image pile when dragging them to the drop zone
- Follow *Converted image location* setting for adaptive optimisation on PNG and JPEG
    - If `in-place` is selected, PNGs will be **replaced** with JPEGs if smaller, and vice-versa

## Fixes

- Fix app hang when sharing a file
- Fix settings window appearing on NSService action when menubar icon is hidden

## Coming soon..

- Better image compression with `webp` and `avif` outputs
- Raycast extension and Alfred workflow

# 2.3.1

**[Download Clop 2.3.1 →](https://files.lowtechguys.com/releases/Clop-2.3.1.dmg)**
## Improvements

- Store `.clopignore` rules per file type (image, video, PDF)

## Fixes

- Create directories with full permissions for multi-user support
- Fix first rename action failing
- Disable `Strip EXIF` for HEICs to avoid invalid files

# 2.3.0

**[Download Clop 2.3.0 →](https://files.lowtechguys.com/releases/Clop-2.3.0.dmg)**
## Features

- **Remove audio** from videos
    - available as an automated setting, or manually through right click on the result
- **Strip EXIF Metadata** system service

![strip exif service](https://files.lowtechguys.com/strip-exif-service.png)

- **Preserve creation and modification dates** for optimised files

![preserve dates](https://files.lowtechguys.com/preserve-dates-setting.png)

- Hold `Option` while dragging files to the drop zone to keep the originals untouched
- **Batch actions** in Compact Results

<video autoplay controls loop muted playsinline disablepictureinpicture width=600>
    <source src="https://files.lowtechguys.com/batch-actions-select-clop-h265.mp4" type="video/mp4; codecs=hvc1">
    <source src="https://files.lowtechguys.com/batch-actions-select-clop-h264.mp4" type="video/mp4">
</video>


## Fixes

- Fix CLI relative path on `--output`
- Fix click through blocked when some floating results are not removed properly from the screen

# 2.2.7

**[Download Clop 2.2.7 →](https://files.lowtechguys.com/releases/Clop-2.2.7.dmg)**
## Fixes

- Fix `Ctrl-O` in Finder not optimising file in-place
- Ignore *Universal Clipboard* images

# 2.2.6

**[Download Clop 2.2.6 →](https://files.lowtechguys.com/releases/Clop-2.2.6.dmg)**
## Improvements

- Add **Share** submenu to the right click menu
- Add `uncrop-pdf` command to the CLI to reverse the `crop-pdf` command

## Fixes

- Fix `--output` on `crop-pdf` not working correctly
- Fix landscape `--resolution` and `--aspect-ratio` creating the wrong page layout in `crop-pdf`

# 2.2.5

**[Download Clop 2.2.5 →](https://files.lowtechguys.com/releases/Clop-2.2.5.dmg)**
## Features

### **Upload with [Dropshare](https://dropshare.app/)**

You can now upload optimised files to any cloud or server using [the Dropshare app](https://dropshare.app/).

Hover over the floating Clop result and press `Cmd`-`U` (or right click and choose *Upload with Dropshare*) to send the file to Dropshare.

![upload with dropshare option](https://files.lowtechguys.com/clop_2023-10-17_498.png)

Dropshare also integrates Clop directly, so if you use it to take screenshots, you can now have them optimised automatically before uploading.

*the feature is only in the beta version of Dropshare at the moment of this update*

![dropshare integration with clop](https://files.lowtechguys.com/clop_2023-10-17_499.png)

### [Clop SDK](https://github.com/FuzzyIdeas/ClopSDK)

You can now optimise images, videos and PDFs in your own app using the Clop SDK.

Example code:

*Swift*
```swift
import ClopSDK

guard ClopSDK.shared.waitForClopToBeAvailable() else {
    print("Clop is not available")
    return
}

try ClopSDK.shared.optimise(path: "AppData/image.png")
```

*Objective-C*
```objc
@import ClopSDK;

ClopSDKObjC *clop = [ClopSDKObjC shared];
if (![clop waitForClopToBeAvailableFor:5]) {
    return;
}

[clop optimiseWithPath:@"AppData/img.png" error:nil];
```


*This is not exactly a feature inside Clop, but I thought it might be a good idea to let people know in case someone is an app developer and wants to integrate Clop in their app.*

## Improvements

- Add "Crop PDF" Shortcut
- Add `--output` parameter for the CLI
- ADd `--aggressive` parameter in the CLI commands where it was missing
- ADd `--page-layout` parameter for the `crop-pdf` CLI command
- Add `Output path` parameter for Shortcuts

## Fixes

- Fix `--playback-speed-factor` CLI option
- Fix `Ctrl`-`C` not stopping optimisation
- Fix CLI acting on the wrong file if it was backed up before

# 2.2.4

**[Download Clop 2.2.4 →](https://files.lowtechguys.com/releases/Clop-2.2.4.dmg)**
## Features

- Setting to hide drop zone by default, show when manually pressing the `⌥ Option` key

![drop zone setting](https://files.lowtechguys.com/clop_2023-10-14_471.png)

## Improvements

- Show dock icon when opening Settings window

## Fixes

- Allow JIT to work in libvips binaries *(fixes downscaling in Intel builds)*
- Lower bundle size by compressing `x86` and `arm` binaries together
- Fix crash on optimise hotkey
- Fix possible multiplication overflow crash
- Fix Crop shortcut requesting Size value when both Width and Height are specified

# 2.2.3

**[Download Clop 2.2.3 →](https://files.lowtechguys.com/releases/Clop-2.2.3.dmg)**
## Fixes

- Fix always showing *"v2.2.2 update available"*
- Fix binaries being unarchived in the wrong folder

# 2.2.2

**[Download Clop 2.2.2 →](https://files.lowtechguys.com/releases/Clop-2.2.2.dmg)**
## Features

* Add **Pause automatic optimisations** option in the menubar
* Add support for `--long-edge` flag to `clop crop` command

```bash
  -l, --long-edge         When the size is specified as a single number, it will crop the longer of width or height to that number.
                          The shorter edge will be calculated automatically while keeping the original aspect ratio.

                          Example: `clop crop --long-edge --size 1920` will crop a landscape 2400x1350 image to 1920x1080, and a portrait 1350x2400 image to 1080x1920
```

## Improvements

* Show when an update is available as a subtle button below the floating results

## Fixes

- Fix downscaling and cropping on Intel
- Show message when CLI is already installed

# 2.2.1

**[Download Clop 2.2.1 →](https://files.lowtechguys.com/releases/Clop-2.2.1.dmg)**
## Improvements

- Allow using `0` for width/height for cropping to the original aspect ratio

## Fixes

- Fix PNG optimisation because of a code signing error
- Hide ignore rules after deleting a watch path
- Fix Pro limits still being set to 2 on the drop zone (they're now set to 5)

# 2.2.0

**[Download Clop 2.2.0 →](https://files.lowtechguys.com/releases/Clop-2.2.0.dmg)**
## Features

- **PDF** optimisation
- **Strip EXIF** metadata
- Auto Copy to clipboard for *dropped* and *watched* files after optimisation
- Settings sync between Macs via iCloud
- Right click menu with `⌘ Command` hotkeys on hover
- **Speed up video** function
- Ignore rules for watched folders
- Template for auto naming of clipboard images
- Finder action: **Optimise with Clop**
- **Automation**: run Shortcuts on optimised files
- Command-line Interface (CLI) for optimising files
- Convert video to GIF using [gifski](https://github.com/ImageOptim/gifski)
- Compact results list when processing more than 5 files
- Click on resolution to crop to a specific size

## Improvements

- Skip optimisations when more than 1 file is copied to clipboard
- Skip optimisations when more than `x` files are dropped in watched folders
- Make aggressive GIF optimisation more space saving by limiting colors to 256
- Implement optimisation on dropped file promises
- Better handling of optimisations that result in larger files
- Cleanup of optimiser processes on crash or forced termination


## Fixes

- Don't show drop zone in settings floating results preview
- Fix GIF optimisation (yet again)
- Fix interference with other drop zone apps like Yoink, Dropzone, Dropshare etc.
- Fix params for aggressive video optimisation

# 2.1.3

**[Download Clop 2.1.3 →](https://files.lowtechguys.com/releases/Clop-2.1.3.dmg)**
## Fixes

- Fix optimisation on copied JPEGs as `public.png`

# 2.1.2

**[Download Clop 2.1.2 →](https://files.lowtechguys.com/releases/Clop-2.1.2.dmg)**
## Improvements

- Make app uninstallable from Launchpad

## Fixes

- Fix adaptive optimisation not working on all images
- Some files were getting ignored because of the new "converted file location" setting

# 2.1.1

**[Download Clop 2.1.1 →](https://files.lowtechguys.com/releases/Clop-2.1.1.dmg)**
## Features

- Drop zone for drag-and-drop file optimisation

<video autoplay controls loop muted playsinline disablepictureinpicture width=600>
    <source src="https://files.lowtechguys.com/clop-drop-zone-demo-h265.mp4" type="video/mp4; codecs=hvc1">
    <source src="https://files.lowtechguys.com/clop-drop-zone-demo-h264.mp4" type="video/mp4">
</video>


- More control of the clipboard optimiser

![more clipboard settings](https://files.lowtechguys.com/clop-more-clipboard-settings.jpeg)

- More control on where the converted files are placed

![converted files location setting](https://files.lowtechguys.com/clop-converted-file-location.png)

## Improvements

- Better scoring formula for video adaptive optimisation *(should result in less CPU usage on high workload videos)*
- Easier to read text on floating results
- Restart on crash or app hang (some crashes/hangs are unavoidable)
- Log to system console

## Fixes

- **Optimising clipboard data should now leave the original files untouched**
- Fix GIF optimisation
- Fix resolution being 72x higher on JPEGs without a defined DPI
- Bringing back removed results would also bring back notices and error messages
- Destroy previously removed results after a while to free up memory

# 2.0.3

**[Download Clop 2.0.3 →](https://files.lowtechguys.com/releases/Clop-2.0.3.dmg)**
## Features

- Automatic downscaling of Retina images to `1x`

![Downscale retina images setting](https://files.lowtechguys.com/clop-downscale-retina.png)

## Improvements

- Preserve EXIF metadata (helps keep the original DPI for retina images and videos)

# 2.0.2

**[Download Clop 2.0.2 →](https://files.lowtechguys.com/releases/Clop-2.0.2.dmg)**
## Fixes

- Fix HEIC file watching optimiser
- Fix removing the last path from the file watcher list

# 2.0.1

**[Download Clop 2.0.1 →](https://files.lowtechguys.com/releases/Clop-2.0.1.dmg)**
## Features

- Add `About...` menu item
- Allow capping video FPS to specific values

![cap fps setting](https://files.lowtechguys.com/clop-cap-fps.png)

## Fixes

- Stop unwanted automatic optimisation of already existing files

# 2.0.0

**[Download Clop 2.0.0 →](https://files.lowtechguys.com/releases/Clop-2.0.0.dmg)**
Introducing **Clop Pro**: freemium with an **$8** paid tier as a one-time purchase.

Still fully open source as GPLv3 for anyone to tinker with it.

## Features in **v2**:

- **Video optimisation** using the hardware encoder *(uses the dedicated Media Engine chip on Apple Silicon for little to no CPU usage)*
- **Downscale** images and videos on the fly
- **Hotkeys** for useful actions
	- Downscale to any percentage from `10%` to `90%` with a single keystroke
	- Restore original image/video
	- Quicklook the last optimised item
	- Pause optimiser for next copy
	- Optimise current clipboard if it's an URL/file path/ignored image etc.
- **Path watching**: optimise any file created inside configured folders
- **Floating thumbnails**: make it easy to see which item was optimised and allow interactions like:
	- Drag and drop the thumbnail anywhere to insert it
	- Swipe to dismiss
	- Buttons for Quicklook, Restore, Downscale etc.
- **URL optimisation**: download and optimise images and videos from links
- **macOS Shortcuts** support
- **Aggressive optimisation** for squeezing more bits when needed

# 1.0.0

**[Download Clop 1.0.0 →](https://files.lowtechguys.com/releases/Clop-1.0.0.dmg)**
Completely free version before the Pro features were introduced. Suitable for people who liked the simplicity and lack of customization of this version.

## Features:

- Watch the clipboard for `.png`, `.jpeg` and `.gif` images *(not paths, it had to be image data)*
- Ignore copied data coming from most graphical editors
- Optimise the images and copy them back to the clipboard
- Show a simple notification with the size savings in the bottom right corner of the screen
