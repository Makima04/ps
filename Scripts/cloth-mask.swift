// 服装分割：直接调用项目内已有的 ClothSegmentation.mlmodelc，输出「非服装」概率图。
// 编译：swiftc -O -o Scripts/cloth-mask Scripts/cloth-mask.swift
// 用法：Scripts/cloth-mask <模型目录> <输出png> 图片1 图片2 ...
// 输出为 8 位灰度 PNG（255 = 服装），尺寸随模型（当前 768×768），由调用方放大使用。

import CoreML
import Foundation
import ImageIO
import CoreGraphics
import Vision

func loadCG(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func writeGray(_ data: [UInt8], _ w: Int, _ h: Int, _ path: String) {
    guard let provider = CGDataProvider(data: Data(data) as CFData),
          let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8,
                            bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                    "public.png" as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.count < 3 {
    FileHandle.standardError.write("用法：cloth-mask <模型> <输出png> 图片...\n".data(using: .utf8)!)
    exit(2)
}
let modelPath = args[0]
let outPath = args[1]
let paths = Array(args.dropFirst(2))

let conf = MLModelConfiguration()
conf.computeUnits = .cpuOnly
guard let model = try? MLModel(contentsOf: URL(fileURLWithPath: modelPath), configuration: conf) else {
    FileHandle.standardError.write("无法加载模型\n".data(using: .utf8)!)
    exit(3)
}
guard let input = model.modelDescription.inputDescriptionsByName.first,
      let constraint = input.value.imageConstraint,
      let first = paths.first, let cg = loadCG(first) else {
    FileHandle.standardError.write("模型输入不可用\n".data(using: .utf8)!)
    exit(4)
}

let w = constraint.pixelsWide, h = constraint.pixelsHigh
var acc = [Double](repeating: 0, count: w * h)
var count = 0.0

func val(_ t: MLMultiArray, _ i: Int) -> Double {
    switch t.dataType {
    case .float32:
        return Double(t.dataPointer.assumingMemoryBound(to: Float.self)[i])
    case .float16:
        return Double(t.dataPointer.assumingMemoryBound(to: Float16.self)[i])
    case .double:
        return t.dataPointer.assumingMemoryBound(to: Double.self)[i]
    default:
        return t[i].doubleValue
    }
}

for p in paths {
    guard let img = loadCG(p) else { continue }
    guard let feature = try? MLFeatureValue(cgImage: img, constraint: constraint,
                                           options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
    else { continue }
    guard let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: [input.key: feature]))
    else { continue }
    guard let tensor = out.featureValue(for: "probs")?.multiArrayValue else { continue }
    let strides: [Int] = tensor.strides.map { $0.intValue }
    let s1 = strides[1], s2 = strides[2], s3 = strides[3]
    for y in 0..<h {
        for x in 0..<w {
            let off = y * s2 + x * s3
            let bg = val(tensor, off)
            var best = val(tensor, off + s1)
            let second = val(tensor, off + 2 * s1)
            let third = val(tensor, off + 3 * s1)
            if second > best { best = second }
            if third > best { best = third }
            if best > bg { acc[y * w + x] = max(acc[y * w + x], best) }
        }
    }
    count += 1
}

var bytes = [UInt8](repeating: 0, count: w * h)
for i in 0..<(w * h) {
    bytes[i] = UInt8(max(0, min(1, acc[i])) * 255)
}
writeGray(bytes, w, h, outPath)
print("\(outPath) \(w)x\(h) images=\(Int(count))")
