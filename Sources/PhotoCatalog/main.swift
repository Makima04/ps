import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

struct CatalogEntry: Codable {
    let filename: String
    let source: String
    let day: String
    let timestamp: String
    let dateSource: String
    let width: Int?
    let height: Int?
    let bytes: Int64
    let modified: Date
    var faceCount: Int?
    var largestFaceArea: Double?
    var scanError: String?
}

struct Catalog: Codable {
    let version: Int
    let source: String
    var entries: [CatalogEntry]
    var failures: [String]
}

struct CandidateGroup: Codable {
    let day: String
    let count: Int
    let files: [String]
}

enum CatalogError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}

let imageExtensions: Set<String> = ["jpg", "jpeg", "arw", "dng", "nef", "cr2", "cr3", "raf", "orf", "rw2", "tif", "tiff", "heic", "heif", "png"]
let renderedExtensions: Set<String> = ["jpg", "jpeg", "tif", "tiff", "heic", "heif", "png"]

func progress(_ text: String) {
    print(text)
    fflush(stdout)
}

func normalizedTimestamp(_ text: String?) -> String? {
    guard let text, text.count >= 19 else { return nil }
    let candidate = String(text.prefix(19))
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    formatter.isLenient = false
    guard let date = formatter.date(from: candidate),
          formatter.string(from: date) == candidate else { return nil }
    return candidate
}

func readEntry(_ url: URL) throws -> CatalogEntry {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        throw CatalogError.message("无法读取元数据：\(url.lastPathComponent)")
    }
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    let choices: [(String, String?)] = [
        ("EXIF DateTimeOriginal", exif[kCGImagePropertyExifDateTimeOriginal] as? String),
        ("EXIF DateTimeDigitized", exif[kCGImagePropertyExifDateTimeDigitized] as? String),
        ("TIFF DateTime", tiff[kCGImagePropertyTIFFDateTime] as? String)
    ]
    let resources = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
    var timestamp: String?
    var dateSource = ""
    for (name, value) in choices {
        if let valid = normalizedTimestamp(value) {
            timestamp = valid
            dateSource = name
            break
        }
    }
    if timestamp == nil {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let fallback = resources.creationDate ?? resources.contentModificationDate else {
            throw CatalogError.message("没有可用日期：\(url.lastPathComponent)")
        }
        timestamp = formatter.string(from: fallback)
        dateSource = resources.creationDate != nil ? "文件创建时间（Asia/Shanghai）" : "文件修改时间（Asia/Shanghai）"
    }
    let date = timestamp!
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    let rotated = (5...8).contains(orientation)
    return CatalogEntry(
        filename: url.lastPathComponent, source: url.path,
        day: String(date.prefix(10)).replacingOccurrences(of: ":", with: "-"),
        timestamp: date, dateSource: dateSource,
        width: properties[rotated ? kCGImagePropertyPixelHeight : kCGImagePropertyPixelWidth] as? Int,
        height: properties[rotated ? kCGImagePropertyPixelWidth : kCGImagePropertyPixelHeight] as? Int,
        bytes: Int64(resources.fileSize ?? 0), modified: resources.contentModificationDate ?? .distantPast
    )
}

func thumbnail(_ path: String, maxSize: Int) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceShouldCacheImmediately: true
          ] as CFDictionary) else {
        throw CatalogError.message("无法读取缩略图：\(URL(fileURLWithPath: path).lastPathComponent)")
    }
    return image
}

func scanFaces(_ path: String) throws -> (Int, Double) {
    let image = try thumbnail(path, maxSize: 1000)
    let request = VNDetectFaceRectanglesRequest()
    request.preferBackgroundProcessing = true
    let handler = VNImageRequestHandler(cgImage: image)
    try handler.perform([request])
    let faces = (request.results ?? []).filter { $0.confidence >= 0.7 && $0.boundingBox.height >= 0.03 }
    return (faces.count, faces.map { Double($0.boundingBox.width * $0.boundingBox.height) }.max() ?? 0)
}

func saveJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
}

func link(_ source: String, to destination: URL) throws {
    let manager = FileManager.default
    if let existing = try? manager.destinationOfSymbolicLink(atPath: destination.path) {
        guard existing == source else {
            throw CatalogError.message("链接目标冲突：\(destination.path)")
        }
        return
    }
    guard !manager.fileExists(atPath: destination.path) else {
        throw CatalogError.message("目标路径已存在：\(destination.path)")
    }
    try manager.createSymbolicLink(atPath: destination.path, withDestinationPath: source)
}

func candidateGroups(_ entries: [CatalogEntry]) -> [[CatalogEntry]] {
    let people = entries.filter { ($0.faceCount ?? 0) > 0 }.sorted { $0.timestamp < $1.timestamp }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    var groups: [[CatalogEntry]] = []
    for entry in people {
        if let last = groups.last?.last,
           last.day == entry.day,
           let a = formatter.date(from: last.timestamp),
           let b = formatter.date(from: entry.timestamp),
           b.timeIntervalSince(a) <= 300 {
            groups[groups.count - 1].append(entry)
        } else {
            groups.append([entry])
        }
    }
    return groups.sorted {
        if $0.count != $1.count { return $0.count > $1.count }
        return $0[0].timestamp < $1[0].timestamp
    }
}

func contactSheet(_ entries: [CatalogEntry], at url: URL) throws {
    let columns = 5
    let cellWidth = 280
    let cellHeight = 235
    let rows = (entries.count + columns - 1) / columns
    let width = columns * cellWidth
    let height = max(1, rows) * cellHeight + 52
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: width * 4, space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw CatalogError.message("无法生成预览")
    }
    context.setFillColor(CGColor(gray: 0.07, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    defer { NSGraphicsContext.restoreGraphicsState() }
    let title: NSString = "人物候选 · \(entries.first?.day ?? "") · 按拍摄时间排列" as NSString
    title.draw(at: CGPoint(x: 18, y: height - 34), withAttributes: [
        .font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.white
    ])
    for (index, entry) in entries.enumerated() {
        let column = index % columns
        let row = index / columns
        let bottom = height - 52 - (row + 1) * cellHeight
        let image = try thumbnail(entry.source, maxSize: 500)
        let available = CGRect(x: column * cellWidth + 8, y: bottom + 37, width: cellWidth - 16, height: cellHeight - 45)
        let scale = min(available.width / CGFloat(image.width), available.height / CGFloat(image.height))
        let rect = CGRect(x: available.midX - CGFloat(image.width) * scale / 2,
                          y: available.midY - CGFloat(image.height) * scale / 2,
                          width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        let label = "\(entry.filename) · \(entry.faceCount ?? 0) 人脸" as NSString
        label.draw(at: CGPoint(x: column * cellWidth + 10, y: bottom + 16), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white
        ])
    }
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw CatalogError.message("无法保存预览")
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw CatalogError.message("预览写入失败") }
}

struct FaceScanResult: Sendable {
    let index: Int
    let count: Int?
    let area: Double?
    let error: String?
}

func analyzeFace(index: Int, path: String) -> FaceScanResult {
    do {
        let result = try autoreleasepool { try scanFaces(path) }
        return FaceScanResult(index: index, count: result.0, area: result.1, error: nil)
    } catch {
        return FaceScanResult(index: index, count: nil, area: nil, error: error.localizedDescription)
    }
}

func run() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains("--help") || arguments.isEmpty {
        print("用法：swift run PhotoCatalog --source <照片目录> --output <分类目录> [--dates-only]")
        print("按照片拍摄日期创建 YYYY-MM-DD 文件夹，使用链接组织原图，默认同时扫描人脸。")
        return
    }
    func value(_ key: String) throws -> String {
        guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else {
            throw CatalogError.message("缺少参数 \(key)")
        }
        return arguments[index + 1]
    }
    let source = URL(fileURLWithPath: try value("--source"), isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let output = URL(fileURLWithPath: try value("--output"), isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    guard source != output, !output.path.hasPrefix(source.path + "/") else {
        throw CatalogError.message("分类目录需要位于原图目录之外。")
    }
    let manager = FileManager.default
    let files = try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    try manager.createDirectory(at: output, withIntermediateDirectories: true)
    let catalogURL = output.appendingPathComponent("catalog.json")
    let previous: Catalog?
    if manager.fileExists(atPath: catalogURL.path) {
        previous = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL))
        guard previous?.source == source.path else { throw CatalogError.message("输出目录已用于其他照片目录。") }
    } else {
        previous = nil
    }
    let cached = Dictionary((previous?.entries ?? []).map { ($0.source, $0) }, uniquingKeysWith: { _, latest in latest })
    var catalog = Catalog(version: 1, source: source.path, entries: [], failures: [])
    progress("读取 \(files.count) 个图像文件的拍摄日期…")
    for (index, url) in files.enumerated() {
        do {
            let resources = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let entry: CatalogEntry
            if let old = cached[url.path],
               old.bytes == Int64(resources.fileSize ?? 0),
               old.modified == resources.contentModificationDate {
                entry = old
            } else {
                entry = try autoreleasepool { try readEntry(url) }
            }
            let dayFolder = output.appendingPathComponent(entry.day, isDirectory: true)
            try manager.createDirectory(at: dayFolder, withIntermediateDirectories: true)
            try link(entry.source, to: dayFolder.appendingPathComponent(entry.filename))
            catalog.entries.append(entry)
        } catch {
            catalog.failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
        }
        if (index + 1) % 200 == 0 { progress("日期分类 \(index + 1) / \(files.count)") }
    }
    try saveJSON(catalog, to: catalogURL)
    let days = Dictionary(grouping: catalog.entries, by: \.day)
    for day in days.keys.sorted() {
        let entries = days[day]!
        let captures = Set(entries.map { URL(fileURLWithPath: $0.filename).deletingPathExtension().lastPathComponent }).count
        progress("\(day)  \(captures) 次拍摄 / \(entries.count) 个文件")
    }

    if !arguments.contains("--dates-only") {
        // Prefer JPEGs when a RAW+JPEG pair shares a stem.
        let renderedStems = Set(catalog.entries.filter {
            renderedExtensions.contains(URL(fileURLWithPath: $0.source).pathExtension.lowercased())
        }.map { URL(fileURLWithPath: $0.source).deletingPathExtension().path })
        let indices = catalog.entries.indices.filter { index in
            let entry = catalog.entries[index]
            let url = URL(fileURLWithPath: entry.source)
            return entry.faceCount == nil && (renderedExtensions.contains(url.pathExtension.lowercased())
                || !renderedStems.contains(url.deletingPathExtension().path))
        }
        progress("开始本机人脸检测，待扫描 \(indices.count) 张照片…")
        try await withThrowingTaskGroup(of: FaceScanResult.self) { group in
            var pending = indices.makeIterator()
            for _ in 0..<4 {
                if let index = pending.next() {
                    let path = catalog.entries[index].source
                    group.addTask { analyzeFace(index: index, path: path) }
                }
            }
            var completed = 0
            while let result = try await group.next() {
                catalog.entries[result.index].faceCount = result.count
                catalog.entries[result.index].largestFaceArea = result.area
                catalog.entries[result.index].scanError = result.error
                completed += 1
                if completed % 50 == 0 || completed == indices.count {
                    try saveJSON(catalog, to: catalogURL)
                    progress("人物筛选 \(completed) / \(indices.count)")
                }
                if let index = pending.next() {
                    let path = catalog.entries[index].source
                    group.addTask { analyzeFace(index: index, path: path) }
                }
            }
        }
        let groups = candidateGroups(catalog.entries)
        try saveJSON(groups.prefix(20).map {
            CandidateGroup(day: $0[0].day, count: $0.count, files: $0.map(\.filename))
        }, to: output.appendingPathComponent("portrait-candidates.json"))
        if let best = groups.first {
            let limit = min(best.count, 30)
            let sample = (0..<limit).map { best[$0 * best.count / limit] }
            try contactSheet(sample, at: output.appendingPathComponent("portrait-candidates.jpg"))
            progress("最大连续人物候选组：\(best[0].day)，\(best.count) 张。")
        }
    }
    let fallback = catalog.entries.filter { !$0.dateSource.hasPrefix("EXIF") && !$0.dateSource.hasPrefix("TIFF") }
    var summary = "# 按拍摄日期分类\n\n原图目录 \(source.path)\n\n分类方式为原图文件链接。RAW 与 JPEG 各自保留，导入调色工作室时选择 JPEG。\n\n"
    summary += "| 日期 | 拍摄数 | 文件数 | 有人脸的照片 |\n|---|---:|---:|---:|\n"
    for day in days.keys.sorted() {
        let entries = catalog.entries.filter { $0.day == day }
        let count = Set(entries.map { URL(fileURLWithPath: $0.filename).deletingPathExtension().lastPathComponent }).count
        summary += "| \(day) | \(count) | \(entries.count) | \(entries.filter { ($0.faceCount ?? 0) > 0 }.count) |\n"
    }
    summary += "\n使用文件时间回退的文件数为 \(fallback.count)。分类失败数为 \(catalog.failures.count)。人脸检测只用于筛选人物照片，同一人物的测试组需要结合候选预览确认。\n"
    if !catalog.failures.isEmpty { summary += "\n" + catalog.failures.joined(separator: "\n") + "\n" }
    try summary.write(to: output.appendingPathComponent("分类说明.md"), atomically: true, encoding: .utf8)
    progress("完成。结果位于 \(output.path)")
}

do {
    try await run()
} catch {
    fputs("错误：\(error.localizedDescription)\n", stderr)
    exit(1)
}
