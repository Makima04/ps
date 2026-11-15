import ColorEngine
import Foundation

struct Photo: Identifiable, Codable, Equatable {
    let id: UUID
    let url: URL
    var settings = Adjustments()
    var portraitSummary: String?
    var portraitWarnings: [String]?

    init(url: URL) {
        self.id = UUID()
        self.url = url
    }
}

struct Preset: Identifiable, Codable, Equatable {
    let name: String
    let settings: Adjustments

    var id: String { name }

    static let standard: [Preset] = [
        Preset(name: "原始色彩", settings: Adjustments()),
        Preset(name: "自然通透", settings: adjusted {
            $0.exposure = 0.18
            $0.shadows = 0.15
            $0.highlights = -0.12
            $0.saturation = 0.06
        }),
        Preset(name: "暖调人像", settings: adjusted {
            $0.temperature = 450
            $0.tint = 3
            $0.shadows = 0.14
            $0.saturation = -0.05
        }),
        Preset(name: "低饱和胶片", settings: adjusted {
            $0.highlights = -0.26
            $0.shadows = 0.18
            $0.saturation = -0.30
            $0.curve = 0.025
        }),
        Preset(name: "高反差黑白", settings: adjusted {
            $0.saturation = -1
            $0.curve = 0.06
        })
    ]

    private static func adjusted(_ configure: (inout Adjustments) -> Void) -> Adjustments {
        var settings = Adjustments()
        configure(&settings)
        return settings
    }
}

struct Project: Codable, Equatable {
    var version = 1
    var photos: [Photo] = []
    var customPresets: [Preset] = []
    var skinTemplates: [SkinStyleTemplate]?
}
