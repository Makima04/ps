// 人体姿态关键点：用 macOS Vision 输出归一化关节坐标，为「肢体皮肤」提供空间先验。
// 编译：swiftc -O -o Scripts/body-pose Scripts/body-pose.swift
// 用法：Scripts/body-pose 图片1 图片2 ...
// 坐标为「归一化 + 左上原点」，与 face-detect 一致。

import Foundation
import ImageIO
import Vision

struct Pose: Encodable {
    let confidence: Double
    let joints: [String: [Double]]   // name -> [x, y, confidence]
}

struct Out: Encodable {
    let image: String
    let width: Int
    let height: Int
    let poses: [Pose]
    let error: String?
}

let jointNames: [(String, VNHumanBodyPoseObservation.JointName)] = [
    ("nose", .nose),
    ("neck", .neck),
    ("root", .root),
    ("leftShoulder", .leftShoulder), ("rightShoulder", .rightShoulder),
    ("leftElbow", .leftElbow), ("rightElbow", .rightElbow),
    ("leftWrist", .leftWrist), ("rightWrist", .rightWrist),
    ("leftHip", .leftHip), ("rightHip", .rightHip),
    ("leftKnee", .leftKnee), ("rightKnee", .rightKnee),
    ("leftAnkle", .leftAnkle), ("rightAnkle", .rightAnkle),
]

func detect(path: String) -> Out {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else {
        return Out(image: path, width: 0, height: 0, poses: [], error: "无法解码")
    }
    let w = cg.width, h = cg.height

    let request = VNDetectHumanBodyPoseRequest()
    let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
    do { try handler.perform([request]) } catch {
        return Out(image: path, width: w, height: h, poses: [], error: "检测失败")
    }

    var poses: [Pose] = []
    for o in (request.results ?? []) {
        var dict: [String: [Double]] = [:]
        for (name, key) in jointNames {
            guard let p = try? o.recognizedPoint(key), p.confidence > 0.1 else { continue }
            // Vision 为左下原点，转换为左上原点
            dict[name] = [Double(p.location.x), Double(1 - p.location.y), Double(p.confidence)]
        }
        if !dict.isEmpty {
            poses.append(Pose(confidence: Double(o.confidence), joints: dict))
        }
    }
    return Out(image: path, width: w, height: h, poses: poses, error: nil)
}

let paths = Array(CommandLine.arguments.dropFirst())
if paths.isEmpty {
    FileHandle.standardError.write("用法：body-pose 图片路径...\n".data(using: .utf8)!)
    exit(2)
}
let results = paths.map { detect(path: $0) }
let enc = JSONEncoder()
enc.outputFormatting = [.withoutEscapingSlashes]
if let data = try? enc.encode(results), let s = String(data: data, encoding: .utf8) {
    print(s)
}
