import CoreGraphics
import XCTest
@testable import ColorEngine

final class AnalysisSnapshotTests: XCTestCase {
    func testSnapshotInvalidationOnInputOrAlgorithmChange() {
        let url = URL(fileURLWithPath: "/tmp/sample.jpg")
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let baseInput = AnalysisInputFingerprint(
            url: url,
            fileSize: 1024,
            modifiedAt: modified,
            pixelWidth: 4000,
            pixelHeight: 6000,
            isRAW: true
        )
        let snapshot = AnalysisSnapshot(
            input: baseInput,
            algorithmVersion: .current,
            faces: [
                FaceSnapshot(
                    index: 0,
                    bounds: CGRect(x: 1000, y: 2000, width: 600, height: 800),
                    hasLandmarks: true,
                    availableRegions: [.skin, .lips, .leftCheek, .rightCheek]
                )
            ]
        )

        XCTAssertTrue(snapshot.isValid(for: baseInput))

        let resizedInput = AnalysisInputFingerprint(
            url: url,
            fileSize: 2048,
            modifiedAt: modified,
            pixelWidth: 4000,
            pixelHeight: 6000,
            isRAW: true
        )
        XCTAssertFalse(snapshot.isValid(for: resizedInput))

        let bumpedVersion = AnalysisAlgorithmVersion(
            semanticParser: "0.5.0-sapiens2",
            blemishDetector: AnalysisAlgorithmVersion.current.blemishDetector,
            skinRefinement: AnalysisAlgorithmVersion.current.skinRefinement
        )
        XCTAssertFalse(snapshot.isValid(for: baseInput, version: bumpedVersion))
    }

    func testSnapshotCodableRoundTrip() throws {
        let input = AnalysisInputFingerprint(
            url: URL(fileURLWithPath: "/tmp/portrait.jpg"),
            fileSize: 4096,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_500),
            pixelWidth: 3000,
            pixelHeight: 4000,
            isRAW: false
        )
        let snapshot = AnalysisSnapshot(
            input: input,
            faces: [],
            blemishSensitivity: 0.5,
            blemishes: BlemishAnalysis(candidates: [], warnings: ["未检测到可靠人脸"]),
            warnings: ["未检测到可靠人脸"]
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AnalysisSnapshot.self, from: data)
        XCTAssertEqual(decoded.input, snapshot.input)
        XCTAssertEqual(decoded.algorithmVersion, snapshot.algorithmVersion)
        XCTAssertEqual(decoded.warnings, snapshot.warnings)
    }
}
