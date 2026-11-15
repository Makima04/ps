import XCTest
@testable import ColorEngine

final class PhotoSourceTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func touch(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data([0x00]).write(to: url)
        return url
    }

    /// A JPEG path is upgraded to the paired ARW for pixels, while the JPEG
    /// remains the analysis/metadata reference.
    func testJPEGIsUpgradedToPairedRAW() throws {
        let jpeg = try touch("DSC00681.JPG")
        let raw = try touch("DSC00681.ARW")

        let source = PhotoSource.resolve(jpeg)
        XCTAssertEqual(source.imageURL.lastPathComponent, raw.lastPathComponent)
        XCTAssertEqual(source.analysisURL.lastPathComponent, jpeg.lastPathComponent)
        XCTAssertEqual(source.metadataURL.lastPathComponent, jpeg.lastPathComponent)
        XCTAssertTrue(source.isRAW)
        XCTAssertTrue(source.hasPairedJPEG)
    }

    /// The legacy JPEG-only pipeline stays available on demand.
    func testJPEGOnlyFallback() throws {
        let jpeg = try touch("DSC00681.JPG")
        _ = try touch("DSC00681.ARW")

        let source = PhotoSource.resolve(jpeg, preferRAW: false)
        XCTAssertEqual(source.imageURL.lastPathComponent, jpeg.lastPathComponent)
        XCTAssertEqual(source.analysisURL.lastPathComponent, jpeg.lastPathComponent)
        XCTAssertFalse(source.isRAW)
    }

    /// A lone JPEG (no ARW anywhere) must still work untouched.
    func testLoneJPEG() throws {
        let jpeg = try touch("DSC00681.JPG")
        let source = PhotoSource.resolve(jpeg)
        XCTAssertEqual(source.imageURL.lastPathComponent, jpeg.lastPathComponent)
        XCTAssertEqual(source.analysisURL.lastPathComponent, jpeg.lastPathComponent)
        XCTAssertFalse(source.isRAW)
        XCTAssertFalse(source.hasPairedJPEG)
    }

    /// A lone ARW (no camera JPEG) must also work: masks fall back to RAW pixels.
    func testLoneRAW() throws {
        let raw = try touch("DSC00681.ARW")
        let source = PhotoSource.resolve(raw)
        XCTAssertEqual(source.imageURL.lastPathComponent, raw.lastPathComponent)
        XCTAssertEqual(source.analysisURL.lastPathComponent, raw.lastPathComponent)
        XCTAssertTrue(source.isRAW)
        XCTAssertFalse(source.hasPairedJPEG)
    }

    /// Passing the ARW directly still finds the camera JPEG for detection.
    func testRAWInputKeepsJPEGForAnalysis() throws {
        let raw = try touch("DSC00681.ARW")
        let jpeg = try touch("DSC00681.JPG")
        let source = PhotoSource.resolve(raw)
        XCTAssertEqual(source.imageURL.lastPathComponent, raw.lastPathComponent)
        XCTAssertEqual(source.analysisURL.lastPathComponent, jpeg.lastPathComponent)
        XCTAssertTrue(source.isRAW)
    }

    /// Catalog folders use symlinks; the ARW lives next to the real source file.
    func testSymlinkedCatalogFolder() throws {
        let originals = folder.appendingPathComponent("100MSDCF")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let realJPEG = originals.appendingPathComponent("DSC00681.JPG")
        let realRAW = originals.appendingPathComponent("DSC00681.ARW")
        try Data([0x00]).write(to: realJPEG)
        try Data([0x00]).write(to: realRAW)

        let catalog = folder.appendingPathComponent("JPEG")
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        let link = catalog.appendingPathComponent("DSC00681.JPG")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realJPEG)

        let source = PhotoSource.resolve(link)
        XCTAssertEqual(source.imageURL.lastPathComponent, realRAW.lastPathComponent)
        XCTAssertEqual(source.analysisURL.lastPathComponent, realJPEG.lastPathComponent)
        XCTAssertTrue(source.isRAW)
    }

    /// New lip fields must round-trip while old saved projects still decode.
    func testLipParametersAreBackwardCompatible() throws {
        let legacy = try XCTUnwrap(#"{"exposure":0.3,"layers":[]}"#.data(using: .utf8))
        let oldSettings = try JSONDecoder().decode(Adjustments.self, from: legacy)
        XCTAssertEqual(oldSettings.exposure, 0.3)
        XCTAssertEqual(oldSettings.global.lipNaturalization, 0)

        var current = Adjustments()
        var lips = AdjustmentLayer(mask: .lips)
        lips.adjustments.lipNaturalization = 0.6
        current.layers.append(lips)
        let encoded = try JSONEncoder().encode(current)
        let decoded = try JSONDecoder().decode(Adjustments.self, from: encoded)
        XCTAssertEqual(decoded.layers.first?.mask, .lips)
        XCTAssertEqual(decoded.layers.first?.adjustments.lipNaturalization, 0.6)
    }
}
