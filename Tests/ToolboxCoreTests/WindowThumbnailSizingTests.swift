import Foundation
import XCTest
@testable import ToolboxCore

final class WindowThumbnailSizingTests: XCTestCase {
    func testRetinaPreviewUsesDisplayDemandInsteadOfOldLowResolutionCap() throws {
        let size = try XCTUnwrap(WindowThumbnailSizing.dimensions(
            sourcePointSize: CGSize(width: 1200, height: 800), sourceScale: 2,
            maximumPixelSize: CGSize(width: 1400, height: 900), candidateCount: 12))
        XCTAssertEqual(size, .init(width: 1350, height: 900))
    }

    func testSourceResolutionPreventsFakeUpscaling() throws {
        let size = try XCTUnwrap(WindowThumbnailSizing.dimensions(
            sourcePointSize: CGSize(width: 120, height: 80), sourceScale: 1,
            maximumPixelSize: CGSize(width: 1200, height: 800), candidateCount: 1))
        XCTAssertEqual(size, .init(width: 120, height: 80))
        let retina = try XCTUnwrap(WindowThumbnailSizing.dimensions(
            sourcePointSize: CGSize(width: 120, height: 80), sourceScale: 2,
            maximumPixelSize: CGSize(width: 1200, height: 800), candidateCount: 1))
        XCTAssertEqual(retina, .init(width: 240, height: 160))
    }

    func testPortraitWindowKeepsItsAspectRatioWithoutBakedPadding() throws {
        let size = try XCTUnwrap(WindowThumbnailSizing.dimensions(
            sourcePointSize: CGSize(width: 400, height: 1200), sourceScale: 2,
            maximumPixelSize: CGSize(width: 1000, height: 700), candidateCount: 12))
        XCTAssertEqual(size, .init(width: 233, height: 700))
    }

    func testLargeCaptureIsCappedPerImage() throws {
        let size = try XCTUnwrap(WindowThumbnailSizing.dimensions(
            sourcePointSize: CGSize(width: 4000, height: 2500), sourceScale: 2,
            maximumPixelSize: CGSize(width: 8000, height: 5000), candidateCount: 1))
        XCTAssertEqual(size, .init(width: 1600, height: 1000))
    }

    func testFullSessionStaysInsideAggregatePixelBudget() throws {
        let size = try XCTUnwrap(WindowThumbnailSizing.dimensions(
            sourcePointSize: CGSize(width: 4000, height: 2500), sourceScale: 2,
            maximumPixelSize: CGSize(width: 8000, height: 5000), candidateCount: 24))
        XCTAssertLessThan(size.width, 1600)
        XCTAssertLessThanOrEqual(size.pixelCount * WindowThumbnailSizing.imageLimit,
                                 WindowThumbnailSizing.maximumCachePixels)
        XCTAssertLessThanOrEqual(size.pixelCount, WindowThumbnailSizing.pixelsPerImage(candidateCount: 24))
        XCTAssertEqual(WindowThumbnailSizing.pixelsPerImage(candidateCount: 1000),
                       WindowThumbnailSizing.pixelsPerImage(candidateCount: 24))
    }

    func testInvalidSourceAndDemandCannotReachIntegerConversion() {
        let valid = CGSize(width: 1000, height: 700)
        let invalid = [CGSize.zero, CGSize(width: -1, height: 10),
                       CGSize(width: CGFloat.nan, height: 10), CGSize(width: 10, height: CGFloat.infinity)]
        for size in invalid {
            XCTAssertNil(WindowThumbnailSizing.dimensions(sourcePointSize: size, sourceScale: 2,
                maximumPixelSize: valid, candidateCount: 1))
            XCTAssertNil(WindowThumbnailSizing.dimensions(sourcePointSize: valid, sourceScale: 2,
                maximumPixelSize: size, candidateCount: 1))
        }
        for scale in [CGFloat.zero, -1, CGFloat.nan, CGFloat.infinity] {
            XCTAssertNil(WindowThumbnailSizing.dimensions(sourcePointSize: valid, sourceScale: scale,
                maximumPixelSize: valid, candidateCount: 1))
        }
    }
}
