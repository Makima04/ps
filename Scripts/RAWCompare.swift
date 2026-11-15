import AppKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

let root = "/Users/makima/program/Ps/100MSDCF/DSC00681"
let jpegURL = URL(fileURLWithPath: root + ".JPG")
let rawURL = URL(fileURLWithPath: root + ".ARW")

let context = CIContext(options: [
    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
    .workingFormat: CIFormat.RGBAf
])
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func png(_ image: CIImage, rect: CGRect) -> CGImage {
    context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: sRGB)!
}

let jpeg = CIImage(contentsOf: jpegURL, options: [.applyOrientationProperty: true])!
let rawDefault = CIImage(contentsOf: rawURL, options: [.applyOrientationProperty: true])!
let rawFilter = CIFilter(imageURL: rawURL, options: nil)!
let rawFilterImage = rawFilter.outputImage!
let boosted = CIFilter(imageURL: rawURL, options: nil)!
boosted.setValue(0.35, forKey: "inputEV")
boosted.setValue(1.0, forKey: "inputBoost")
let boostedImage = boosted.outputImage!

print("JPG", jpeg.extent, jpeg.colorSpace?.name as Any)
print("RAW CIImage", rawDefault.extent, rawDefault.colorSpace?.name as Any)
print("RAW filter", rawFilterImage.extent, rawFilterImage.colorSpace?.name as Any)
print("RAW boosted", boostedImage.extent, boostedImage.colorSpace?.name as Any)

let reference = png(jpeg, rect: jpeg.extent)
let request = VNDetectFaceRectanglesRequest()
try VNImageRequestHandler(cgImage: reference).perform([request])
let face = request.results!.max { $0.boundingBox.width < $1.boundingBox.width }!.boundingBox
let width = face.width * Double(reference.width) * 2.0
let height = width * 1.2
// createCGImage(from:) uses CIImage coordinates (bottom-left origin), like Vision boxes.
let rect = CGRect(x: face.midX * Double(reference.width) - width / 2,
                  y: face.midY * Double(reference.height) - height / 2,
                  width: width, height: height).integral
    .intersection(CGRect(x: 0, y: 0, width: reference.width, height: reference.height))
print("crop", rect)

let images = [jpeg, rawDefault, rawFilterImage, boostedImage]
let labels = ["JPG 原图 (sRGB)", "ARW CIImage 默认", "ARW CIRAWFilter 默认", "ARW EV+0.35 / Boost 1.0"]
let cellWidth = 420
let cellHeight = Int(Double(cellWidth) * rect.height / rect.width)
let canvas = CGContext(data: nil, width: cellWidth * images.count, height: cellHeight + 48,
                       bitsPerComponent: 8, bytesPerRow: cellWidth * images.count * 4,
                       space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
canvas.setFillColor(CGColor(gray: 0.09, alpha: 1))
canvas.fill(CGRect(x: 0, y: 0, width: cellWidth * images.count, height: cellHeight + 48))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: false)
defer { NSGraphicsContext.restoreGraphicsState() }
for (index, image) in images.enumerated() {
    canvas.interpolationQuality = .high
    let crop = png(image, rect: rect)
    canvas.draw(crop, in: CGRect(x: index * cellWidth, y: 0, width: cellWidth, height: cellHeight))
    (labels[index] as NSString).draw(at: CGPoint(x: index * cellWidth + 14, y: cellHeight + 14),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium),
                                                      .foregroundColor: NSColor.white])
}
let output = URL(fileURLWithPath: "/Users/makima/program/Ps/.build/QA/raw-decode-compare.png")
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, canvas.makeImage()!, nil)
CGImageDestinationFinalize(destination)
print(output.path)
