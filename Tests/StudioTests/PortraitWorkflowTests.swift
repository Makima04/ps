import XCTest
import ColorEngine
@testable import Ps

@MainActor final class QuickPortraitTests: XCTestCase {
    func testQuickRecipeIsRepeatableAndKeepsPhotoOwnedRepairs() throws {
        var existing = Adjustments()
        let spot = RepairSpot(source:MaskPoint(x:0.3,y:0.3),target:MaskPoint(x:0.4,y:0.4),radius:0.002)
        existing.repairSpots = [spot]; existing.exposure = 0.8
        let options = PortraitIntent()
        let first = try PortraitWorkflow.settings(options,existing:existing,reference:nil)
        let second = try PortraitWorkflow.settings(options,existing:first,reference:nil)
        XCTAssertEqual(first,second,"重复处理不能叠加同样的图层")
        XCTAssertEqual(first.layers.count,2)
        XCTAssertEqual(first.repairSpots,[spot])
        XCTAssertEqual(first.exposure,0,"快速流程从目标重新计算，不复制旧曝光偏移")
        XCTAssertNotNil(first.layers.first { $0.mask == .lips }?.lipReference?.lips?.appearance)
        var other = existing; other.repairSpots = nil
        let otherResult = try PortraitWorkflow.settings(options,existing:other,reference:nil)
        XCTAssertEqual(first.skinReference,otherResult.skinReference)
        XCTAssertEqual(first.layers,otherResult.layers)
        XCTAssertNil(otherResult.repairSpots)
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self,from:JSONEncoder().encode(first)),first)
        XCTAssertNil(try JSONDecoder().decode(Adjustments.self,from:Data("{}".utf8)).portraitIntent)
    }

    func testIntentControlsRealGoalsAndRejectsMissingReference() throws {
        var a = PortraitIntent()
        let low = try PortraitWorkflow.settings(a,existing:Adjustments(),reference:nil)
        a.brightness = 0.9; a.softness = 0.8; a.lipStrength = 0.2
        let high = try PortraitWorkflow.settings(a,existing:Adjustments(),reference:nil)
        XCTAssertGreaterThan(high.skinReference!.template.targetLightness,low.skinReference!.template.targetLightness)
        XCTAssertGreaterThan(high.layers[0].adjustments.skinSmoothing,low.layers[0].adjustments.skinSmoothing)
        XCTAssertEqual(high.layers[1].adjustments.lipAdaptation,0.2)
        a.look = .original
        let original = try PortraitWorkflow.settings(a,existing:Adjustments(),reference:nil)
        XCTAssertEqual(original.skinReference?.colorAmount,0)
        XCTAssertEqual(original.skinReference?.lightnessAmount,0)
        XCTAssertEqual(original.skinReference?.chromaCompensation,0)
        a.useReference = true
        XCTAssertThrowsError(try PortraitWorkflow.settings(a,existing:Adjustments(),reference:nil))
        a.useReference = false; a.brightness = .nan
        XCTAssertThrowsError(try PortraitWorkflow.settings(a,existing:Adjustments(),reference:nil))
    }

    func testSavedReferenceCanBeAdjustedWithoutReselectingLibraryEntry() throws {
        let reference = try PortraitWorkflow.softPink()
        var options = PortraitIntent(); options.useReference = true; options.lip = .reference
        let applied = try options.settings(existing:Adjustments(),reference:reference)
        options.softness = 0.4
        let edited = try options.settings(existing:applied)
        XCTAssertEqual(edited.skinReference?.template,reference)
        XCTAssertEqual(edited.layers[1].lipReference,reference)
    }

    func testQuickBatchRunsPerPhotoAndIsOneUndoableEdit() async throws {
        guard let folder = ProcessInfo.processInfo.environment["PS_TEST_PHOTO_DIR"] else {
            throw XCTSkip("Set PS_TEST_PHOTO_DIR for the quick workflow integration check")
        }
        let source = URL(fileURLWithPath:folder).appendingPathComponent("DSC00681.JPG").resolvingSymlinksInPath()
        let other = source.deletingLastPathComponent().appendingPathComponent("DSC00735.JPG")
        guard FileManager.default.fileExists(atPath:other.path) else { throw XCTSkip("Second portrait not available") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:temp) }
        var first = Photo(url:source)
        let spot = RepairSpot(source:MaskPoint(x:0.3,y:0.3),target:MaskPoint(x:0.4,y:0.4),radius:0.001)
        first.settings.repairSpots = [spot]
        let project = Project(photos:[first,Photo(url:other)])
        let storage = temp.appendingPathComponent("project.json")
        try JSONEncoder().encode(project).write(to:storage)
        let studio = Studio(storageURL:storage)
        studio.history.groupsByEvent = false
        studio.runPortrait(all:true)
        for _ in 0..<900 where studio.portraitBusy { try await Task.sleep(for:.milliseconds(100)) }
        XCTAssertFalse(studio.portraitBusy)
        XCTAssertNil(studio.alert)
        XCTAssertTrue(studio.project.photos.allSatisfy { $0.settings.portraitIntent != nil && $0.portraitSummary != nil })
        XCTAssertEqual(studio.project.photos[0].settings.repairSpots?.first,spot)
        XCTAssertFalse(studio.project.photos[1].settings.repairSpots?.contains(spot) ?? false)
        XCTAssertEqual(studio.project.photos[0].settings.skinReference,studio.project.photos[1].settings.skinReference)
        studio.undo()
        XCTAssertEqual(studio.project,project)
        studio.runPortrait(all:true); studio.cancelPortrait()
        for _ in 0..<100 where studio.portraitBusy { try await Task.sleep(for:.milliseconds(50)) }
        XCTAssertFalse(studio.portraitBusy)
        XCTAssertEqual(studio.project,project,"取消不能留下半套处理结果")
    }
}
