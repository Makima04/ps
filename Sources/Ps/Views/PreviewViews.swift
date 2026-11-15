import ColorEngine
import ImageIO
import SwiftUI

struct PhotoMetadata: View {
    let url: URL
    @State private var info: PhotoInfo?
    @State private var sourceLabel: String?
    @State private var loading = true

    var body: some View {
        HStack(spacing: 12) {
            if let info {
                Text("\(info.width) × \(info.height)")
                Text(info.profile ?? "无 ICC · 按解码器默认色彩处理")
            } else {
                Text(loading ? "读取尺寸…" : "尺寸信息不可用")
            }
            if let sourceLabel {
                Text(sourceLabel).foregroundStyle(.tint)
            }
        }
        .task(id: url) {
            loading = true
            let result = await Task.detached { () -> (PhotoInfo?, String?) in
                let source = PhotoSource.resolve(url)
                let label = source.isRAW ? "RAW 原图解码 · \(source.imageURL.lastPathComponent)" : nil
                return (try? PhotoInfo.read(source.imageURL), label)
            }.value
            guard !Task.isCancelled else { return }
            info = result.0
            sourceLabel = result.1
            loading = false
        }
    }
}

struct PreviewKey: Equatable {
    let url: URL
    let settings: Adjustments
    let maskLayerID: UUID?
    let referenceMask: Bool
    let referenceBodyMask: Bool
}

struct PreviewView: View {
    let photo: Photo
    let engine: ColorEngine
    let showOriginal: Bool
    @Binding var zoom: Double
    @Binding var actualZoom: Double
    let maskLayerID: UUID?
    let brush: MaskBrushTool
    let brushRadius: Double
    let onStroke: (MaskStroke) -> Void
    let repairMode: Bool
    let repairSource: MaskPoint?
    let onRepairPoint: (MaskPoint, Bool) -> Void
    let referenceMask: Bool
    let referenceBodyMask: Bool
    let blemishes: [BlemishCandidate]
    let selectedBlemishes: Set<UUID>
    let focusedBlemishID: UUID?
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var renderedURL: URL?
    @State private var busy = false
    @State private var failure: String?

    private var key: PreviewKey {
        PreviewKey(url: photo.url, settings: showOriginal ? Adjustments() : photo.settings,
                   maskLayerID: maskLayerID, referenceMask: referenceMask, referenceBodyMask: referenceBodyMask)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image, renderedURL == photo.url {
                    PhotoCanvas(image: image, displayScale: displayScale,
                                zoom: $zoom, actualZoom: $actualZoom,
                                brush: brush, radius: brushRadius, onStroke: onStroke,
                                repairMode: repairMode, repairSource: repairSource, onRepairPoint: onRepairPoint,
                                blemishes: blemishes, selectedBlemishes: selectedBlemishes, focusedBlemishID: focusedBlemishID)
                }
                if let failure {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(failure)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 12))
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .padding(10)
                        .background(.regularMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(10)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .task(id: key) {
            busy = true
            failure = nil
            do {
                try await Task.sleep(for: .milliseconds(70))
                let result = try await engine.preview(key.url, adjustments: key.settings,
                                                      maxEdge: nil,
                                                      maskLayerID: key.maskLayerID, profile: .sRGB,
                                                      referenceMask: key.referenceMask, referenceBodyMask: key.referenceBodyMask)
                try Task.checkCancellation()
                image = result
                renderedURL = key.url
                busy = false
            } catch is CancellationError {
                // The replacement request owns the loading state.
            } catch {
                if !Task.isCancelled {
                    failure = error.localizedDescription
                    busy = false
                }
            }
        }
    }
}

struct PhotoThumbnail: View {
    let photo: Photo
    let selected: Bool
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                Color.black.opacity(0.25)
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                }
                if photo.settings != Adjustments() {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(studioAccent)
                        .padding(4)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                        .padding(5)
                }
            }
            .frame(width: 100, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? studioAccent : .clear, lineWidth: 2))
            Text(photo.url.lastPathComponent)
                .font(.system(size: 10))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: 100)
        }
        .task(id: photo.url) {
            let url = photo.url
            image = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 200
                ] as CFDictionary)
            }.value
        }
    }
}
