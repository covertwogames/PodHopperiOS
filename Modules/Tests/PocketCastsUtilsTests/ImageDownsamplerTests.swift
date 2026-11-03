import UIKit
import XCTest

@testable import PocketCastsUtils

final class ImageDownsamplerTests: XCTestCase {
    func testLargeImageIsDownsampledToTheLongestSide() throws {
        let data = try XCTUnwrap(makeImage(size: CGSize(width: 2000, height: 1000)).jpegData(compressionQuality: 0.8))

        let image = try XCTUnwrap(ImageDownsampler.downsampledImage(from: data, maxPixelSize: 500))

        XCTAssertEqual(image.size, CGSize(width: 500, height: 250))
    }

    func testImageWithinTheSizeIsLeftToTheCaller() throws {
        let data = try XCTUnwrap(makeImage(size: CGSize(width: 300, height: 300)).pngData())

        XCTAssertNil(ImageDownsampler.downsampledImage(from: data, maxPixelSize: 500))
        XCTAssertNil(ImageDownsampler.downsampledData(from: data, maxPixelSize: 500))
        XCTAssertEqual(ImageDownsampler.image(from: data, maxPixelSize: 500)?.size, CGSize(width: 300, height: 300))
    }

    func testInvalidDataReturnsNil() {
        let data = Data("not an image".utf8)

        XCTAssertNil(ImageDownsampler.downsampledImage(from: data, maxPixelSize: 500))
        XCTAssertNil(ImageDownsampler.downsampledData(from: data, maxPixelSize: 500))
        XCTAssertNil(ImageDownsampler.image(from: data, maxPixelSize: 500))
    }

    func testDownsampledDataDecodesAtTheSmallerSize() throws {
        let data = try XCTUnwrap(makeImage(size: CGSize(width: 1200, height: 1200)).jpegData(compressionQuality: 0.8))

        let smaller = try XCTUnwrap(ImageDownsampler.downsampledData(from: data, maxPixelSize: 400))

        XCTAssertEqual(UIImage(data: smaller)?.size, CGSize(width: 400, height: 400))
    }

    private func makeImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
