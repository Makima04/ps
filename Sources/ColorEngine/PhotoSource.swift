import Foundation

/// A photo split into the file that supplies pixels, the file used for face/person
/// analysis, and the file that supplies EXIF/DPI metadata.
///
/// For a Sony-style ARW + JPEG pair the RAW file is the pixel source (14-bit linear
/// demosaic, Display P3, far more highlight headroom), while the camera JPEG is used
/// for Vision/Core ML masks: it is gamma-encoded, small and already tone-mapped, so
/// detectors see the same image the photographer saw. Passing a lone JPEG, a lone
/// ARW, or a TIFF still works — the resolver simply falls back to that file.
public struct PhotoSource: Hashable, Sendable {
    /// File decoded into the working image. ARW is preferred when available.
    public let imageURL: URL
    /// File rendered for Vision face detection and Core ML semantic masks.
    public let analysisURL: URL
    /// File read for orientation, DPI and other container metadata.
    public let metadataURL: URL
    /// True when `imageURL` is a camera RAW file.
    public let isRAW: Bool
    /// True when a same-stem JPEG accompanies the RAW file.
    public let hasPairedJPEG: Bool

    public static let rawExtensions: Set<String> = [
        "arw", "srf", "sr2", "cr2", "cr3", "nef", "nrw", "raf", "orf", "rw2", "pef",
        "dng", "raw", "3fr", "fff", "iiq"
    ]
    public static let jpegExtensions: Set<String> = ["jpg", "jpeg", "jpe"]
    public static let stillExtensions: Set<String> = ["tiff", "tif", "png", "heic", "heif"]

    private static let rawCandidates = ["ARW", "arw", "DNG", "dng", "CR3", "cr3", "NEF", "nef", "RAF", "raf"]
    private static let jpegCandidates = ["JPG", "jpg", "JPEG", "jpeg"]

    /// A short, human-readable description for logs and UI status lines.
    public var label: String {
        if isRAW && hasPairedJPEG {
            return "\(imageURL.lastPathComponent)（分析参考 \(analysisURL.lastPathComponent)）"
        }
        return imageURL.lastPathComponent
    }

    /// Resolves the source for `url`.
    ///
    /// - Parameter preferRAW: `true` (default) makes a same-stem ARW the pixel source
    ///   even when the caller passes the JPEG. `false` keeps the legacy JPEG-only
    ///   pipeline by picking the paired JPEG as the pixel source instead.
    public static func resolve(_ url: URL, preferRAW: Bool = true) -> PhotoSource {
        // Catalog folders contain symlinks (JPEG/ and RAW/ are separate). Resolve
        // them so the ARW sibling is found next to the real source file.
        let input = url.resolvingSymlinksInPath().standardizedFileURL
        let ext = input.pathExtension.lowercased()
        let inputIsRAW = rawExtensions.contains(ext)
        let inputIsJPEG = jpegExtensions.contains(ext)

        let pairedRAW = pairedURL(for: input, extensions: rawCandidates)
        let pairedJPEG = pairedURL(for: input, extensions: jpegCandidates)

        let candidateRAW = inputIsRAW ? input : pairedRAW
        let candidateJPEG = inputIsJPEG ? input : pairedJPEG

        if preferRAW, let raw = candidateRAW {
            let jpeg = candidateJPEG
            return PhotoSource(imageURL: raw,
                               analysisURL: jpeg ?? raw,
                               metadataURL: jpeg ?? raw,
                               isRAW: true,
                               hasPairedJPEG: jpeg != nil)
        }
        if !preferRAW, let jpeg = candidateJPEG {
            return PhotoSource(imageURL: jpeg,
                               analysisURL: jpeg,
                               metadataURL: jpeg,
                               isRAW: false,
                               hasPairedJPEG: false)
        }
        return PhotoSource(imageURL: input,
                           analysisURL: candidateJPEG ?? input,
                           metadataURL: candidateJPEG ?? input,
                           isRAW: inputIsRAW,
                           hasPairedJPEG: inputIsRAW && candidateJPEG != nil)
    }

    /// Looks for a sibling file with the same stem, tolerating extension case.
    private static func pairedURL(for url: URL, extensions: [String]) -> URL? {
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        return extensions.lazy
            .map { directory.appendingPathComponent(stem).appendingPathExtension($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
