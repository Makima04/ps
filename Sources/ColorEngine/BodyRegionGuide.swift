import CoreImage
import Vision

/// Spatial priors keep skin-coloured lace, hats and skirts out of limb candidates.
/// This is a conservative pose/color candidate, not a body skin segmentation model.
enum BodyRegionGuide {
    static func make(_ image: CIImage, context: CIContext) throws -> CIImage {
        let extent = image.extent
        let scale = min(1, 1200 / max(extent.width, extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let input = context.createCGImage(small, from: small.extent,
                                                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw ImageError.maskFailed("无法读取身体姿态图像")
        }
        let request = VNDetectHumanBodyPoseRequest()
        try VNImageRequestHandler(cgImage: input).perform([request])
        let width = input.width, height = input.height
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                     bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw ImageError.maskFailed("无法创建肢体候选选区")
        }
        bitmap.setFillColor(gray: 0, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.setStrokeColor(gray: 1, alpha: 1)
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.setLineCap(.round)
        for pose in request.results ?? [] {
            func point(_ joint: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
                guard let p = try? pose.recognizedPoint(joint), p.confidence >= 0.35 else { return nil }
                return CGPoint(x: p.location.x * Double(width), y: p.location.y * Double(height))
            }
            guard let ls = point(.leftShoulder), let rs = point(.rightShoulder) else { continue }
            let span = hypot(ls.x - rs.x, ls.y - rs.y)
            func segment(_ a: VNHumanBodyPoseObservation.JointName, _ b: VNHumanBodyPoseObservation.JointName, _ thickness: Double) {
                guard let start = point(a), let end = point(b) else { return }
                bitmap.setLineWidth(max(2, span * thickness))
                bitmap.move(to: start); bitmap.addLine(to: end); bitmap.strokePath()
            }
            typealias Joint = VNHumanBodyPoseObservation.JointName
            let arms: [(Joint, Joint, Joint)] = [(.leftShoulder, .leftElbow, .leftWrist),
                                                  (.rightShoulder, .rightElbow, .rightWrist)]
            for (shoulder, elbow, wrist) in arms {
                segment(shoulder, elbow, 0.34)
                segment(elbow, wrist, 0.28)
                if let w = point(wrist), let e = point(elbow) {
                    let center = CGPoint(x: w.x + (w.x - e.x) * 0.2, y: w.y + (w.y - e.y) * 0.2)
                    let radius = span * 0.19
                    bitmap.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2*radius, height: 2*radius))
                }
            }
            segment(.leftHip, .leftKnee, 0.32); segment(.rightHip, .rightKnee, 0.32)
            segment(.leftKnee, .leftAnkle, 0.23); segment(.rightKnee, .rightAnkle, 0.23)
        }
        guard let cg = bitmap.makeImage() else { throw ImageError.maskFailed("肢体选区生成失败") }
        return CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(scaleX: extent.width / Double(width), y: extent.height / Double(height)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY)).cropped(to: extent)
    }
    static func hands(_ image: CIImage, context: CIContext) throws -> CIImage {
        let extent = image.extent
        let scale = min(1, 1800 / max(extent.width, extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let input = context.createCGImage(small, from: small.extent,
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw ImageError.maskFailed("无法读取手部姿态图像")
        }
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 6
        try VNImageRequestHandler(cgImage: input).perform([request])
        let w = input.width, h = input.height
        guard let bitmap = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw ImageError.maskFailed("无法创建手部候选选区")
        }
        bitmap.setFillColor(gray: 0, alpha: 1); bitmap.fill(CGRect(x: 0, y: 0, width: w, height: h))
        bitmap.setFillColor(gray: 1, alpha: 1)
        for hand in request.results ?? [] {
            let joints = try hand.recognizedPoints(.all).values.filter { $0.confidence >= 0.35 }
            guard joints.count >= 10 else { continue }
            let points = joints.map { CGPoint(x: $0.location.x * Double(w), y: $0.location.y * Double(h)) }
            let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
            func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
                (a.x-o.x)*(b.y-o.y)-(a.y-o.y)*(b.x-o.x)
            }
            var lower: [CGPoint] = [], upper: [CGPoint] = []
            for p in sorted {
                while lower.count >= 2 && cross(lower[lower.count-2],lower.last!,p) <= 0 { lower.removeLast() }
                lower.append(p)
            }
            for p in sorted.reversed() {
                while upper.count >= 2 && cross(upper[upper.count-2],upper.last!,p) <= 0 { upper.removeLast() }
                upper.append(p)
            }
            let hull = Array(lower.dropLast()) + Array(upper.dropLast())
            guard let first = hull.first else { continue }
            bitmap.beginPath(); bitmap.move(to: first)
            for p in hull.dropFirst() { bitmap.addLine(to: p) }
            bitmap.closePath(); bitmap.fillPath()
        }
        guard let cg = bitmap.makeImage() else { throw ImageError.maskFailed("手部候选生成失败") }
        return CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 2.5])
            .transformed(by: CGAffineTransform(scaleX: extent.width/Double(w), y: extent.height/Double(h)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY)).cropped(to: extent)
    }

}
