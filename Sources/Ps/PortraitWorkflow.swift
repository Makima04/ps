import Foundation
import ColorEngine

enum PortraitWorkflow {
    static func softPink() throws -> SkinStyleTemplate { try PortraitIntent.softPinkTemplate() }
    static func settings(_ intent: PortraitIntent, existing: Adjustments,
                         reference: SkinStyleTemplate?) throws -> Adjustments {
        try intent.settings(existing:existing,reference:reference)
    }
}
