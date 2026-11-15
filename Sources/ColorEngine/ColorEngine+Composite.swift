import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

extension ColorEngine {
    func composite(_ original: CIImage, analysis: CIImage, with settings: Adjustments,
                   cacheURL: URL, lipReport: ((LipAdaptationReport) -> Void)? = nil) throws -> CIImage {
        var image = try SpotRepair.apply(settings.repairSpots ?? [], to: original)
        if let automatic = settings.automaticBase, automatic.strength > 0 {
            image = try applyAutomaticBase(image, analysis: analysis, cacheURL: cacheURL, settings: automatic).image
        }
        image = try grade(image, with: settings.global)
        for layer in settings.layers where layer.enabled && layer.opacity > 0 {
            // Adaptive lips see the final skin, including reference matching.
            if layer.mask == .lips && layer.adjustments.lipStyle != .manual { continue }
            try Task.checkCancellation()
            guard layer.adjustments != ColorAdjustments() else { continue }
            var cheeks: CIImage?
            if layer.mask.isSkinRegion && (layer.adjustments.cheekBlush != 0 || layer.adjustments.skinUniformity > 0) {
                let parsed = try masks.parsedMasks(analysis: analysis, cacheURL: cacheURL, context: context)
                cheeks = parsed.mask(.leftCheek, faceIndex: layer.faceIndex).applyingFilter("CIMaximumCompositing", parameters: [
                    kCIInputBackgroundImageKey: parsed.mask(.rightCheek, faceIndex: layer.faceIndex)
                ])
            }
            var adjusted = try grade(image, with: layer.adjustments, cheeks: cheeks)
            switch layer.blendMode {
            case .normal:
                break
            case .luminosity, .color:
                adjusted = try LayerBlender.blend(adjusted, over: image, mode: layer.blendMode)
            }
            let mask = try masks.makeMask(for: layer, original: original, analysis: analysis,
                                          cacheURL: cacheURL, context: context)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = adjusted
            blend.backgroundImage = image
            blend.maskImage = mask
            image = blend.outputImage ?? image
        }
        if let application = settings.skinReference, application.strength > 0 {
            image = try applyReference(image, analysis: analysis, cacheURL: cacheURL, application: application).image
        }
        for layer in settings.layers where layer.enabled && layer.opacity > 0 &&
            layer.mask == .lips && layer.adjustments.lipStyle != .manual {
            let parsed = try masks.parsedMasks(analysis: analysis, cacheURL: cacheURL, context: context)
            let faces = parsed.faces.filter { layer.faceIndex == nil || layer.faceIndex == $0.info.index }
            guard !faces.isEmpty else { throw ImageError.maskFailed("未找到唇部图层指定的人脸，请重新选择人物") }
            let baseline = image
            for face in faces {
                try Task.checkCancellation()
                let skin = try SkinColorMath.profile(baseline, mask: parsed.mask(.skin, faceIndex: face.info.index),
                                                     box: face.info.bounds, context: context)
                let lips: SkinProfile
                do {
                    lips = try SkinColorMath.profile(baseline, mask: parsed.mask(.lips, faceIndex: face.info.index),
                        box: face.info.bounds, context: context, maxEdge: 840, threshold: 0.85,
                        minimumSamples: 30, erosion: 0.6)
                } catch { throw ImageError.maskFailed("人物 \(face.info.index + 1) 的嘴唇采样不足，请改用手动微调或修正选区") }
                let recipe = try LipProcessing.recipe(skin: skin, lips: lips, settings: layer.adjustments,
                                                       reference: layer.lipReference?.lips ?? settings.skinReference?.template.lips)
                var ordinary = layer.adjustments
                ordinary.lipBrightness = 0; ordinary.lipHue = 0; ordinary.lipChroma = 0; ordinary.lipSmoothing = 0
                var adjusted = try grade(image, with: ordinary)
                adjusted = try LipProcessing.apply(adjusted, recipe: recipe, smoothing: layer.adjustments.lipSmoothing)
                if layer.blendMode != .normal {
                    adjusted = try LayerBlender.blend(adjusted, over: image, mode: layer.blendMode)
                }
                var local = layer
                local.faceIndex = face.info.index
                let selection = try masks.makeMask(for: local, original: original, analysis: analysis,
                                                   cacheURL: cacheURL, context: context)
                image = adjusted.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: selection])
                if let lipReport {
                    let after = try SkinColorMath.profile(image, mask: parsed.mask(.lips, faceIndex: face.info.index),
                        box: face.info.bounds, context: context, maxEdge: 840, threshold: 0.85,
                        minimumSamples: 30, erosion: 0.6)
                    lipReport(LipAdaptationReport(faceIndex: face.info.index, source: lips, after: after,
                        lightnessChange: recipe.lightness, hueChangeDegrees: recipe.hue * 180 / .pi,
                        chromaScale: recipe.chroma,
                        referenceName: layer.lipReference?.name ?? settings.skinReference?.template.name))
                }
            }
        }
        return image.cropped(to: original.extent)
    }

    public func lipAdaptationReports(_ url: URL, adjustments: Adjustments, preferRAW: Bool = true) throws -> [LipAdaptationReport] {
        let source = PhotoSource.resolve(url, preferRAW: preferRAW)
        let original = try load(source)
        let analysis = try analysisImage(for: source, original: original)
        var reports: [LipAdaptationReport] = []
        _ = try composite(original, analysis: analysis, with: adjustments, cacheURL: source.analysisURL,
                          lipReport: { reports.append($0) })
        return reports
    }

    public func automaticBaseReport(_ url: URL, adjustments: Adjustments) throws -> AutomaticBaseReport {
        let source = PhotoSource.resolve(url)
        let original = try load(source)
        let analysis = try analysisImage(for: source, original: original)
        let repaired = try SpotRepair.apply(adjustments.repairSpots ?? [], to: original)
        return try applyAutomaticBase(repaired, analysis: analysis, cacheURL: source.analysisURL,
                                      settings: adjustments.automaticBase ?? AutomaticBaseSettings()).report
    }

    func applyAutomaticBase(_ original: CIImage, analysis: CIImage, cacheURL: URL,
                            settings: AutomaticBaseSettings) throws -> (image: CIImage, report: AutomaticBaseReport) {
        try settings.validate()
        let parsed = try masks.parsedMasks(analysis: analysis, cacheURL: cacheURL, context: context)
        let face = parsed.faces.max { $0.info.bounds.width * $0.info.bounds.height < $1.info.bounds.width * $1.info.bounds.height }
        let faceBefore = face.flatMap { try? SkinColorMath.profile(original, mask: parsed.mask(.skin, faceIndex: $0.info.index),
                                                                 box: $0.info.bounds, context: context) }
        let scene = SceneToneProfile.measure(original, context: context)
        let recipe = try AutomaticBase.recipe(scene: scene, faceL: faceBefore?.lightness.median, settings: settings)
        var image = try AutomaticBase.tone(original, ev: recipe.globalEV)
        if recipe.subjectEV > 0 {
            let layer = AdjustmentLayer(mask: .person)
            let person = try masks.makeMask(for: layer, original: original, analysis: analysis, cacheURL: cacheURL, context: context)
            let lifted = try AutomaticBase.tone(image, ev: recipe.subjectEV)
            image = lifted.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: person])
        }
        image = try SkinProcessing.correctNeutralCast(image, deltaA: recipe.colorDeltaA, deltaB: recipe.colorDeltaB)
        let faceAfter = face.flatMap { try? SkinColorMath.profile(image, mask: parsed.mask(.skin, faceIndex: $0.info.index),
                                                                box: $0.info.bounds, context: context) }
        return (image.cropped(to: original.extent), AutomaticBaseReport(sceneMedianLightness: recipe.sceneMedianLightness,
            faceLightnessBefore: recipe.faceLightnessBefore, faceLightnessAfter: faceAfter?.lightness.median,
            globalEV: recipe.globalEV, subjectEV: recipe.subjectEV, neutralSamples: recipe.neutralSamples,
            colorDeltaA: recipe.colorDeltaA, colorDeltaB: recipe.colorDeltaB, warnings: recipe.warnings))
    }

    public func faceRegions(_ url: URL) throws -> [FaceRegionInfo] {
        let source = PhotoSource.resolve(url)
        let original = try load(source)
        let analysis = try analysisImage(for: source, original: original)
        return try masks.parsedMasks(analysis: analysis, cacheURL: source.analysisURL, context: context).faces.map(\.info)
    }

    func grade(_ original: CIImage, with settings: ColorAdjustments, cheeks: CIImage? = nil) throws -> CIImage {
        var image = original
        if settings.temperature != 0 || settings.tint != 0 {
            let balance = CIFilter.temperatureAndTint()
            balance.inputImage = image
            balance.neutral = CIVector(x: 6500 + settings.temperature, y: settings.tint)
            balance.targetNeutral = CIVector(x: 6500, y: 0)
            image = balance.outputImage ?? image
        }
        if settings.exposure != 0 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = image
            exposure.ev = Float(settings.exposure)
            image = exposure.outputImage ?? image
        }
        if settings.shadows != 0 || settings.highlights != 0 {
            let tones = CIFilter.highlightShadowAdjust()
            tones.inputImage = image
            tones.shadowAmount = Float(settings.shadows)
            tones.highlightAmount = Float(1 + settings.highlights)
            image = tones.outputImage ?? image
        }
        if settings.curve != 0 {
            let curve = CIFilter.toneCurve()
            curve.inputImage = image
            curve.point0 = CGPoint(x: 0, y: 0)
            curve.point1 = CGPoint(x: 0.25, y: 0.25 - settings.curve)
            curve.point2 = CGPoint(x: 0.5, y: 0.5)
            curve.point3 = CGPoint(x: 0.75, y: 0.75 + settings.curve)
            curve.point4 = CGPoint(x: 1, y: 1)
            image = curve.outputImage ?? image
        }
        if settings.contrast != 0 || settings.saturation != 0 {
            let color = CIFilter.colorControls()
            color.inputImage = image
            color.contrast = Float(1 + settings.contrast)
            color.saturation = Float(1 + settings.saturation)
            image = color.outputImage ?? image
        }
        if settings.rednessReduction > 0 {
            image = try SelectiveColor.reduceRedness(image, amount: settings.rednessReduction)
        }
        if settings.lipNaturalization > 0 {
            image = try SelectiveColor.naturalizeLips(image, amount: settings.lipNaturalization)
        }
        if settings.lipPolish > 0 {
            image = try SelectiveColor.polishLips(image, amount: settings.lipPolish)
        }
        try LipProcessing.validate(settings)
        image = try LipProcessing.apply(image, recipe: LipRecipe(lightness: settings.lipBrightness * 6,
            hue: settings.lipHue * .pi / 10, chroma: 1 + settings.lipChroma * 0.35), smoothing: settings.lipSmoothing)
        image = try SkinProcessing.apply(image, settings: settings, cheeks: cheeks)
        return image.cropped(to: original.extent)
    }
}
