import AppKit
import ColorEngine
import Foundation
import UniformTypeIdentifiers

extension Studio {
    func enableAutomaticBase(all: Bool) {
        let automatic = photo?.settings.automaticBase ?? AutomaticBaseSettings()
        var updated = project
        for index in updated.photos.indices where all || updated.photos[index].id == selection {
            updated.photos[index].settings.automaticBase = automatic
        }
        commit(updated, name: "自动基础校正")
        automaticBaseReportText = ""
        referenceReportText = ""
        status = "已启用自动基础校正，曝光按每张照片重新计算"
    }

    func updateAutomaticBase(_ edit: (inout AutomaticBaseSettings) -> Void) {
        guard var settings = photo?.settings else { return }
        var automatic = settings.automaticBase ?? AutomaticBaseSettings()
        edit(&automatic)
        settings.automaticBase = automatic
        setAdjustments(settings)
    }

    func removeAutomaticBase() {
        guard var settings = photo?.settings else { return }
        settings.automaticBase = nil
        setAdjustments(settings)
    }

    func checkAutomaticBase() {
        guard let photo, !referenceBusy else { return }
        referenceBusy = true
        Task {
            defer { referenceBusy = false }
            do {
                let report = try await referenceEngine.automaticBaseReport(photo.url, adjustments: photo.settings)
                guard self.photo?.id == photo.id, self.photo?.settings == photo.settings else { return }
                automaticBaseReportText = String(format: "全图补偿 %.2f EV · 人物补光 %.2f EV", report.globalEV, report.subjectEV)
                if let before = report.faceLightnessBefore, let after = report.faceLightnessAfter {
                    automaticBaseReportText += String(format: "\n脸部 L* %.1f → %.1f", before, after)
                }
                if photo.settings.automaticBase?.correctColorCast == true {
                    automaticBaseReportText += String(format: "\n偏色修正 a* %+.1f · b* %+.1f", report.colorDeltaA, report.colorDeltaB)
                }
                automaticBaseReportText += report.warnings.isEmpty ? "" : "\n" + report.warnings.joined(separator: "；")
            } catch { alert = "自动校正分析失败：\(error.localizedDescription)" }
        }
    }

    func detectFaces() async {
        guard let photo else { return }
        do {
            let faces = try await referenceEngine.faceRegions(photo.url)
            guard selection == photo.id else { return }
            detectedFaces = faces
        } catch {
            guard selection == photo.id else { return }
            status = "人物识别失败：\(error.localizedDescription)"
        }
    }

    func pickSkinReference() {
        guard !referenceBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "从参考图提取肤色，或导入模板 JSON"
        panel.allowedContentTypes = [.jpeg, .png, .tiff, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importSkinReference(url)
    }

    func importSkinReference(_ url: URL) {
        guard !referenceBusy else { return }
        referenceBusy = true
        Task {
            defer { referenceBusy = false }
            do {
                var template: SkinStyleTemplate
                if url.pathExtension.lowercased() == "json" {
                    template = try JSONDecoder().decode(SkinStyleTemplate.self, from: Data(contentsOf: url))
                    try template.validate()
                    // Import as an independent editable copy.
                    template.id = UUID()
                } else {
                    template = try await referenceEngine.makeSkinTemplate(url, name: url.deletingPathExtension().lastPathComponent)
                }
                var updated = project
                var templates = skinTemplates
                templates.append(template)
                updated.skinTemplates = templates
                commit(updated, name: "导入参考肤色模板")
                selectedSkinTemplateID = template.id
                status = "已提取参考肤色，可编辑目标后应用"
            } catch { alert = "参考导入失败：\(error.localizedDescription)" }
        }
    }

    func updateSkinTemplate(_ edit: (inout SkinStyleTemplate) -> Void) {
        guard let index = skinTemplates.firstIndex(where: { $0.id == selectedSkinTemplateID }) else { return }
        var templates = skinTemplates
        edit(&templates[index])
        var updated = project
        updated.skinTemplates = templates
        commit(updated, name: "编辑参考目标")
    }

    func exportSkinTemplate() {
        guard let template = selectedSkinTemplate else { return }
        let panel = NSSavePanel()
        panel.title = "保存可重复使用的肤色模板"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = template.name + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try template.validate()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(template).write(to: url, options: .atomic)
        } catch { alert = "保存模板失败：\(error.localizedDescription)" }
    }

    func applySkinTemplate(all: Bool) {
        guard let template = selectedSkinTemplate else { return }
        do { try template.validate() } catch { alert = error.localizedDescription; return }
        var application = SkinReferenceApplication(template: template)
        application.strength = referenceStrength
        var updated = project
        for index in updated.photos.indices where all || updated.photos[index].id == selection {
            var perPhoto = application
            if updated.photos[index].settings.skinReference?.template.id == template.id {
                perPhoto.brushStrokes = updated.photos[index].settings.skinReference?.brushStrokes
                perPhoto.bodyBrushStrokes = updated.photos[index].settings.skinReference?.bodyBrushStrokes
            }
            updated.photos[index].settings.skinReference = perPhoto
        }
        commit(updated, name: "应用参考肤色目标")
        referenceReportText = ""
        showMask = false
        status = all ? "已应用目标，各张照片及人物独立计算追色量" : "已应用参考目标，可切换原图比较"
    }

    func updateSkinReference(_ edit: (inout SkinReferenceApplication) -> Void) {
        guard var settings = photo?.settings, var reference = settings.skinReference else { return }
        edit(&reference)
        settings.skinReference = reference
        setAdjustments(settings)
        referenceReportText = ""
    }

    func removeSkinReference() {
        guard var settings = photo?.settings else { return }
        settings.skinReference = nil
        referenceMaskEditing = false
        showMask = false
        setAdjustments(settings)
        referenceReportText = ""
    }

    func editReferenceMask(body: Bool = false) {
        guard photo?.settings.skinReference != nil else { return }
        activeLayerID = nil
        referenceMaskEditing = true
        referenceBodyMaskEditing = body
        repairMode = false
        showMask = true
        brushTool = .add
    }

    func checkSkinReference() {
        guard let photo, !referenceBusy else { return }
        referenceBusy = true
        Task {
            defer { referenceBusy = false }
            do {
                let reports = try await referenceEngine.skinReferenceReports(photo.url, adjustments: photo.settings)
                guard self.photo?.id == photo.id, self.photo?.settings == photo.settings else { return }
                referenceReportText = reports.enumerated().map { index, report in
                    String(format: "人物 %d · L* %.1f → %.1f · 有效强度 %.0f%%", index + 1,
                           report.before.lightness.median, report.after.lightness.median, report.adaptation.strength * 100)
                        + report.bodyReports.enumerated().map { i, b in
                            String(format: "\n身体区域 %d · L* %.1f → %.1f · b* %.1f → %.1f", i + 1,
                                   b.before.lightness.median, b.after.lightness.median, b.before.yellowBlue.median, b.after.yellowBlue.median)
                        }.joined()
                        + (report.warnings.isEmpty ? "" : "\n" + report.warnings.joined(separator: "；"))
                }.joined(separator: "\n")
            } catch { alert = "参考效果检查失败：\(error.localizedDescription)" }
        }
    }
}
