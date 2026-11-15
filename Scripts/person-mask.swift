// 人物分割：用 macOS Vision 生成人物蒙版，供背景虚化使用。
// 编译：swiftc -O -o Scripts/person-mask Scripts/person-mask.swift
// 用法：Scripts/person-mask 输入.jpg 输出.png

import Foundation
import ImageIO
import Vision
import CoreImage

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    FileHandle.standardError.write("用法：person-mask 输入.jpg 输出.png\n".data(using: .utf8)!)
    exit(2)
}

let url = URL(fileURLWithPath: args[0])
guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write("无法解码输入图\n".data(using: .utf8)!)
    exit(1)
}

let request = VNGeneratePersonSegmentationRequest()
request.qualityLevel = .accurate
request.outputPixelFormat = kCVPixelFormatType_OneComponent8

let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
do {
    try handler.perform([request])
} catch {
    FileHandle.standardError.write("分割失败：\(error)\n".data(using: .utf8)!)
    exit(1)
}

guard let obs = request.results?.first else {
    FileHandle.standardError.write("未检测到人物\n".data(using: .utf8)!)
    exit(1)
}

let pb = obs.pixelBuffer
let ctx = CIContext()
let ci = CIImage(cvPixelBuffer: pb)
guard let maskCG = ctx.createCGImage(ci, from: ci.extent) else {
    FileHandle.standardError.write("蒙版转换失败\n".data(using: .utf8)!)
    exit(1)
}

let outURL = URL(fileURLWithPath: args[1])
guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil) else {
    FileHandle.standardError.write("无法写入输出\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(dest, maskCG, nil)
CGImageDestinationFinalize(dest)
print("\(cg.width)x\(cg.height) -> mask \(maskCG.width)x\(maskCG.height)")
