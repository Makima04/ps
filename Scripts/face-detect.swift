// 人脸关键点提取：用 macOS Vision 输出归一化坐标，供肤色分析定位脸颊。
// 编译：swiftc -O -o Scripts/face-detect Scripts/face-detect.swift
// 用法：Scripts/face-detect 图片1 图片2 ...
// 坐标统一为「原始像素空间 + 左上原点」，与 PIL 未应用 EXIF 方向的读取结果一致。

import Foundation
import ImageIO
import Vision

struct Out: Encodable {
    let image: String
    let width: Int
    let height: Int
    let faces: [Face]
    let error: String?
}

struct Face: Encodable {
    let bbox: [Double]          // x, y, w, h —— 归一化，左上原点
    let leftPupil: [Double]?    // x, y
    let rightPupil: [Double]?
    let mouth: [Double]?        // 嘴角闭合区的中心
    let contour: [[Double]]?    // 脸部轮廓多边形（归一化，左上原点）
    let roll: Double
    let yaw: Double
    let confidence: Double
}

func centroid(_ points: [CGPoint]) -> CGPoint? {
    guard !points.isEmpty else { return nil }
    let sx = points.reduce(0) { $0 + $1.x }
    let sy = points.reduce(0) { $0 + $1.y }
    return CGPoint(x: sx / CGFloat(points.count), y: sy / CGFloat(points.count))
}

func detect(path: String) -> Out {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else {
        return Out(image: path, width: 0, height: 0, faces: [], error: "无法解码")
    }
    let w = cg.width, h = cg.height

    let request = VNDetectFaceLandmarksRequest()
    let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
    do { try handler.perform([request]) } catch {
        return Out(image: path, width: w, height: h, faces: [], error: "检测失败")
    }

    let obs = (request.results ?? []).sorted {
        $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height
    }
    var faces: [Face] = []
    for o in obs {
        let bb = o.boundingBox
        // Vision 为左下原点，转换为左上原点
        let bbox = [Double(bb.minX), Double(1 - bb.maxY), Double(bb.width), Double(bb.height)]

        func map(_ p: CGPoint?) -> [Double]? {
            guard let p else { return nil }
            let x = bb.minX + p.x * bb.width
            let y = (bb.minY + p.y * bb.height)      // 仍在左下原点系
            return [Double(x), Double(1 - y)]
        }

        let lm = o.landmarks
        let mouthPt = lm?.outerLips.flatMap { centroid($0.normalizedPoints) }
        // 脸部轮廓：下颌到鬓角的整圈边界，用来替代椭圆做皮肤区的多边形约束
        let contour = lm?.faceContour?.normalizedPoints.compactMap { map($0) }

        faces.append(
            Face(
                bbox: bbox,
                leftPupil: map(lm?.leftPupil?.normalizedPoints.first),
                rightPupil: map(lm?.rightPupil?.normalizedPoints.first),
                mouth: map(mouthPt),
                contour: (contour?.count ?? 0) >= 8 ? contour : nil,
                roll: Double(o.roll?.doubleValue ?? 0),
                yaw: Double(o.yaw?.doubleValue ?? 0),
                confidence: Double(o.confidence)
            )
        )
    }
    return Out(image: path, width: w, height: h, faces: faces, error: nil)
}

let paths = Array(CommandLine.arguments.dropFirst())
if paths.isEmpty {
    FileHandle.standardError.write("用法：face-detect 图片路径...\n".data(using: .utf8)!)
    exit(2)
}
let results = paths.map { detect(path: $0) }
let enc = JSONEncoder()
enc.outputFormatting = [.withoutEscapingSlashes]
if let data = try? enc.encode(results), let s = String(data: data, encoding: .utf8) {
    print(s)
}
