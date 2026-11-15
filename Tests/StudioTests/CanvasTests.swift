import AppKit
import XCTest
@testable import Ps

@MainActor
final class CanvasTests: XCTestCase {
    func testFitZoomAndPhysicalPixelZoomPreserveDocumentGeometry() {
        let scroll = CanvasScrollView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        scroll.contentView = CenteredClipView()
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.02
        scroll.maxMagnification = 8
        // A 4000x6000 image at Retina backing scale 2.
        let canvas = CanvasImageView(frame: CGRect(x: 0, y: 0, width: 2000, height: 3000))
        scroll.documentView = canvas
        scroll.layoutSubtreeIfNeeded()
        scroll.desiredZoom = 0
        scroll.updateZoom()
        let fit = min(scroll.contentView.frame.width / 2000, scroll.contentView.frame.height / 3000)
        XCTAssertEqual(scroll.magnification, fit, accuracy: 0.001)
        XCTAssertLessThan(scroll.magnification, 0.3)
        scroll.desiredZoom = 1
        scroll.updateZoom()
        XCTAssertEqual(scroll.magnification, 1, accuracy: 0.0001)
        XCTAssertLessThan(scroll.documentVisibleRect.width, canvas.bounds.width)
        XCTAssertLessThan(scroll.documentVisibleRect.height, canvas.bounds.height)
        scroll.desiredZoom = 2
        scroll.updateZoom()
        XCTAssertEqual(scroll.magnification, 2, accuracy: 0.0001)
        XCTAssertEqual(canvas.frame.size, CGSize(width: 2000, height: 3000))
        scroll.desiredZoom = 20
        scroll.updateZoom()
        XCTAssertEqual(scroll.magnification, 8, accuracy: 0.0001)
        scroll.desiredZoom = 0
        scroll.updateZoom()
        XCTAssertEqual(scroll.magnification, fit, accuracy: 0.001)
    }
}
