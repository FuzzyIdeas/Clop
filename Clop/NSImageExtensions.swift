//
//  NSImageExtensions.swift
//  Clop
//
//  Created by Alin Panaitiu on 12.07.2023.
//

import Cocoa
import CoreGraphics
import CoreImage
import Foundation
import Lowtech

extension CGImage {
    func gamma(_ power: Float) -> CGImage? {
        let ciImage = CIImage(cgImage: self)
        guard let filter = CIFilter(name: "CIGammaAdjust") else {
            return nil
        }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(power, forKey: "inputPower")

        guard let outputCIImage = filter.outputImage else {
            return nil
        }

        let context = CIContext()

        guard let cgImage = context.createCGImage(outputCIImage, from: outputCIImage.extent) else {
            return nil
        }

        return cgImage
    }
}

extension NSImage {
    var realSize: NSSize {
        guard let rep = representations.first else {
            return size
        }

        return NSSize(width: rep.pixelsWide ?! size.width.i, height: rep.pixelsHigh ?! size.height.i)
    }

    /// The height of the image.
    var height: CGFloat {
        realSize.height
    }

    /// The width of the image.
    var width: CGFloat {
        realSize.width
    }

    /// A PNG representation of the image.
    var pngData: Data? {
        if let tiff = tiffRepresentation, let tiffData = NSBitmapImageRep(data: tiff) {
            return tiffData.representation(using: .png, properties: [.compressionFactor: 1.0])
        }

        return nil
    }

    var jpegData: Data? {
        if let tiff = tiffRepresentation, let tiffData = NSBitmapImageRep(data: tiff) {
            return tiffData.representation(using: .jpeg, properties: [.compressionFactor: 1.0])
        }

        return nil
    }

    var gifData: Data? {
        if let tiff = tiffRepresentation, let tiffData = NSBitmapImageRep(data: tiff) {
            return tiffData.representation(using: .gif, properties: [.compressionFactor: 1.0])
        }

        return nil
    }

    func resize(withSize targetSize: NSSize) -> NSImage? {
        let frame = NSRect(x: 0, y: 0, width: targetSize.width, height: targetSize.height)
        let ctx = NSGraphicsContext.current
        ctx?.imageInterpolation = .high
        guard let representation = bestRepresentation(for: frame, context: ctx, hints: nil) else {
            return nil
        }
        let image = NSImage(size: targetSize, flipped: false, drawingHandler: { _ -> Bool in
            representation.draw(in: frame)
        })

        return image
    }

    func linear() -> CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)?.gamma(1.0 / 2.2)
    }

    func nonLinear() -> CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)?.gamma(2.2)
    }

    func resize(to targetSize: CGSize) -> NSImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
        guard let image = linear() else {
            return nil
        }

        let context = CGContext(
            data: nil,
            width: targetSize.width.evenInt,
            height: targetSize.height.evenInt,
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: image.colorSpace ?? colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.interpolationQuality = .high
        context?.draw(image, in: CGRect(origin: .zero, size: targetSize))

        guard let scaledImage = context?.makeImage()?.gamma(2.2) else { return nil }

        return NSImage(cgImage: scaledImage, size: targetSize)
    }

    func resizedTo(width: Double, height: Double) -> NSImage? {
        resize(to: NSSize(width: width.evenInt, height: height.evenInt))
    }

    /// Copy the image and resize it to the supplied size, while maintaining it's
    /// original aspect ratio.
    ///
    /// - Parameter size: The target size of the image.
    /// - Returns: The resized image.
    func resizeMaintainingAspectRatio(to targetSize: NSSize) -> NSImage? {
        let newSize: NSSize
        let widthRatio = targetSize.width / width
        let heightRatio = targetSize.height / height

        if widthRatio > heightRatio {
            newSize = NSSize(
                width: floor(width * widthRatio),
                height: floor(height * widthRatio)
            )
        } else {
            newSize = NSSize(
                width: floor(width * heightRatio),
                height: floor(height * heightRatio)
            )
        }
        return resize(to: newSize)
    }

    // MARK: Cropping

    /// Resize the image, to nearly fit the supplied cropping size
    /// and return a cropped copy the image.
    ///
    /// - Parameter size: The size of the new image.
    /// - Returns: The cropped image.
    func crop(toSize targetSize: NSSize) -> NSImage? {
        guard let resizedImage = resizeMaintainingAspectRatio(to: targetSize) else {
            return nil
        }
        let x = floor((resizedImage.width - targetSize.width) / 2)
        let y = floor((resizedImage.height - targetSize.height) / 2)
        let frame = NSRect(x: x, y: y, width: targetSize.width, height: targetSize.height)

        guard let representation = resizedImage.bestRepresentation(for: frame, context: nil, hints: nil) else {
            return nil
        }

        let image = NSImage(
            size: targetSize,
            flipped: false,
            drawingHandler: { (destinationRect: NSRect) -> Bool in
                representation.draw(in: destinationRect)
            }
        )

        return image
    }

    // MARK: Saving

    /// Save the images PNG representation the the supplied file URL:
    ///
    /// - Parameter url: The file URL to save the png file to.
    /// - Throws: An unwrappingPNGRepresentationFailed when the image has no png representation.
    func save(format: NSBitmapImageRep.FileType, to url: URL) throws {
        if let data = data(using: format) {
            try data.write(to: url, options: .atomicWrite)
        } else {
            throw NSImageExtensionError.unwrappingRepresentationFailed
        }
    }

    func data(using type: NSBitmapImageRep.FileType) -> Data? {
        switch type {
        case .png:
            pngData
        case .jpeg:
            jpegData
        case .gif:
            gifData
        default:
            pngData
        }
    }
}

enum NSImageExtensionError: Error {
    case unwrappingRepresentationFailed
}
