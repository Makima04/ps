import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let base = "/Users/makima/program/Ps/100MSDCF/DSC00681"
for ext in ["ARW", "JPG"] {
    let url = URL(fileURLWithPath: base + "." + ext)
    print("=== \(ext) ===")
    if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
       let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
        print("  props W/H:", p[kCGImagePropertyPixelWidth] ?? "?", p[kCGImagePropertyPixelHeight] ?? "?",
              "orientation:", p[kCGImagePropertyOrientation] ?? "?",
              "profile:", p[kCGImagePropertyProfileName] ?? "?")
    }
    if let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) {
        print("  CIImage:", img.extent, "cs:", img.colorSpace?.name as Any, "props:", img.properties.keys.prefix(6))
    } else { print("  CIImage: nil") }
}
let rawURL = URL(fileURLWithPath: base + ".ARW")
if let f = CIFilter(imageURL: rawURL, options: nil) {
    print("=== CIFilter(imageURL) ===", type(of: f))
    let keys = f.attributes.keys.sorted()
    print("  attrs:", keys.joined(separator: ", "))
    if let out = f.outputImage { print("  output:", out.extent, "cs:", out.colorSpace?.name as Any) }
} else { print("  CIFilter(imageURL): nil") }
