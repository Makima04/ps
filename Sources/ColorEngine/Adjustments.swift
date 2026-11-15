import Foundation

public struct ColorAdjustments: Codable, Equatable, Sendable {
    public var exposure = 0.0
    public var temperature = 0.0
    public var tint = 0.0
    public var contrast = 0.0
    public var shadows = 0.0
    public var highlights = 0.0
    public var saturation = 0.0
    public var curve = 0.0
    public var rednessReduction = 0.0
    /// Softens dark-red lips toward a natural rose/coral tone while keeping lip texture.
    /// Applied selectively through a lips mask layer; 0 keeps the original color.
    public var lipNaturalization = 0.0
    /// Lifts dark lips, adds a rose tint and reduces fine lip lines while keeping the
    /// vermilion border and gloss. Applied through a lips mask layer; 0 is a no-op.
    public var lipPolish = 0.0
    public var lipStyle: LipStyle = .manual
    public var lipAdaptation = 0.65
    public var lipBrightness = 0.0
    public var lipHue = 0.0
    public var lipChroma = 0.0
    public var lipSmoothing = 0.0

    /// Skin controls are independent of exposure and the legacy redness operator.
    public var skinWhitening = 0.0
    public var skinYellowReduction = 0.0
    public var skinUniformity = 0.0
    public var skinVitality = 0.0
    public var cheekBlush = 0.0
    public var skinSmoothing = 0.0
    /// Zero means maximum softening; one preserves the original fine detail.
    public var texturePreservation = 0.75
    /// Restores fine skin detail after smoothing and tone changes; 0 keeps the old output.
    public var skinDetail = 0.0
    /// Prevents whitening and yellow reduction from crossing strong edges such as hair
    /// and the lip border. 0 keeps the previous edge handling.
    public var skinEdgeGuard = 0.0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case exposure, temperature, tint, contrast, shadows, highlights, saturation, curve,
             rednessReduction, lipNaturalization, lipPolish, skinWhitening, skinYellowReduction,
             skinUniformity, skinVitality, cheekBlush, skinSmoothing, texturePreservation,
             skinDetail, skinEdgeGuard, lipStyle, lipAdaptation, lipBrightness, lipHue, lipChroma, lipSmoothing
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try values.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        temperature = try values.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        tint = try values.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        contrast = try values.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        shadows = try values.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        highlights = try values.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        saturation = try values.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        curve = try values.decodeIfPresent(Double.self, forKey: .curve) ?? 0
        rednessReduction = try values.decodeIfPresent(Double.self, forKey: .rednessReduction) ?? 0
        lipNaturalization = try values.decodeIfPresent(Double.self, forKey: .lipNaturalization) ?? 0
        lipPolish = try values.decodeIfPresent(Double.self, forKey: .lipPolish) ?? 0
        lipStyle = try values.decodeIfPresent(LipStyle.self, forKey: .lipStyle) ?? .manual
        lipAdaptation = try values.decodeIfPresent(Double.self, forKey: .lipAdaptation) ?? 0.65
        lipBrightness = try values.decodeIfPresent(Double.self, forKey: .lipBrightness) ?? 0
        lipHue = try values.decodeIfPresent(Double.self, forKey: .lipHue) ?? 0
        lipChroma = try values.decodeIfPresent(Double.self, forKey: .lipChroma) ?? 0
        lipSmoothing = try values.decodeIfPresent(Double.self, forKey: .lipSmoothing) ?? 0
        skinWhitening = try values.decodeIfPresent(Double.self, forKey: .skinWhitening) ?? 0
        skinYellowReduction = try values.decodeIfPresent(Double.self, forKey: .skinYellowReduction) ?? 0
        skinUniformity = try values.decodeIfPresent(Double.self, forKey: .skinUniformity) ?? 0
        skinVitality = try values.decodeIfPresent(Double.self, forKey: .skinVitality) ?? 0
        cheekBlush = try values.decodeIfPresent(Double.self, forKey: .cheekBlush) ?? 0
        skinSmoothing = try values.decodeIfPresent(Double.self, forKey: .skinSmoothing) ?? 0
        texturePreservation = try values.decodeIfPresent(Double.self, forKey: .texturePreservation) ?? 0.75
        skinDetail = try values.decodeIfPresent(Double.self, forKey: .skinDetail) ?? 0
        skinEdgeGuard = try values.decodeIfPresent(Double.self, forKey: .skinEdgeGuard) ?? 0
    }
}

// The existing flat JSON format remains readable by saved projects and presets.
public struct Adjustments: Codable, Equatable, Sendable {
    public var global = ColorAdjustments()
    public var layers: [AdjustmentLayer] = []
    /// Appearance targets are recalculated from this photo after ordinary layers.
    public var skinReference: SkinReferenceApplication?
    public var repairSpots: [RepairSpot]?
    public var automaticBase: AutomaticBaseSettings?
    public var portraitIntent: PortraitIntent?


    public init() {}

    public var exposure: Double {
        get { global.exposure }
        set { global.exposure = newValue }
    }
    public var temperature: Double {
        get { global.temperature }
        set { global.temperature = newValue }
    }
    public var tint: Double {
        get { global.tint }
        set { global.tint = newValue }
    }
    public var contrast: Double {
        get { global.contrast }
        set { global.contrast = newValue }
    }
    public var shadows: Double {
        get { global.shadows }
        set { global.shadows = newValue }
    }
    public var highlights: Double {
        get { global.highlights }
        set { global.highlights = newValue }
    }
    public var saturation: Double {
        get { global.saturation }
        set { global.saturation = newValue }
    }
    public var curve: Double {
        get { global.curve }
        set { global.curve = newValue }
    }

    private enum CodingKeys: String, CodingKey { case layers, skinReference, repairSpots, automaticBase, portraitIntent }

    public init(from decoder: Decoder) throws {
        global = try ColorAdjustments(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layers = try container.decodeIfPresent([AdjustmentLayer].self, forKey: .layers) ?? []
        skinReference = try container.decodeIfPresent(SkinReferenceApplication.self, forKey: .skinReference)
        repairSpots = try container.decodeIfPresent([RepairSpot].self, forKey: .repairSpots)
        automaticBase = try container.decodeIfPresent(AutomaticBaseSettings.self, forKey: .automaticBase)
        portraitIntent = try container.decodeIfPresent(PortraitIntent.self, forKey: .portraitIntent)
    }

    public func encode(to encoder: Encoder) throws {
        try global.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(layers, forKey: .layers)
        try container.encodeIfPresent(skinReference, forKey: .skinReference)
        try container.encodeIfPresent(repairSpots, forKey: .repairSpots)
        try container.encodeIfPresent(automaticBase, forKey: .automaticBase)
        try container.encodeIfPresent(portraitIntent, forKey: .portraitIntent)
    }

    public static func portraitLayers() -> [AdjustmentLayer] {
        var person = AdjustmentLayer(mask: .person)
        person.name = "人物提亮"
        person.adjustments.exposure = 0.35
        person.blendMode = .luminosity
        person.highlightProtection = 0.8

        var highlights = AdjustmentLayer(mask: .highlights)
        highlights.name = "高光压暗"
        highlights.adjustments.exposure = -0.3
        highlights.blendMode = .luminosity
        return [person, highlights]
    }
}

public enum MaskKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case all, person, background, skin, neck, bodySkin, lips, eyes, eyebrows, teeth, hair
    case forehead, leftCheek, rightCheek, underEyes, noseSides, clothing, highlights, shadows
    public var id: Self { self }
    public var label: String {
        switch self {
        case .all: "全图"
        case .person: "人物"
        case .background: "背景"
        case .skin: "脸部皮肤"
        case .neck: "脖子"
        case .bodySkin: "身体皮肤候选"
        case .eyes: "眼睛"
        case .eyebrows: "眉毛"
        case .teeth: "牙齿候选"
        case .hair: "头发"
        case .forehead: "额头"
        case .leftCheek: "画面左脸颊"
        case .rightCheek: "画面右脸颊"
        case .underEyes: "眼下"
        case .noseSides: "鼻侧"
        case .lips: "嘴唇"
        case .clothing: "服装"
        case .highlights: "高光"
        case .shadows: "暗部"
        }
    }
}

extension MaskKind {
    public var isFaceRegion: Bool {
        [.skin, .neck, .lips, .eyes, .eyebrows, .teeth, .hair, .forehead,
         .leftCheek, .rightCheek, .underEyes, .noseSides].contains(self)
    }
    public var isSkinRegion: Bool {
        [.skin, .neck, .bodySkin, .forehead, .leftCheek, .rightCheek,
         .underEyes, .noseSides].contains(self)
    }
}

public enum LayerBlendMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case normal, luminosity, color
    public var id: Self { self }
    public var label: String {
        switch self {
        case .normal: "正常"
        case .luminosity: "明度"
        case .color: "颜色"
        }
    }
}

public struct AdjustmentLayer: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var enabled = true
    public var opacity = 1.0
    public var mask: MaskKind
    public var inverted = false
    // Relative to the original image's longest edge, shared by preview and export.
    public var feather = 0.001
    public var rangeStart = 0.65
    public var rangeEnd = 0.95
    public var highlightProtection = 0.0
    public var blendMode: LayerBlendMode = .normal
    public var adjustments = ColorAdjustments()
    public var brushStrokes: [MaskStroke]?
    /// Detected faces are ordered from image left to right; nil selects all faces.
    public var faceIndex: Int?
    /// A photo-independent lip appearance snapshot, separate from skin matching.
    public var lipReference: SkinStyleTemplate?


    public init(mask: MaskKind) {
        self.mask = mask
        self.name = mask.label + "调整"
        if mask == .skin { feather = 0.0003 }
        if mask == .lips { feather = 0.0004 }
        if mask == .clothing { feather = 0.0007 }
        if mask == .shadows {
            rangeStart = 0.15
            rangeEnd = 0.5
        }
    }
}


public struct MaskPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct MaskStroke: Codable, Equatable, Sendable {
    public var points: [MaskPoint]
    public var radius: Double
    public var erase: Bool

    public init(points: [MaskPoint], radius: Double, erase: Bool) {
        self.points = points
        self.radius = radius
        self.erase = erase
    }
}
