import Foundation

public enum PortraitLook: String, Codable, CaseIterable, Identifiable, Sendable {
    case natural, fair, original
    public var id: Self { self }
    public var label: String {
        switch self { case .natural: "自然通透"; case .fair: "白皙红润"; case .original: "保留原色" }
    }
}

public enum PortraitLip: String, Codable, CaseIterable, Identifiable, Sendable {
    case original, softPink, reference
    public var id: Self { self }
    public var label: String {
        switch self { case .original: "保留原唇色"; case .softPink: "自然浅粉"; case .reference: "借鉴参考" }
    }
}

public struct PortraitIntent: Codable, Equatable, Sendable {
    public var look: PortraitLook = .natural
    public var brightness = 0.5
    public var uniformity = 0.3
    public var softness = 0.2
    public var lip: PortraitLip = .softPink
    public var lipStrength = 0.7
    public var harmonizeBody = true
    public var repairRedSpots = true
    public var useReference = false
    public init() {}

    public func validate() throws {
        guard [brightness,uniformity,softness,lipStrength].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw ImageError.maskFailed("快速修图强度必须为 0 到 1")
        }
    }

    public func skinGoal() -> SkinStyleTemplate {
        let l = look == .fair ? 72+brightness*6 : 68+brightness*8
        let profile = SkinProfile(sampleCount:1000,faceWidthPixels:320,
            lightness:SkinDistribution([l-12,l-6,l,l+4,l+7]),
            redGreen:SkinDistribution([12,14,16,18,20]),
            yellowBlue:SkinDistribution([7,9,11,14,16]))
        var goal = SkinStyleTemplate(name:"内置目标 · " + look.label,reference:profile)
        goal.id = UUID(uuidString:"231B709C-4188-4B30-960E-D3EE8EA2450A")!
        goal.scene = "内置外观目标，非参考图测量"
        goal.maxLightnessChange = 14; goal.maxColorChange = 8
        return goal
    }
}


extension PortraitIntent {
    public static func softPinkTemplate() throws -> SkinStyleTemplate {
        guard let url = Bundle.module.url(forResource:"自然浅粉",withExtension:"json",subdirectory:"Styles") else {
            throw ImageError.maskFailed("缺少内置自然浅粉模板")
        }
        var target = try JSONDecoder().decode(SkinStyleTemplate.self,from:Data(contentsOf:url))
        // This is a derived quick-mode look, not a replacement of the archived
        // reference measurement. The independent reference library stays intact.
        target.id = UUID(uuidString:"C8F71BCE-C63F-47C2-BB5A-06052DCB2B70")!
        target.name = "自然浅粉 · 柔和目标"
        target.scene = "由1号参考派生的柔和外观目标，非原图测量"
        if var lips = target.lips, var appearance = lips.appearance {
            appearance.lightness = 57
            appearance.redGreen = 22
            appearance.yellowBlue = 6.5
            lips.appearance = appearance
            lips.reliability = 1
            lips.lightnessDifference = appearance.lightness-appearance.skinLightness
            lips.hueDifference = atan2(appearance.yellowBlue,appearance.redGreen)
                - atan2(target.reference.yellowBlue.median,target.reference.redGreen.median)
            lips.chromaRatio = hypot(appearance.redGreen,appearance.yellowBlue)
                / hypot(target.reference.redGreen.median,target.reference.yellowBlue.median)
            target.lips = lips
        }
        return target
    }

    public func settings(existing: Adjustments, reference suppliedReference: SkinStyleTemplate? = nil) throws -> Adjustments {
        let intent = self
        let storedSkin = existing.portraitIntent?.useReference == true ? existing.skinReference?.template : nil
        let storedLip = existing.portraitIntent?.lip == .reference ? existing.layers.first(where: { $0.mask == .lips })?.lipReference : nil
        let reference = suppliedReference ?? storedSkin ?? storedLip
        try intent.validate()
        if intent.useReference && reference == nil { throw NSError(domain:"Portrait",code:1,
            userInfo:[NSLocalizedDescriptionKey:"请先导入并选择参考图，或关闭借鉴参考肤色"] ) }
        var value = Adjustments()
        value.portraitIntent = intent
        value.repairSpots = existing.repairSpots
        var automatic = AutomaticBaseSettings()
        automatic.targetFaceLightness = 58+intent.brightness*4
        automatic.maxGlobalEV = 0.3
        value.automaticBase = automatic
        let target = intent.useReference ? reference! : intent.skinGoal()
        try target.validate()
        var match = SkinReferenceApplication(template:target)
        match.strength = 0.75
        match.bodyHarmonization = intent.harmonizeBody ? 0.7 : 0
        if intent.look == .original && !intent.useReference {
            match.lightnessAmount = 0; match.colorAmount = 0; match.chromaCompensation = 0
        }
        if existing.skinReference?.template.id == target.id {
            match.brushStrokes = existing.skinReference?.brushStrokes
            match.bodyBrushStrokes = existing.skinReference?.bodyBrushStrokes
        }
        value.skinReference = match
        var skin = AdjustmentLayer(mask:.skin)
        skin.id = UUID(uuidString:"71D028F9-77D4-4E3D-9797-7047DE449A01")!
        skin.name = "快速修图 · 肤色与纹理"
        skin.adjustments.skinUniformity = intent.uniformity*0.5
        skin.adjustments.skinSmoothing = intent.softness*0.35
        skin.adjustments.texturePreservation = 0.9
        skin.adjustments.skinDetail = intent.softness > 0 ? 0.12 : 0
        skin.adjustments.skinEdgeGuard = 1
        skin.highlightProtection = 0.4
        skin.brushStrokes = existing.layers.first { $0.mask == .skin && $0.faceIndex == nil }?.brushStrokes
        var lips = AdjustmentLayer(mask:.lips)
        lips.id = UUID(uuidString:"71D028F9-77D4-4E3D-9797-7047DE449A02")!
        lips.name = "快速修图 · 唇色协调"
        lips.adjustments.lipAdaptation = intent.lipStrength
        lips.brushStrokes = existing.layers.first { $0.mask == .lips && $0.faceIndex == nil }?.brushStrokes
        switch intent.lip {
        case .original: lips.adjustments.lipStyle = .original
        case .softPink:
            lips.adjustments.lipStyle = .reference; lips.lipReference = try Self.softPinkTemplate()
        case .reference:
            guard let reference, reference.lips != nil else { throw NSError(domain:"Portrait",code:2,
                userInfo:[NSLocalizedDescriptionKey:"所选参考没有可用唇色，请改选自然浅粉或保留原唇色"]) }
            lips.adjustments.lipStyle = .reference; lips.lipReference = reference
        }
        value.layers = [skin,lips]
        return value
    }
}
