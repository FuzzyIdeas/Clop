#!/bin/bash
# Generate test fixture files for ClopTests
# Requires: ffmpeg, sips (macOS built-in), and optionally cwebp/heif-enc from Clop's bin dir
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Generating test fixtures in $SCRIPT_DIR"

# --- Generate base PNG (1200x1200 gradient) using Swift/CoreGraphics ---
if [ ! -f sample.png ]; then
    swift - <<'SWIFT'
import Cocoa

let size = NSSize(width: 1200, height: 1200)
let image = NSImage(size: size)
image.lockFocus()

// Draw a gradient background
let gradient = NSGradient(colors: [.red, .green, .blue, .yellow])!
gradient.draw(in: NSRect(origin: .zero, size: size), angle: 45)

// Draw some shapes for visual variety
NSColor.white.withAlphaComponent(0.5).setFill()
NSBezierPath(ovalIn: NSRect(x: 100, y: 100, width: 400, height: 400)).fill()
NSColor.black.withAlphaComponent(0.5).setFill()
NSBezierPath(rect: NSRect(x: 600, y: 600, width: 400, height: 400)).fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Failed to create PNG\n", stderr)
    exit(1)
}

let url = URL(fileURLWithPath: "sample.png")
try png.write(to: url)
print("Created sample.png")
SWIFT
fi

# --- JPEG from PNG ---
if [ ! -f sample.jpg ]; then
    sips -s format jpeg -s formatOptions 90 sample.png --out sample.jpg >/dev/null 2>&1
    echo "Created sample.jpg"
fi

# --- TIFF from PNG ---
if [ ! -f sample.tiff ]; then
    sips -s format tiff sample.png --out sample.tiff >/dev/null 2>&1
    echo "Created sample.tiff"
fi

# --- WebP (try cwebp, fall back to sips on macOS 14+) ---
if [ ! -f sample.webp ]; then
    if command -v cwebp &>/dev/null; then
        cwebp -q 80 sample.png -o sample.webp 2>/dev/null
        echo "Created sample.webp (cwebp)"
    elif sips -s format com.google.webp sample.png --out sample.webp 2>/dev/null; then
        echo "Created sample.webp (sips)"
    else
        echo "SKIP: sample.webp (no cwebp or compatible sips)"
    fi
fi

# --- HEIC (try sips) ---
if [ ! -f sample.heic ]; then
    if sips -s format heic sample.png --out sample.heic 2>/dev/null; then
        echo "Created sample.heic"
    else
        echo "SKIP: sample.heic (sips doesn't support HEIC output)"
    fi
fi

# --- AVIF (try avifenc or sips) ---
if [ ! -f sample.avif ]; then
    if command -v avifenc &>/dev/null; then
        avifenc sample.png sample.avif 2>/dev/null
        echo "Created sample.avif (avifenc)"
    else
        echo "SKIP: sample.avif (no avifenc)"
    fi
fi

# --- Videos (require ffmpeg) ---
if command -v ffmpeg &>/dev/null; then
    FFMPEG=ffmpeg
elif [ -f "$HOME/Library/Application Scripts/com.lowtechguys.Clop/bin/arm64/ffmpeg" ]; then
    FFMPEG="$HOME/Library/Application Scripts/com.lowtechguys.Clop/bin/arm64/ffmpeg"
elif [ -f "$HOME/Library/Application Scripts/com.lowtechguys.Clop/bin/x86/ffmpeg" ]; then
    FFMPEG="$HOME/Library/Application Scripts/com.lowtechguys.Clop/bin/x86/ffmpeg"
else
    FFMPEG=""
fi

if [ -n "$FFMPEG" ]; then
    # MP4: 1280x720, 2s, with audio
    if [ ! -f sample.mp4 ]; then
        "$FFMPEG" -y -f lavfi -i "testsrc2=duration=2:size=1280x720:rate=30" \
            -f lavfi -i "sine=frequency=440:duration=2" \
            -c:v libx264 -preset ultrafast -c:a aac -b:a 64k \
            -pix_fmt yuv420p -movflags +faststart \
            sample.mp4 2>/dev/null
        echo "Created sample.mp4"
    fi

    # MOV: 1280x720, 2s, with audio
    if [ ! -f sample.mov ]; then
        "$FFMPEG" -y -f lavfi -i "testsrc2=duration=2:size=1280x720:rate=30" \
            -f lavfi -i "sine=frequency=440:duration=2" \
            -c:v libx264 -preset ultrafast -c:a aac -b:a 64k \
            -pix_fmt yuv420p \
            sample.mov 2>/dev/null
        echo "Created sample.mov"
    fi

    # GIF: 400x400, few frames
    if [ ! -f sample.gif ]; then
        "$FFMPEG" -y -f lavfi -i "testsrc2=duration=1:size=400x400:rate=10" \
            -vf "split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" \
            sample.gif 2>/dev/null
        echo "Created sample.gif"
    fi
    # WAV: 2s 440Hz sine, 16-bit PCM
    if [ ! -f sample.wav ]; then
        "$FFMPEG" -y -f lavfi -i "sine=frequency=440:duration=2" \
            -c:a pcm_s16le sample.wav 2>/dev/null
        echo "Created sample.wav"
    fi

    # FLAC: 2s 440Hz sine
    if [ ! -f sample.flac ]; then
        "$FFMPEG" -y -f lavfi -i "sine=frequency=440:duration=2" \
            -c:a flac sample.flac 2>/dev/null
        echo "Created sample.flac"
    fi

    # AIFF: 2s 440Hz sine
    if [ ! -f sample.aiff ]; then
        "$FFMPEG" -y -f lavfi -i "sine=frequency=440:duration=2" \
            -c:a pcm_s16be sample.aiff 2>/dev/null
        echo "Created sample.aiff"
    fi

    # MP3: 2s 440Hz sine at 320kbps (high bitrate for optimisation testing)
    if [ ! -f sample.mp3 ]; then
        "$FFMPEG" -y -f lavfi -i "sine=frequency=440:duration=2" \
            -c:a libmp3lame -b:a 320k sample.mp3 2>/dev/null
        echo "Created sample.mp3"
    fi

    # M4A (AAC): 2s 440Hz sine at 256kbps
    if [ ! -f sample.m4a ]; then
        "$FFMPEG" -y -f lavfi -i "sine=frequency=440:duration=2" \
            -c:a aac -b:a 256k sample.m4a 2>/dev/null
        echo "Created sample.m4a"
    fi

    # OGG (Opus): 2s 440Hz sine at 128kbps
    if [ ! -f sample.ogg ]; then
        "$FFMPEG" -y -f lavfi -i "sine=frequency=440:duration=2" \
            -c:a libopus -b:a 128k sample.ogg 2>/dev/null
        echo "Created sample.ogg"
    fi
else
    echo "SKIP: video fixtures (no ffmpeg found)"
    echo "SKIP: audio fixtures (no ffmpeg found)"
fi

# --- PDF: 3 pages with colored rectangles ---
if [ ! -f sample.pdf ]; then
    swift - <<'SWIFT'
import Cocoa
import PDFKit

let pdfDoc = PDFDocument()
let colors: [NSColor] = [.systemRed, .systemGreen, .systemBlue]
let pageSize = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter

for (i, color) in colors.enumerated() {
    let page = PDFPage()
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { continue }

    var mediaBox = pageSize
    context.beginPage(mediaBox: &mediaBox)

    // Background
    context.setFillColor(NSColor.white.cgColor)
    context.fill(pageSize)

    // Colored rectangle
    context.setFillColor(color.cgColor)
    context.fill(CGRect(x: 50, y: 50, width: 512, height: 692))

    // Add text
    let text = "Test Page \(i + 1)" as NSString
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 36),
        .foregroundColor: NSColor.white,
    ]
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    text.draw(at: NSPoint(x: 200, y: 400), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()

    context.endPage()
    context.closePDF()

    if let provider = CGDataProvider(data: data as CFData),
       let cgPDF = CGPDFDocument(provider),
       let newPage = PDFPage(image: NSImage(size: pageSize.size, flipped: false, drawingHandler: { rect in
           guard let ctx = NSGraphicsContext.current?.cgContext,
                 let pdfPage = cgPDF.page(at: 1) else { return false }
           ctx.drawPDFPage(pdfPage)
           return true
       }))
    {
        pdfDoc.insert(newPage, at: i)
    }
}

let url = URL(fileURLWithPath: "sample.pdf")
pdfDoc.write(to: url)
print("Created sample.pdf (\(pdfDoc.pageCount) pages)")
SWIFT
fi

echo "Done! Fixtures generated."
ls -la sample.* 2>/dev/null || echo "No fixtures found"
