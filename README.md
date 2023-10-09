<p align="center">
    <a href="https://lowtechguys.com/clop"><img width="128" height="128" src="Clop/Assets.xcassets/clop.imageset/clop_256.png" style="filter: drop-shadow(0px 2px 4px rgba(80, 50, 6, 0.2));"></a>
    <h1 align="center"><code style="text-shadow: 0px 3px 10px rgba(8, 0, 6, 0.35); font-size: 3rem; font-family: ui-monospace, Menlo, monospace; font-weight: 800; background: transparent; color: #4d3e56; padding: 0.2rem 0.2rem; border-radius: 6px">Clop</code></h1>
    <h4 align="center" style="padding: 0; margin: 0; font-family: ui-monospace, monospace;">Image, video, PDF and clipboard optimiser</h4>
    <h6 align="center" style="padding: 0; margin: 0; font-family: ui-monospace, monospace; font-weight: 400;">Copy large, paste small, send fast</h6>
</p>

<p align="center">
    <a href="https://files.lowtechguys.com/releases/Clop.dmg">
        <img width=300 src="https://files.alinpanaitiu.com/download-button-dark.svg">
    </a>
</p>

## Optimise images as soon as you copy them

As long as the Clop app is running, every time you copy an image to your **clipboard**, Clop will **optimise** it to the **smallest possible size**.

The optimised image will have minimal to zero loss in quality, and will be **ready to paste** in any app.

## Screen recordings as small as screenshots

Sending screen recordings becomes 10x faster with Clop. The app will optimise the video as soon as you stop recording.

The video will be available as a **floating thumbnail**, ready for you to **drag and drop** in any app.

Clop can use Apple Silicon's dedicated **Media Engine chip** for battery-efficient video encoding without using the CPU.

## Downscale in a pinch

Get images and videos ready for sharing by scaling them down to any resolution.

Use handy hotkeys or the floating buttons to downscale the image or video and get an even smaller file size.

* <kbd>-</kbd> downscales incrementally from 90% until 10% of the original resolution
* <kbd>1</kbd>..<kbd>9</kbd> are for downscaling to specific sizes

## Power user features

### 1. On-demand optimisation

Press `Ctrl`-`Shift`-`C` to manually optimise the current clipboard.

The action works on *images*, *video* files, *paths*, *URLs*, even base64 encoded images.

For more aggressive optimisation, `Ctrl`-`Shift`-`A` is also available.


### 2. Compatible formats

Clop automatically **converts** less compatible formats like `HEIC`, `tiff`, `mov` to formats understood by most devices.

The conversion is fully configurable from the app settings.

Original files are kept in a backup folder which can be accessed from the app menu.


### 3. macOS Shortcuts

Integrate Clop optimisation in your workflows through **native macOS Shortcuts**.

- Downscale and optimise images that you email weekly
- Download optimised images directly into your slideshow
- ..and so on


## Free vs Pro

Free version features are free **forever**.

After the **14-day trial**, the app will continue to work with the free features.


| Feature | Clop Pro | Free version |
|---------|----------|--------------|
| Clipboard optimisation | ✅ | ✅ |
| Downscale images | ✅ | ✅ |
| Optimise screen recordings | ✅ | 5 per session |
| Optimise screenshot files | ✅ | 5 per session |
| On-demand optimisation | ✅ | 5 per session |
| Shortcuts support | ✅ | 5 per session |


## Technical details

Clop uses the following open source tools for optimising files, images and videos:

* `pngquant` for PNG
* `jpegoptim` for JPEG
* `gifsicle` for GIF
* `ffmpeg` for videos
* `libvips` for resizing images
* `gifski` for converting videos to GIFs
* `ghostscript` for optimising PDFs

It may also use `libvips` for resizing images if it is installed on your system.

The app is licensed under [GPLv3](https://github.com/FuzzyIdeas/Clop/blob/main/LICENSE.md).

## What's up with the hat?

*Clop* is the Romanian word for a traditional straw hat with a high crown and raised conical brim, worn more as an adorment in days of celebration.

We thought *"**Cl**ipboard **Op**timizer"* sounds a bit too technical and doesn't roll off the tongue as easily. We're <b style="color: red">Rom</b><b style="color: yellow">an</b><b style="color: blue">ian</b> ourselves and we thought it might be a good idea to keep the memory of our traditions from dying completely, with whatever little we can do.
