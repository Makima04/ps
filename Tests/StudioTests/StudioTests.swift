import XCTest
import ColorEngine
@testable import Ps

@MainActor
final class StudioTests: XCTestCase {
    func testBlemishReviewIsPhotoLocalAndUndoable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = folder.appendingPathComponent("project.json")
        let first = Photo(url: folder.appendingPathComponent("first.jpg"))
        var second = Photo(url: folder.appendingPathComponent("second.jpg"))
        let own = RepairSpot(source:MaskPoint(x:0.2,y:0.2),target:MaskPoint(x:0.3,y:0.3),radius:0.01)
        second.settings.repairSpots = [own]
        try JSONEncoder().encode(Project(photos:[first,second])).write(to:storage)
        let studio = Studio(storageURL:storage)
        studio.history.groupsByEvent = false
        let repair = RepairSpot(source:MaskPoint(x:0.4,y:0.4),target:MaskPoint(x:0.5,y:0.5),radius:0.01)
        let red = BlemishCandidate(faceIndex:0,kind:.redSpot,score:0.95,target:repair.target,radius:repair.radius,repair:repair)
        let dark = BlemishCandidate(faceIndex:0,kind:.darkSpot,score:0.99,target:repair.target,radius:repair.radius,repair:repair)
        var colourRepair = repair; colourRepair.mode = .sampledSkin
        let yellow = BlemishCandidate(faceIndex:0,kind:.yellowSpot,score:0.99,target:repair.target,radius:repair.radius,repair:colourRepair)
        studio.receiveBlemishAnalysis(BlemishAnalysis(candidates:[red,dark,yellow]),photoID:first.id,repairSnapshot:[])
        XCTAssertEqual(studio.selectedBlemishIDs,[red.id])
        studio.selectRecommendedBlemishes()
        XCTAssertFalse(studio.selectedBlemishIDs.contains(yellow.id))
        XCTAssertNil(studio.photo?.settings.repairSpots,"分析本身不得修改照片")
        studio.excludeBlemish(dark.id)
        XCTAssertEqual(studio.blemishCandidates.count,2)
        studio.selectedBlemishIDs = [yellow.id]
        studio.history.beginUndoGrouping()
        studio.applySelectedBlemishes()
        studio.history.endUndoGrouping()
        XCTAssertEqual(studio.photo?.settings.repairSpots,[colourRepair])
        XCTAssertTrue(studio.blemishCandidates.isEmpty)
        studio.history.beginUndoGrouping()
        studio.syncAll()
        studio.history.endUndoGrouping()
        XCTAssertEqual(studio.project.photos[1].settings.repairSpots,[own],"同步不得复制另一张照片的自动取样坐标")
        studio.history.beginUndoGrouping()
        studio.savePreset(named:"瑕疵验证")
        studio.history.endUndoGrouping()
        XCTAssertNil(studio.project.customPresets[0].settings.repairSpots)
        studio.selection = second.id
        XCTAssertTrue(studio.blemishCandidates.isEmpty)
        studio.selection = first.id
        studio.history.beginUndoGrouping()
        studio.clearRepairSpots()
        studio.history.endUndoGrouping()
        studio.undo()
        XCTAssertEqual(studio.photo?.settings.repairSpots,[colourRepair])
    }

    func testStaleBlemishAnalysisIsDiscarded() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let storage = folder.appendingPathComponent("project.json")
        let a = Photo(url:folder.appendingPathComponent("a.jpg")), b = Photo(url:folder.appendingPathComponent("b.jpg"))
        try JSONEncoder().encode(Project(photos:[a,b])).write(to:storage)
        let studio = Studio(storageURL:storage)
        let repair = RepairSpot(source:MaskPoint(x:0.2,y:0.2),target:MaskPoint(x:0.3,y:0.3),radius:0.01)
        let candidate = BlemishCandidate(faceIndex:0,kind:.redSpot,score:0.95,target:repair.target,radius:0.01,repair:repair)
        let result = BlemishAnalysis(candidates:[candidate])
        studio.selection = b.id
        studio.receiveBlemishAnalysis(result,photoID:a.id,repairSnapshot:[])
        XCTAssertTrue(studio.blemishCandidates.isEmpty)
        studio.selection = a.id
        var settings = studio.photo!.settings; settings.repairSpots = [repair]
        studio.setAdjustments(settings)
        studio.receiveBlemishAnalysis(result,photoID:a.id,repairSnapshot:[])
        XCTAssertTrue(studio.blemishCandidates.isEmpty)
    }
    func testBatchSyncKeepsEachPhotosOwnBrushAndPresetExcludesBrush() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = folder.appendingPathComponent("project.json")
        var first = Photo(url: folder.appendingPathComponent("first.jpg"))
        var second = Photo(url: folder.appendingPathComponent("second.jpg"))
        let third = Photo(url: folder.appendingPathComponent("third.jpg"))
        let a = MaskStroke(points: [MaskPoint(x: 0.2, y: 0.3)], radius: 0.02, erase: false)
        let b = MaskStroke(points: [MaskPoint(x: 0.8, y: 0.7)], radius: 0.03, erase: true)
        var layer = AdjustmentLayer(mask: .skin)
        layer.adjustments.exposure = 0.4
        layer.brushStrokes = [a]
        first.settings.layers = [layer]
        layer.brushStrokes = [b]
        layer.adjustments.exposure = 0.1
        second.settings.layers = [layer]
        let project = Project(photos: [first, second, third])
        try JSONEncoder().encode(project).write(to: storage)
        let studio = Studio(storageURL: storage)
        studio.syncAll()
        XCTAssertEqual(studio.project.photos[0].settings.layers[0].brushStrokes, [a])
        XCTAssertEqual(studio.project.photos[1].settings.layers[0].brushStrokes, [b])
        XCTAssertNil(studio.project.photos[2].settings.layers[0].brushStrokes)
        XCTAssertEqual(studio.project.photos[1].settings.layers[0].adjustments.exposure, 0.4)
        studio.savePreset(named: "测试")
        XCTAssertNil(studio.project.customPresets[0].settings.layers[0].brushStrokes)
        studio.save()
        let restored = Studio(storageURL: storage)
        XCTAssertEqual(restored.project.photos, studio.project.photos)
    }

    func testBrushIsOneUndoableEditAndClearCanBeUndone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = folder.appendingPathComponent("project.json")
        var photo = Photo(url: folder.appendingPathComponent("photo.jpg"))
        photo.settings.layers = [AdjustmentLayer(mask: .clothing)]
        try JSONEncoder().encode(Project(photos: [photo])).write(to: storage)
        let studio = Studio(storageURL: storage)
        studio.activeLayerID = photo.settings.layers[0].id
        studio.history.groupsByEvent = false
        let stroke = MaskStroke(points: [MaskPoint(x: 0.2, y: 0.3)], radius: 0.02, erase: true)
        studio.history.beginUndoGrouping()
        studio.recordStroke(stroke)
        studio.history.endUndoGrouping()
        XCTAssertEqual(studio.activeLayer?.brushStrokes, [stroke])
        studio.undo()
        XCTAssertNil(studio.activeLayer?.brushStrokes)
        studio.redo()
        XCTAssertEqual(studio.activeLayer?.brushStrokes, [stroke])
        studio.history.beginUndoGrouping()
        studio.clearBrushStrokes()
        studio.history.endUndoGrouping()
        XCTAssertNil(studio.activeLayer?.brushStrokes)
        studio.undo()
        XCTAssertEqual(studio.activeLayer?.brushStrokes, [stroke])
    }
    func testReferenceTargetsAndRepairPointsPersistWithoutCopyingRepairCoordinates() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = folder.appendingPathComponent("project.json")
        var first = Photo(url: folder.appendingPathComponent("first.jpg"))
        var second = Photo(url: folder.appendingPathComponent("second.jpg"))
        let a = RepairSpot(source: MaskPoint(x: 0.2, y: 0.3), target: MaskPoint(x: 0.4, y: 0.3), radius: 0.002)
        let b = RepairSpot(source: MaskPoint(x: 0.6, y: 0.3), target: MaskPoint(x: 0.8, y: 0.3), radius: 0.003)
        first.settings.repairSpots = [a]; second.settings.repairSpots = [b]
        let distribution = SkinDistribution([50,60,70,80,90])
        let profile = SkinProfile(sampleCount: 1000, faceWidthPixels: 200, lightness: distribution,
                                  redGreen: SkinDistribution([10,12,14]), yellowBlue: SkinDistribution([14,16,18]))
        let template = SkinStyleTemplate(name: "参考", reference: profile)
        try JSONEncoder().encode(Project(photos: [first, second], skinTemplates: [template])).write(to: storage)
        let studio = Studio(storageURL: storage)
        studio.selectedSkinTemplateID = template.id
        studio.referenceStrength = 0.6
        studio.enableAutomaticBase(all: true)
        XCTAssertTrue(studio.project.photos.allSatisfy { $0.settings.automaticBase != nil })
        studio.applySkinTemplate(all: true)
        XCTAssertEqual(studio.project.photos[0].settings.skinReference?.strength, 0.6)
        XCTAssertEqual(studio.project.photos[1].settings.skinReference?.template, template)
        studio.updateSkinTemplate { $0.targetLightness = 75 }
        XCTAssertEqual(studio.selectedSkinTemplate?.targetLightness, 75)
        XCTAssertEqual(studio.project.photos[0].settings.skinReference?.template.targetLightness, 70,
                       "Applied photos keep their editable target snapshot until explicitly reapplied")
        let stroke = MaskStroke(points: [MaskPoint(x: 0.4, y: 0.7)], radius: 0.01, erase: true)
        studio.editReferenceMask()
        studio.recordStroke(stroke)
        studio.editReferenceMask(body: true)
        studio.recordStroke(stroke)
        studio.syncAll()
        XCTAssertEqual(studio.project.photos[0].settings.skinReference?.bodyBrushStrokes, [stroke])
        XCTAssertNil(studio.project.photos[1].settings.skinReference?.bodyBrushStrokes)
        XCTAssertEqual(studio.project.photos[0].settings.skinReference?.brushStrokes, [stroke])
        XCTAssertNil(studio.project.photos[1].settings.skinReference?.brushStrokes)
        XCTAssertEqual(studio.project.photos[0].settings.repairSpots, [a])
        XCTAssertEqual(studio.project.photos[1].settings.repairSpots, [b])
        studio.savePreset(named: "不含修复坐标")
        XCTAssertNil(studio.project.customPresets[0].settings.repairSpots)
        XCTAssertNil(studio.project.customPresets[0].settings.skinReference?.brushStrokes)
        XCTAssertNil(studio.project.customPresets[0].settings.skinReference?.bodyBrushStrokes)
        studio.save()
        let restored = Studio(storageURL: storage)
        XCTAssertEqual(restored.project, studio.project)
    }

}
