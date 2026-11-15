import AppKit
import ColorEngine
import Foundation

extension Studio {
    func clearBlemishAnalysis() {
        blemishCandidates = []; selectedBlemishIDs = []; focusedBlemishID = nil
        blemishWarnings = ""; blemishRepairSnapshot = []
        if status.hasPrefix("瑕疵候选：") || status.hasPrefix("已修复 ") { status = "" }
    }

    func updatePortrait(_ edit: (inout PortraitIntent) -> Void) {
        var options = portraitOptions; edit(&options)
        portraitOptions = options
        guard let photo, photo.settings.portraitIntent != nil, !portraitBusy else { return }
        do {
            let settings = try PortraitWorkflow.settings(options, existing: photo.settings, reference: selectedSkinTemplate)
            setAdjustments(settings)
        } catch { alert = error.localizedDescription }
    }

    func runPortrait(all: Bool) {
        guard !portraitBusy, !exporting else { return }
        let targets = project.photos.filter { all || $0.id == selection }
        guard !targets.isEmpty else { return }
        let options = portraitOptions, reference = selectedSkinTemplate
        portraitBusy = true; portraitProgress = "正在准备…"
        portraitTask = Task {
            defer { portraitBusy = false; portraitProgress = ""; portraitTask = nil }
            var results: [UUID: (Photo, Adjustments, BlemishAnalysis, Int, [String])] = [:]
            var failures: [String] = []
            for (index, photo) in targets.enumerated() {
                do {
                    try Task.checkCancellation()
                    portraitProgress = "正在处理 \(index + 1)/\(targets.count) · \(photo.url.lastPathComponent)"
                    var recipe = try PortraitWorkflow.settings(options, existing: photo.settings, reference: reference)
                    let analysis = try await portraitEngine.blemishCandidates(photo.url, existingRepairs: photo.settings.repairSpots ?? [])
                    let automatic = options.repairRedSpots ? analysis.candidates.filter(\.recommended) : []
                    let repairs = automatic.compactMap(\.repair)
                    if !repairs.isEmpty { recipe.repairSpots = (recipe.repairSpots ?? []) + repairs }
                    _ = try await portraitEngine.preview(photo.url, adjustments: recipe, maxEdge: 1000, profile: .sRGB)
                    let checks = try await portraitEngine.skinReferenceReports(photo.url, adjustments: recipe)
                    let accepted = Set(automatic.map(\.id))
                    let review = BlemishAnalysis(candidates: analysis.candidates.filter { !accepted.contains($0.id) }, warnings: analysis.warnings)
                    results[photo.id] = (photo, recipe, review, repairs.count, checks.flatMap(\.warnings))
                } catch is CancellationError { status = "已取消，保留原有编辑"; return }
                catch { failures.append("\(photo.url.lastPathComponent)：\(error.localizedDescription)") }
            }
            guard !Task.isCancelled else { status = "已取消，保留原有编辑"; return }
            var updated = project
            var complete = 0
            for index in updated.photos.indices {
                guard let (original, recipe, review, count, warnings) = results[updated.photos[index].id] else { continue }
                guard updated.photos[index].settings == original.settings else {
                    failures.append("\(original.url.lastPathComponent)：编辑已改变，跳过覆盖"); continue
                }
                updated.photos[index].settings = recipe
                updated.photos[index].portraitSummary = "已完成补光、肤色与唇色协调 · 自动修复 \(count) 处 · \(review.candidates.count) 处可检查"
                updated.photos[index].portraitWarnings = warnings
                portraitReviews[original.id] = (recipe.repairSpots ?? [], review)
                complete += 1
            }
            history.beginUndoGrouping()
            commit(updated, name: all ? "整组自动修图" : "一键自动修图")
            history.endUndoGrouping()
            activeLayerID = nil; showMask = false; repairMode = false; referenceMaskEditing = false
            if let applied = photo?.settings.portraitIntent { portraitOptions = applied }
            clearBlemishAnalysis()
            status = "已完成 \(complete) 张自动修图，调整量逐张计算\(failures.isEmpty ? "" : " · \(failures.count) 张未处理")"
            if !failures.isEmpty { alert = failures.joined(separator: "\n") }
        }
    }

    func cancelPortrait() { portraitTask?.cancel() }

    func reviewPortraitDetails() {
        guard let photo else { return }
        if let cached = portraitReviews[photo.id], cached.repairs == (photo.settings.repairSpots ?? []) {
            receiveBlemishAnalysis(cached.analysis, photoID: photo.id, repairSnapshot: cached.repairs)
        } else { analyzeBlemishes() }
    }

    func receiveBlemishAnalysis(_ result: BlemishAnalysis, photoID: UUID, repairSnapshot: [RepairSpot]) {
        guard photo?.id == photoID, (photo?.settings.repairSpots ?? []) == repairSnapshot else { return }
        blemishCandidates = result.candidates
        blemishRepairSnapshot = repairSnapshot
        selectedBlemishIDs = Set(result.candidates.filter(\.recommended).map(\.id))
        blemishWarnings = result.warnings.joined(separator: "\n")
        showBlemishCandidates = true
        status = "瑕疵候选：发现 \(result.candidates.count) 个，未修改照片；可检查后修复所选项"
    }

    func analyzeBlemishes() {
        guard let photo, !blemishBusy else { return }
        let snapshot = photo.settings.repairSpots ?? [], sensitivity = blemishSensitivity
        blemishBusy = true
        clearBlemishAnalysis()
        Task {
            defer { blemishBusy = false }
            do {
                let result = try await blemishEngine.blemishCandidates(photo.url, existingRepairs: snapshot, sensitivity: sensitivity)
                receiveBlemishAnalysis(result, photoID: photo.id, repairSnapshot: snapshot)
            } catch {
                if self.photo?.id == photo.id { alert = "瑕疵分析失败：\(error.localizedDescription)" }
            }
        }
    }

    func selectRecommendedBlemishes() {
        selectedBlemishIDs = Set(blemishCandidates.filter(\.recommended).map(\.id))
    }

    func excludeBlemish(_ id: UUID) {
        blemishCandidates.removeAll { $0.id == id }; selectedBlemishIDs.remove(id)
        if focusedBlemishID == id { focusedBlemishID = nil }
        status = "瑕疵候选：剩余 \(blemishCandidates.count) 个，未修改照片"
    }

    func applySelectedBlemishes() {
        guard var settings = photo?.settings, (settings.repairSpots ?? []) == blemishRepairSnapshot else {
            clearBlemishAnalysis(); return
        }
        let repairs = blemishCandidates.filter { selectedBlemishIDs.contains($0.id) }.compactMap(\.repair)
        guard !repairs.isEmpty else { return }
        settings.repairSpots = (settings.repairSpots ?? []) + repairs
        setAdjustments(settings)
        status = "已修复 \(repairs.count) 处 · 可撤销，修复点仅保存于本张照片"
    }

    func export(all: Bool) {
        guard !exporting else { return }
        let photos = all ? project.photos : photo.map { [$0] } ?? []
        guard !photos.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.title = "选择导出位置"
        panel.prompt = "导出"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let format = format
        let profile = profile
        exporting = true
        exportTask = Task {
            var complete = 0
            var failures: [String] = []
            for (index, photo) in photos.enumerated() {
                guard !Task.isCancelled else { break }
                status = "正在导出 \(index + 1) / \(photos.count)"
                let target = Self.nextOutputURL(for: photo.url, in: folder, format: format)
                do {
                    try await exportEngine.export(photo.url, to: target, adjustments: photo.settings,
                                                  format: format, profile: profile)
                    complete += 1
                } catch is CancellationError {
                    break
                } catch {
                    failures.append("\(photo.url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            status = Task.isCancelled ? "已取消 · 已导出 \(complete) 张" : "已导出 \(complete) 张到 \(folder.lastPathComponent)"
            if !failures.isEmpty {
                status += " · \(failures.count) 张失败"
                alert = failures.joined(separator: "\n")
            }
            exporting = false
            exportTask = nil
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    private static func nextOutputURL(for source: URL, in folder: URL, format: OutputFormat) -> URL {
        let basename = source.deletingPathExtension().lastPathComponent + "-调色"
        var number = 1
        while true {
            let suffix = number == 1 ? "" : "-\(number)"
            let url = folder.appendingPathComponent(basename + suffix).appendingPathExtension(format.fileExtension)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            number += 1
        }
    }
}
