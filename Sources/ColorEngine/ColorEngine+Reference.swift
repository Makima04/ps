import CoreImage
import Foundation

extension ColorEngine {
    public func makeSkinTemplate(_ url: URL, name: String) throws -> SkinStyleTemplate {
        // Reference files describe their visible, rendered appearance; do not upgrade to a paired RAW.
        guard !PhotoSource.rawExtensions.contains(url.pathExtension.lowercased()) else {
            throw ImageError.maskFailed("参考图请使用已显影的 JPEG、PNG 或 TIFF")
        }
        let source = PhotoSource(imageURL: url, analysisURL: url, metadataURL: url,
                                 isRAW: false, hasPairedJPEG: false)
        let image = try load(source)
        let parsed = try masks.parsedMasks(analysis: image, cacheURL: source.analysisURL, context: context)
        guard let face = parsed.faces.max(by: { $0.info.bounds.width * $0.info.bounds.height < $1.info.bounds.width * $1.info.bounds.height }) else {
            throw ImageError.maskFailed("参考图没有可靠人脸")
        }
        let profile = try SkinColorMath.profile(image, mask: parsed.mask(.skin, faceIndex: face.info.index),
                                                box: face.info.bounds, context: context)
        var template = SkinStyleTemplate(name: name, reference: profile)
        if let lipProfile = try? SkinColorMath.profile(image, mask: parsed.mask(.lips, faceIndex: face.info.index),
            box: face.info.bounds, context: context, maxEdge: 840, threshold: 0.85, minimumSamples: 30, erosion: 0.6) {
            template.lips = LipReferenceTarget(skin: profile, lips: lipProfile)
        }
        try template.validate()
        return template
    }

    public func skinReferenceReports(_ url: URL, adjustments: Adjustments) throws -> [SkinAdaptationReport] {
        guard let application = adjustments.skinReference else { return [] }
        let source = PhotoSource.resolve(url)
        let original = try load(source)
        let analysis = try analysisImage(for: source, original: original)
        var base = adjustments
        base.skinReference = nil
        // Reference reports stop at skin matching. Adaptive lips run afterwards
        // and may themselves depend on the template removed from this snapshot.
        base.layers.removeAll { $0.mask == .lips && $0.adjustments.lipStyle != .manual }
        let image = try composite(original, analysis: analysis, with: base, cacheURL: source.analysisURL)
        return try applyReference(image, analysis: analysis, cacheURL: source.analysisURL, application: application).reports
    }

    func referenceSelection(parsed: SemanticMasks, faceIndex: Int, application: SkinReferenceApplication,
                            original: CIImage, analysis: CIImage, cacheURL: URL) throws -> CIImage {
        var layer = AdjustmentLayer(mask: .skin)
        layer.faceIndex = faceIndex
        layer.feather = 0
        layer.brushStrokes = application.brushStrokes
        var selection = try masks.makeMask(for: layer, original: original, analysis: analysis, cacheURL: cacheURL, context: context)
        if !application.includeNeck {
            selection = selection.applyingFilter("CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: parsed.mask(.neck, faceIndex: faceIndex).applyingFilter("CIColorInvert")
            ])
        }
        if application.template.protectCheeks {
            let cheeks = parsed.mask(.leftCheek, faceIndex: faceIndex).applyingFilter("CIMaximumCompositing", parameters: [
                kCIInputBackgroundImageKey: parsed.mask(.rightCheek, faceIndex: faceIndex)
            ]).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.65, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.65, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.65, w: 0)
            ]).applyingFilter("CIColorInvert")
            selection = selection.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: cheeks])
        }
        let face = parsed.faces[faceIndex]
        selection = try FaceMaskOwnership.restrict(selection, index: faceIndex, boxes: parsed.faces.map { $0.info.bounds })
        return selection.clampedToExtent().applyingGaussianBlur(sigma: max(0.5, face.info.bounds.width * 0.003)).cropped(to: original.extent)
    }

    func applyReference(_ original: CIImage, analysis: CIImage, cacheURL: URL,
                        application: SkinReferenceApplication) throws -> (image: CIImage, reports: [SkinAdaptationReport]) {
        try application.template.validate()
        let parsed = try masks.parsedMasks(analysis: analysis, cacheURL: cacheURL, context: context)
        let faces = parsed.faces.filter { application.faceIndex == nil || $0.info.index == application.faceIndex }
        guard !faces.isEmpty else { throw ImageError.maskFailed("未找到模板指定的人脸，请重新选择人物") }
        var result = original
        var reports: [SkinAdaptationReport] = []
        for face in faces {
            try Task.checkCancellation()
            let index = face.info.index
            let selection = try referenceSelection(parsed: parsed, faceIndex: index, application: application,
                                                   original: original, analysis: analysis, cacheURL: cacheURL)
            let before = try SkinColorMath.profile(original, mask: parsed.mask(.skin, faceIndex: index), box: face.info.bounds, context: context)
            var recipe = try SkinAdaptation(source: before, application: application)
            var candidate = result
            var after = before
            var warnings = application.template.reference.warnings
            if !face.info.hasLandmarks { warnings.append("关键点不足，未启用脸颊保护") }
            var accepted = false
            // Evaluate the actual composited pixels, reducing strength on highlight/layer loss.
            for _ in 0..<4 {
                let adjusted = try SkinColorMath.transfer(result, recipe: recipe)
                candidate = adjusted.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: selection
                ]).cropped(to: original.extent)
                after = try SkinColorMath.profile(candidate, mask: parsed.mask(.skin, faceIndex: index),
                                                 box: face.info.bounds, context: context)
                let spread = before.lightness.p90 - before.lightness.p10
                if after.clippedFraction <= before.clippedFraction + 0.005 &&
                   after.lightness.p90 - after.lightness.p10 >= spread * 0.80 {
                    accepted = true; break
                }
                recipe.strength *= 0.5
            }
            if !accepted {
                recipe.strength = 0; candidate = result; after = before
                warnings.append("高光或明暗层次检查未通过，本人物保留原效果")
            } else if recipe.strength < application.strength * application.template.reference.reliability {
                warnings.append("已自动降低追色强度以保护高光和层次")
            }
            // A large exposure lift preserves Lab chroma, which makes skin look
            // grey. Close the gap toward the template chroma inside the same mask.
            if let compensation = application.chromaCompensation, compensation > 0 {
                let targetC = hypot(application.template.targetRed, application.template.targetYellow)
                let afterC = hypot(after.redGreen.median, after.yellowBlue.median)
                let deficit = targetC - afterC
                if deficit > 0.2 {
                    var gain = min(1.35, 1 + compensation * deficit / max(afterC, 1))
                    var bBoost = min(2.5, compensation * max(0, application.template.targetYellow - after.yellowBlue.median))
                    let cap = targetC * 1.05
                    // Restoration covers the whole face skin; cheek protection is for
                    // matching the template, not for undoing a lift-induced grey cast.
                    var chromaApplication = application
                    chromaApplication.template.protectCheeks = false
                    let chromaSelection = try referenceSelection(parsed: parsed, faceIndex: index,
                                                                 application: chromaApplication,
                                                                 original: original, analysis: analysis, cacheURL: cacheURL)
                    for _ in 0..<2 {
                        let adjusted = try SkinColorMath.compensateChroma(candidate, mask: chromaSelection, gain: gain,
                                                                          bBoost: bBoost, maxChroma: cap)
                        let compensated = try SkinColorMath.profile(adjusted, mask: parsed.mask(.skin, faceIndex: index),
                                                                    box: face.info.bounds, context: context)
                        let spread = before.lightness.p90 - before.lightness.p10
                        if compensated.clippedFraction <= before.clippedFraction + 0.005 &&
                           compensated.lightness.p90 - compensated.lightness.p10 >= spread * 0.80 {
                            candidate = adjusted
                            after = compensated
                            break
                        }
                        gain = 1 + (gain - 1) * 0.5
                        bBoost *= 0.5
                    }
                }
            }
            result = candidate
            reports.append(SkinAdaptationReport(before: before, after: after, adaptation: recipe, warnings: warnings))
        }
        if application.strength > 0, let amount = application.bodyHarmonization, amount > 0 {
            guard amount.isFinite, amount <= 1 else { throw ImageError.maskFailed("身体肤色协调强度无效") }
            if parsed.faces.count == 1, let face = faces.first {
                let coordinated = try harmonizeBody(result, analysis: analysis, cacheURL: cacheURL,
                                                    application: application, parsed: parsed, face: face, amount: amount)
                result = coordinated.image
                let report = reports[0]
                reports[0] = SkinAdaptationReport(before: report.before, after: report.after, adaptation: report.adaptation,
                    warnings: report.warnings + coordinated.warnings, bodyReports: coordinated.reports)
            } else if !reports.isEmpty {
                let report = reports[0]
                reports[0] = SkinAdaptationReport(before: report.before, after: report.after, adaptation: report.adaptation,
                    warnings: report.warnings + ["多人照片暂不自动关联身体肤色，可使用身体图层手动协调"])
            }
        }
        return (result, reports)
    }

    func bodyCandidates(_ original: CIImage, analysis: CIImage, cacheURL: URL,
                        application: SkinReferenceApplication, parsed: SemanticMasks) throws -> CIImage {
        var layer = AdjustmentLayer(mask: .bodySkin)
        layer.feather = 0.0002
        layer.brushStrokes = application.bodyBrushStrokes
        var candidates = try masks.makeMask(for: layer, original: original, analysis: analysis, cacheURL: cacheURL, context: context)
        if application.includeNeck {
            candidates = candidates.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: parsed.mask(.neck)])
        }
        return candidates.cropped(to: original.extent)
    }

    private func harmonizeBody(_ original: CIImage, analysis: CIImage, cacheURL: URL,
                               application: SkinReferenceApplication, parsed: SemanticMasks,
                               face: SemanticFace, amount: Double) throws -> (image: CIImage, reports: [BodySkinReport], warnings: [String]) {
        let targetFace = try SkinColorMath.profile(original, mask: parsed.mask(.skin, faceIndex: face.info.index),
                                                   box: face.info.bounds, context: context)
        let candidates = try bodyCandidates(original, analysis: analysis, cacheURL: cacheURL, application: application, parsed: parsed)
        let regions = try BodySkinComponents.regions(candidates, context: context)
        var result = original
        var reports: [BodySkinReport] = []
        for region in regions {
            try Task.checkCancellation()
            let before: SkinProfile
            do { before = try SkinColorMath.profile(result, mask: region.mask, box: region.bounds,
                context: context, maxEdge: 600, threshold: 0.55, minimumSamples: 80, erosion: 1) }
            catch {
                continue
            }
            var template = SkinStyleTemplate(name: "脸颈手协调", reference: targetFace)
            // Preserve natural body/face differences within a tolerance band.
            // Lift a shaded hand toward the face; keep naturally sunlit skin bright.
            template.targetLightness = min(95, max(targetFace.lightness.median - 3, before.lightness.median))
            template.targetRed = max(targetFace.redGreen.median - 4.5, min(targetFace.redGreen.median + 1.5, before.redGreen.median))
            template.targetYellow = max(targetFace.yellowBlue.median - 1.5, min(targetFace.yellowBlue.median + 1.5, before.yellowBlue.median))
            template.maxLightnessChange = 10; template.maxColorChange = 10
            var match = SkinReferenceApplication(template: template)
            match.strength = amount
            var recipe = try SkinAdaptation(source: before, application: match, preserveColorSpread: true)
            // Body targets come from this full-size face, not the small external reference.
            recipe.strength = amount
            var candidate = result, after = before, accepted = false
            for _ in 0..<4 {
                let adjusted = try SkinColorMath.transfer(result, recipe: recipe)
                candidate = adjusted.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: region.mask
                ]).cropped(to: original.extent)
                after = try SkinColorMath.profile(candidate, mask: region.mask, box: region.bounds,
                    context: context, maxEdge: 600, threshold: 0.55, minimumSamples: 80, erosion: 1)
                if after.clippedFraction <= before.clippedFraction + 0.005 &&
                   after.lightness.p90 - after.lightness.p10 >= (before.lightness.p90 - before.lightness.p10) * 0.8 {
                    accepted = true; break
                }
                recipe.strength *= 0.5
            }
            if accepted {
                result = candidate
                reports.append(BodySkinReport(before: before, after: after, targetLightness: template.targetLightness,
                                              targetRed: template.targetRed, targetYellow: template.targetYellow))
            }
        }
        return (result, reports, reports.isEmpty ? ["身体皮肤可靠采样不足，未自动协调；可修正身体候选蒙版"] : [])
    }
}
