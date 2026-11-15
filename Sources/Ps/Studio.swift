import AppKit
import ColorEngine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class Studio: ObservableObject {
    @Published private(set) var project = Project() {
        didSet {
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { self?.save() }
            }
        }
    }
    @Published var selection: UUID? {
        didSet {
            activeLayerID = nil
            showMask = false
            brushTool = .inspect
            repairMode = false
            referenceMaskEditing = false
            referenceBodyMaskEditing = false
            automaticBaseReportText = ""
            repairSource = nil
            detectedFaces = []
            referenceReportText = ""
            clearBlemishAnalysis()
            if let intent = photo?.settings.portraitIntent { portraitOptions = intent }
        }
    }
    @Published var activeLayerID: UUID? {
        didSet { if activeLayerID != nil { referenceMaskEditing = false } }
    }
    @Published var referenceMaskEditing = false
    @Published var referenceBodyMaskEditing = false
    @Published var automaticBaseReportText = ""
    @Published var showMask = false
    @Published var brushTool: MaskBrushTool = .inspect
    @Published var brushRadius = 0.008
    @Published var repairMode = false
    @Published var repairSource: MaskPoint?
    @Published var repairRadius = 0.003
    let history = UndoManager()
    @Published var format: OutputFormat = .tiff
    @Published var profile: OutputProfile = .source
    @Published var status = ""
    @Published var alert: String?
    @Published var exporting = false

    @Published var selectedSkinTemplateID: UUID?
    @Published var referenceStrength = 0.75
    @Published var referenceBusy = false
    @Published var referenceReportText = ""
    @Published var detectedFaces: [FaceRegionInfo] = []
    @Published var blemishCandidates: [BlemishCandidate] = []
    @Published var blemishBusy = false
    @Published var blemishWarnings = ""
    @Published var blemishSensitivity = 0.5
    @Published var selectedBlemishIDs: Set<UUID> = []
    @Published var focusedBlemishID: UUID?
    @Published var showBlemishCandidates = true
    var blemishRepairSnapshot: [RepairSpot] = []
    let blemishEngine = ColorEngine()
    @Published var portraitOptions = PortraitIntent()
    @Published var portraitBusy = false
    @Published var portraitProgress = ""
    let portraitEngine = ColorEngine()
    var portraitTask: Task<Void, Never>?
    var portraitReviews: [UUID: (repairs: [RepairSpot], analysis: BlemishAnalysis)] = [:]
    let referenceEngine = ColorEngine()
    let previewEngine = ColorEngine()
    let exportEngine = ColorEngine()
    private let projectURL: URL
    private var saveTask: Task<Void, Never>?
    var exportTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?

    var photo: Photo? { project.photos.first { $0.id == selection } }
    var activeLayer: AdjustmentLayer? {
        photo?.settings.layers.first { $0.id == activeLayerID }
    }
    var editableColor: ColorAdjustments { activeLayer?.adjustments ?? photo?.settings.global ?? ColorAdjustments() }
    var presets: [Preset] { Preset.standard + project.customPresets }
    var skinTemplates: [SkinStyleTemplate] { project.skinTemplates ?? [] }
    var selectedSkinTemplate: SkinStyleTemplate? { skinTemplates.first { $0.id == selectedSkinTemplateID } }

    init(storageURL: URL? = nil) {
        projectURL = storageURL ?? URL.applicationSupportDirectory
            .appendingPathComponent("PsColorStudio", isDirectory: true)
            .appendingPathComponent("project.json")
        history.levelsOfUndo = 40
        do {
            let data = try Data(contentsOf: projectURL)
            let project = try JSONDecoder().decode(Project.self, from: data)
            guard project.version == 1 else {
                alert = "项目格式版本不兼容。"
                return
            }
            self.project = project
            selection = project.photos.first?.id
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        } catch {
            alert = "无法载入项目：\(error.localizedDescription)"
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: projectURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(project).write(to: projectURL, options: .atomic)
        } catch {
            status = "项目保存失败：\(error.localizedDescription)"
        }
    }

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.title = "导入照片"
        panel.prompt = "导入"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.jpeg, .tiff, .rawImage]
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    func importFiles(_ urls: [URL]) {
        guard importTask == nil else { return }
        status = "正在读取照片…"
        importTask = Task {
            let files = await Task.detached(priority: .userInitiated) {
                Self.collectFiles(urls)
            }.value
            var existing = Set(project.photos.map(\.url))
            let added = files.filter { existing.insert($0).inserted }.map(Photo.init(url:))
            var updated = project
            updated.photos.append(contentsOf: added)
            commit(updated, name: "导入照片")
            if selection == nil { selection = project.photos.first?.id }
            status = added.isEmpty ? "没有新的 RAW、JPEG 或 TIFF 照片" : "已导入 \(added.count) 张照片"
            importTask = nil
        }
    }

    private nonisolated static func collectFiles(_ urls: [URL]) -> [URL] {
        let manager = FileManager.default
        let supported = PhotoSource.jpegExtensions
            .union(PhotoSource.rawExtensions)
            .union(PhotoSource.stillExtensions)
        let candidates = urls.flatMap { url -> [URL] in
            var directory: ObjCBool = false
            if manager.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
                return (try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles])) ?? []
            }
            return [url]
        }
        .map { $0.resolvingSymlinksInPath().standardizedFileURL }
        .filter { supported.contains($0.pathExtension.lowercased())
            && (try? PhotoInfo.read($0)) != nil }
        // A paired ARW + JPEG is one photo: keep the RAW as the project entry.
        // The engine still uses the JPEG for face/person analysis.
        let rawStems = Set(candidates
            .filter { PhotoSource.rawExtensions.contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().lastPathComponent.lowercased() })
        return candidates.filter { url in
            guard PhotoSource.jpegExtensions.contains(url.pathExtension.lowercased()) else { return true }
            return !rawStems.contains(url.deletingPathExtension().lastPathComponent.lowercased())
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func commit(_ updated: Project, name: String) {
        guard updated != project else { return }
        let previous = project
        history.registerUndo(withTarget: self) { studio in
            studio.commit(previous, name: name)
        }
        history.setActionName(name)
        project = updated
        if photo?.settings.skinReference == nil && referenceMaskEditing {
            referenceMaskEditing = false
            showMask = false
        }
        if selection != nil && photo == nil { selection = project.photos.first?.id }
        if let activeLayerID, photo?.settings.layers.contains(where: { $0.id == activeLayerID }) != true {
            self.activeLayerID = nil
            showMask = false
        }
    }

    func undo() {
        history.undo()
        clearBlemishAnalysis()
        objectWillChange.send()
    }

    func redo() {
        history.redo()
        clearBlemishAnalysis()
        objectWillChange.send()
    }

    func setAdjustments(_ adjustments: Adjustments) {
        guard let index = project.photos.firstIndex(where: { $0.id == selection }) else { return }
        if project.photos[index].settings.repairSpots != adjustments.repairSpots { clearBlemishAnalysis() }
        var updated = project
        updated.photos[index].settings = adjustments
        updated.photos[index].portraitWarnings = nil
        if adjustments.portraitIntent == nil { updated.photos[index].portraitSummary = nil }
        referenceReportText = ""
        automaticBaseReportText = ""
        commit(updated, name: "调色")
    }

    func removeSelected() {
        guard let index = project.photos.firstIndex(where: { $0.id == selection }) else { return }
        var updated = project
        updated.photos.remove(at: index)
        commit(updated, name: "移除照片")
        selection = project.photos.isEmpty ? nil : project.photos[min(index, project.photos.count - 1)].id
    }
}
