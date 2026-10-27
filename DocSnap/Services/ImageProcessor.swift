import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit

/// Turns a stored original photo into the finished page: crop → rotate → filter.
/// Everything here is pure and thread-safe, so call it off the main thread.
enum ImageProcessor {
    static let context = CIContext(options: [.cacheIntermediates: false])

    /// Longest edge kept for stored originals. A 13 Pro photo is 4032 px; this keeps full detail.
    static let maxStoredDimension: CGFloat = 4096

    // MARK: - Whole pipeline

    static func process(_ original: CGImage, page: ScanPage) -> CGImage? {
        process(original, quad: page.quad, rotation: page.rotation, filter: page.filter)
    }

    static func process(_ original: CGImage, quad: Quad, rotation: Int, filter: ScanFilter) -> CGImage? {
        var image = CIImage(cgImage: original)
        image = perspectiveCorrected(image, quad: quad)
        image = rotated(image, quarterTurns: rotation)
        image = applying(filter, to: image)
        return render(image)
    }

    // MARK: - Steps

    /// Crops and flattens the quad into a rectangle. `quad` uses a top-left origin.
    static func perspectiveCorrected(_ image: CIImage, quad: Quad) -> CIImage {
        guard !quad.isFull, quad.isValid else { return image }
        let e = image.extent
        // Core Image has a bottom-left origin.
        func ci(_ p: CGPoint) -> CGPoint {
            CGPoint(x: e.minX + p.x * e.width, y: e.minY + (1 - p.y) * e.height)
        }
        let f = CIFilter.perspectiveCorrection()
        f.inputImage = image
        f.topLeft = ci(quad.topLeft)
        f.topRight = ci(quad.topRight)
        f.bottomRight = ci(quad.bottomRight)
        f.bottomLeft = ci(quad.bottomLeft)
        guard let out = f.outputImage, out.extent.width >= 1, out.extent.height >= 1 else { return image }
        return out.movedToOrigin()
    }

    /// Rotates clockwise by `quarterTurns` × 90°.
    static func rotated(_ image: CIImage, quarterTurns: Int) -> CIImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        let orientation: CGImagePropertyOrientation
        switch turns {
        case 1: orientation = .right
        case 2: orientation = .down
        case 3: orientation = .left
        default: return image
        }
        return image.oriented(orientation).movedToOrigin()
    }

    static func applying(_ filter: ScanFilter, to image: CIImage) -> CIImage {
        switch filter {
        case .original:
            return image
        case .grayscale:
            return colorControls(image, saturation: 0, contrast: 1.1, brightness: 0.02)
        case .lighten:
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = image
            exposure.ev = 0.7
            return colorControls(exposure.outputImage ?? image, saturation: 1.05, contrast: 1.05, brightness: 0)
        case .magicColor:
            // Divide out uneven lighting so paper turns white and ink keeps its color.
            let flat = flattenedLighting(image)
            let stretched = levels(flat, black: 0.06, white: 0.92)
            return colorControls(stretched, saturation: 1.25, contrast: 1.08, brightness: 0)
        case .blackWhite:
            let gray = colorControls(image, saturation: 0, contrast: 1, brightness: 0)
            let flat = flattenedLighting(gray)
            // Steep (not hard) threshold keeps anti-aliased text edges. Values are in linear light.
            return levels(flat, black: 0.32, white: 0.62)
        }
    }

    // MARK: - Rendering / IO

    static func render(_ image: CIImage) -> CGImage? {
        // Round inward: rounding a fractional perspective extent outward adds a transparent
        // row/column that becomes a black line in the JPEG.
        let e = image.extent
        let minX = e.minX.rounded(.up), minY = e.minY.rounded(.up)
        let extent = CGRect(x: minX, y: minY, width: e.maxX.rounded(.down) - minX, height: e.maxY.rounded(.down) - minY)
        guard extent.width >= 1, extent.height >= 1, extent.width.isFinite, extent.height.isFinite else { return nil }
        return context.createCGImage(image, from: extent)
    }

    static func jpegData(_ image: CGImage, quality: CGFloat = 0.85) -> Data? {
        UIImage(cgImage: image).jpegData(compressionQuality: quality)
    }

    /// Redraws a camera/photos image upright (orientation `.up`) and caps its size, so pixel
    /// coordinates match what the user sees and stored files never depend on EXIF orientation.
    static func normalizedCGImage(_ image: UIImage, maxDimension: CGFloat = maxStoredDimension) -> CGImage? {
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard pixelSize.width >= 1, pixelSize.height >= 1 else { return nil }
        let factor = min(1, maxDimension / max(pixelSize.width, pixelSize.height))
        if image.imageOrientation == .up, factor == 1, let cg = image.cgImage {
            return cg
        }
        let target = CGSize(width: (pixelSize.width * factor).rounded(), height: (pixelSize.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard // 8-bit; the P3 default can allocate 16-bit buffers
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }.cgImage
    }

    /// Loads an image file, optionally downsampled so the longest edge is at most `maxPixelSize`.
    /// Downsampling via ImageIO avoids decoding a full 12 MP image just to draw a thumbnail.
    static func loadCGImage(at url: URL, maxPixelSize: CGFloat? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        guard let maxPixelSize else {
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize)),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Helpers

    private static func colorControls(_ image: CIImage, saturation: Float, contrast: Float, brightness: Float) -> CIImage {
        let f = CIFilter.colorControls()
        f.inputImage = image
        f.saturation = saturation
        f.contrast = contrast
        f.brightness = brightness
        return f.outputImage ?? image
    }

    /// Linear stretch: `black` maps to 0, `white` to 1, clamped.
    private static func levels(_ image: CIImage, black: CGFloat, white: CGFloat) -> CIImage {
        let scale = 1 / max(white - black, 0.01)
        let bias = -black * scale
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        m.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: 0, y: scale, z: 0, w: 0)
        m.bVector = CIVector(x: 0, y: 0, z: scale, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        m.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = m.outputImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return (clamp.outputImage ?? image).cropped(to: image.extent)
    }

    /// Estimates the paper's background brightness (text removed by dilation, then blurred)
    /// and divides the image by it. Removes shadows and lighting gradients.
    static func flattenedLighting(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let longest = max(extent.width, extent.height)
        guard longest >= 16 else { return image }
        // Work on a small copy: the background varies slowly, and big blurs are expensive.
        let small = min(1, 512 / longest)
        let reduced = image.transformed(by: CGAffineTransform(scaleX: small, y: small))
        let smallLongest = longest * small

        let dilate = CIFilter.morphologyMaximum()
        dilate.inputImage = reduced.clampedToExtent()
        dilate.radius = Float(max(2, smallLongest / 60))

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = dilate.outputImage
        blur.radius = Float(max(2, smallLongest / 40))

        guard let blurred = blur.outputImage else { return image }
        let background = blurred
            .transformed(by: CGAffineTransform(scaleX: 1 / small, y: 1 / small))
            .cropped(to: extent)

        let divide = CIFilter.divideBlendMode()
        divide.inputImage = background          // divisor
        divide.backgroundImage = image          // dividend → result = image / background
        return (divide.outputImage ?? image).cropped(to: extent)
    }
}

private extension CIImage {
    func movedToOrigin() -> CIImage {
        transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }
}
