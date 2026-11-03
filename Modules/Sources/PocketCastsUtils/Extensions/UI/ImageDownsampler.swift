import CoreGraphics
import ImageIO
import UIKit

/// Decodes images straight to a smaller size with ImageIO, so large artwork never has to be decoded at
/// full size first. Podcast feeds commonly ship 3000x3000 artwork, which takes about 36 MB once decoded,
/// enough to get a widget, the watch app or the phone app with a screen full of artwork killed for using
/// too much memory.
public enum ImageDownsampler {
    /// Returns the image in `data` decoded so its longest side is at most `maxPixelSize` pixels.
    ///
    /// Returns nil when the image is already within that size, or when the data can't be read as an image,
    /// so callers can fall back to their usual decoding and small images behave exactly as before.
    public static func downsampledImage(from data: Data, maxPixelSize: CGFloat, scale: CGFloat = 1) -> UIImage? {
        guard maxPixelSize.isFinite, maxPixelSize >= 1, scale.isFinite, scale > 0 else { return nil }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let pixelSize = pixelSize(of: source),
              max(pixelSize.width, pixelSize.height) > maxPixelSize else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: thumbnail, scale: scale, orientation: .up)
    }

    /// Returns the image in `data` decoded at no more than `maxPixelSize` pixels on its longest side,
    /// decoding it normally when it's already within that size. Returns nil if the data isn't an image.
    public static func image(from data: Data, maxPixelSize: CGFloat, scale: CGFloat = 1) -> UIImage? {
        if let image = downsampledImage(from: data, maxPixelSize: maxPixelSize, scale: scale) {
            return image
        }

        return UIImage(data: data, scale: scale)
    }

    /// Returns `data` re-encoded at no more than `maxPixelSize` pixels on its longest side, as JPEG when the
    /// image has no transparency and PNG when it does.
    ///
    /// Returns nil when the image is already within that size or can't be read, so callers can keep the
    /// original data unchanged.
    public static func downsampledData(from data: Data, maxPixelSize: CGFloat) -> Data? {
        guard let image = downsampledImage(from: data, maxPixelSize: maxPixelSize),
              let alphaInfo = image.cgImage?.alphaInfo else {
            return nil
        }

        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image.jpegData(compressionQuality: 0.9)
        default:
            return image.pngData()
        }
    }

    private static func pixelSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else {
            return nil
        }

        return CGSize(width: width, height: height)
    }
}
