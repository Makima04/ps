import CoreImage
import Foundation

public enum BlemishKind: String, Codable, Sendable {
    case redSpot, darkSpot, yellowSpot
    public var label: String {
        switch self {
        case .redSpot: "红色小点"
        case .darkSpot: "深色小点 · 需确认"
        case .yellowSpot: "黄褐色小点 · 需确认"
        }
    }
}

public struct BlemishCandidate: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let faceIndex: Int
    public let kind: BlemishKind
    /// Heuristic ranking, not a calibrated probability or a diagnosis.
    public let score: Double
    public let target: MaskPoint
    public let radius: Double
    public let repair: RepairSpot?
    public var recommended: Bool { kind == .redSpot && score >= 0.72 && repair != nil }

    public init(faceIndex: Int, kind: BlemishKind, score: Double, target: MaskPoint,
                radius: Double, repair: RepairSpot?, id: UUID = UUID()) {
        self.id = id; self.faceIndex = faceIndex; self.kind = kind; self.score = score
        self.target = target; self.radius = radius; self.repair = repair
    }
}

public struct BlemishAnalysis: Codable, Sendable {
    public let candidates: [BlemishCandidate]
    public let warnings: [String]
    public init(candidates: [BlemishCandidate], warnings: [String] = []) {
        self.candidates = candidates; self.warnings = warnings
    }
}

/// Local Lab contrast proposes small spots. Skin semantics supply a permitted
/// area; they do not classify acne, moles, freckles or makeup.
enum BlemishDetector {
    static func detect(_ image: CIImage, permitted: CIImage, box: CGRect, faceIndex: Int,
                       sensitivity: Double, context: CIContext) throws -> [BlemishCandidate] {
        guard sensitivity.isFinite, (0...1).contains(sensitivity) else {
            throw ImageError.maskFailed("瑕疵分析灵敏度必须为 0 到 1")
        }
        let rect = box.integral.intersection(image.extent)
        guard rect.width >= 64, rect.height >= 64 else { return [] }
        let scale = min(1, 768 / max(rect.width, rect.height))
        let transform = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let sample = image.cropped(to: rect).transformed(by: transform)
        let bounds = sample.extent.integral
        let width = Int(bounds.width), height = Int(bounds.height)
        let sampleTop = rect.minY + bounds.maxY / scale
        let allowed = permitted.cropped(to: rect).transformed(by: transform)
        let fine = sample.clampedToExtent().applyingGaussianBlur(sigma: 0.65).cropped(to: bounds)
        let broad = sample.clampedToExtent().applyingGaussianBlur(sigma: 5.2).cropped(to: bounds)
        func bitmap(_ input: CIImage) -> [Float] {
            var values = [Float](repeating: 0, count: width * height * 4)
            values.withUnsafeMutableBytes {
                context.render(input, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                    bounds: bounds, format: .RGBAf, colorSpace: SkinColorMath.linearP3)
            }
            return values
        }
        let pixels = bitmap(fine), lows = bitmap(broad), mask = bitmap(allowed)
        func labs(_ values: [Float]) -> [SIMD3<Double>] {
            stride(from: 0, to: values.count, by: 4).map { i in
                let (l,a,b) = SkinColorMath.lab(Double(values[i]), Double(values[i+1]), Double(values[i+2]))
                return SIMD3(l,a,b)
            }
        }
        let colors = labs(pixels), low = labs(lows)
        let count = width * height
        var classes = [UInt8](repeating: 0, count: count)
        var signals = [Double](repeating: 0, count: count)
        let redThreshold = 3.0 - 2.0 * sensitivity
        let darkThreshold = 5.4 - 2 * sensitivity
        let yellowThreshold = 3.8 - 1.6 * sensitivity
        for i in 0..<count where mask[i*4] > 0.96 && pixels[i*4+3] > 0.99 {
            if i.isMultiple(of:4096) { try Task.checkCancellation() }
            let c = colors[i], b = low[i]
            guard c.x.isFinite, c.y.isFinite, c.z.isFinite, c.x > 25, c.x < 88 else { continue }
            let x = i % width, y = i / width
            guard x >= 2, y >= 2, x < width-2, y < height-2,
                  hypot(low[i+2].x-low[i-2].x,low[i+2*width].x-low[i-2*width].x) < 6 else { continue }
            let red = c.y - b.y, dip = b.x - c.x
            if red > redThreshold && dip > 0.4 {
                classes[i] = 1; signals[i] = red / redThreshold
            } else if c.z - b.z > yellowThreshold && dip > 0.3 && red > -2 {
                // A local yellow/brown colour residual, not a semantic diagnosis.
                // Broad warm lighting is absorbed by the local background.
                classes[i] = 3; signals[i] = (c.z - b.z) / yellowThreshold
            } else if dip > darkThreshold {
                classes[i] = 2; signals[i] = dip / darkThreshold
            }
        }
        func insideDisk(_ x: Double, _ y: Double, _ radius: Double, clean: Bool) -> Bool {
            guard x-radius >= 1, y-radius >= 1, x+radius < Double(width-1), y+radius < Double(height-1) else { return false }
            var total = 0, valid = 0
            let step = max(1, Int(radius / 3))
            for yy in stride(from: Int(y-radius), through: Int(y+radius), by: step) {
                for xx in stride(from: Int(x-radius), through: Int(x+radius), by: step) {
                    guard hypot(Double(xx)-x,Double(yy)-y) <= radius else { continue }
                    let i = yy * width + xx; total += 1
                    if mask[i*4] > 0.96 && (!clean || (classes[i] == 0 && colors[i].x > 28 && colors[i].x < 86)) { valid += 1 }
                }
            }
            return total > 0 && Double(valid) / Double(total) >= (clean ? 0.98 : 0.93)
        }
        struct Spot { let x: Double; let y: Double; let radius: Double; let kind: BlemishKind; let score: Double }
        var visited = [Bool](repeating: false, count: count)
        var spots: [Spot] = [], queue: [Int] = []
        for start in 0..<count where classes[start] != 0 && !visited[start] {
            let kind = classes[start]
            queue.removeAll(keepingCapacity: true); queue.append(start); visited[start] = true
            var cursor = 0, area = 0, minX = width, maxX = 0, minY = height, maxY = 0
            var sx = 0.0, sy = 0.0, weight = 0.0, peak = 0.0
            while cursor < queue.count {
                let i = queue[cursor]; cursor += 1
                let x = i % width, y = i / width, signal = signals[i]
                area += 1; minX = min(minX,x); maxX = max(maxX,x); minY = min(minY,y); maxY = max(maxY,y)
                sx += Double(x) * signal; sy += Double(y) * signal; weight += signal; peak = max(peak,signal)
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let xx = x+dx, yy = y+dy
                    guard xx >= 0, yy >= 0, xx < width, yy < height else { continue }
                    let next = yy*width+xx
                    if !visited[next] && classes[next] == kind { visited[next] = true; queue.append(next) }
                } }
            }
            let bw = maxX-minX+1, bh = maxY-minY+1
            let aspect = Double(bw) / Double(bh), compact = Double(area) / Double(bw*bh)
            guard area >= 3, area <= max(20,Int(Double(count)*0.001)),
                  max(bw,bh) <= max(10,Int(Double(min(width,height))*0.06)),
                  aspect > 0.38, aspect < 2.6, compact > 0.24, weight > 0 else { continue }
            let x = sx/weight, y = sy/weight
            let radius = max(2.4, sqrt(Double(area) / .pi) * 1.6)
            guard insideDisk(x,y,radius,clean: false) else { continue }
            // Hair strands and creases may fragment into round components after
            // masking. Their surrounding gradient remains strongly directional.
            let patch = max(3,Int(radius*1.4))
            var xxEnergy = 0.0, yyEnergy = 0.0, xyEnergy = 0.0
            for yy in max(1,Int(y)-patch)...min(height-2,Int(y)+patch) {
                for xx in max(1,Int(x)-patch)...min(width-2,Int(x)+patch) {
                    let i = yy*width+xx
                    let gx = colors[i+1].x-colors[i-1].x, gy = colors[i+width].x-colors[i-width].x
                    xxEnergy += gx*gx; yyEnergy += gy*gy; xyEnergy += gx*gy
                }
            }
            let energy = xxEnergy+yyEnergy
            let directional = hypot(xxEnergy-yyEnergy,2*xyEnergy)/max(0.001,energy)
            guard energy < 1 || directional < 0.72 else { continue }
            let score = min(0.99, 0.4 + 0.2 * min(2,peak-1) + 0.2 * compact)
            guard score >= max(0.62,0.82-0.28*sensitivity) else { continue }
            let type: BlemishKind = kind == 1 ? .redSpot : kind == 3 ? .yellowSpot : .darkSpot
            spots.append(Spot(x:x,y:y,radius:radius,kind:type,score:score))
        }
        spots.sort { $0.score > $1.score }
        var result: [BlemishCandidate] = []
        for spot in spots {
            guard !result.contains(where: {
                hypot($0.target.x*image.extent.width+image.extent.minX-(rect.minX+(spot.x+0.5)/scale),
                      $0.target.y*image.extent.height+image.extent.minY-(sampleTop-(spot.y+0.5)/scale)) < ($0.radius*max(image.extent.width,image.extent.height)+spot.radius/scale)
            }) else { continue }
            let center = low[min(count-1,max(0,Int(spot.y)*width+Int(spot.x)))]
            var best: (Double, Double, Double)?
            for distance in [2.8,4.2,6.0] {
                for angle in 0..<24 {
                    let theta = Double(angle) * .pi / 12
                    let x = spot.x+cos(theta)*spot.radius*distance, y = spot.y+sin(theta)*spot.radius*distance
                    guard insideDisk(x,y,spot.radius,clean: true),
                          !spots.contains(where: { hypot(x-$0.x,y-$0.y) < spot.radius+$0.radius }) else { continue }
                    let i = Int(y)*width+Int(x), c = low[i]
                    let dl = abs(c.x-center.x), dc = hypot(c.y-center.y,c.z-center.z)
                    guard dl < 10, dc < 7 else { continue }
                    let cost = dl*0.6+dc+abs(colors[i].x-c.x)*0.5+distance*0.04
                    if best == nil || cost < best!.2 { best = (x,y,cost) }
                }
            }
            // CIContext bitmap rows start at the top. RepairSpot uses CI's
            // bottom-left coordinates, including for nonzero cropped origins.
            let target = MaskPoint(x:(rect.minX+(spot.x+0.5)/scale-image.extent.minX)/image.extent.width,
                                   y:(sampleTop-(spot.y+0.5)/scale-image.extent.minY)/image.extent.height)
            let radius = spot.radius / scale / max(image.extent.width,image.extent.height)
            var repair: RepairSpot?
            if let best {
                let source = MaskPoint(x:(rect.minX+(best.0+0.5)/scale-image.extent.minX)/image.extent.width,
                                       y:(sampleTop-(best.1+0.5)/scale-image.extent.minY)/image.extent.height)
                let proposal = RepairSpot(source:source,target:target,radius:radius,
                    mode:spot.kind == .yellowSpot ? .sampledSkin : .texture)
                if proposal.isValid(in:image.extent.size) { repair = proposal }
            }
            result.append(BlemishCandidate(faceIndex:faceIndex,kind:spot.kind,score:spot.score,
                                           target:target,radius:radius,repair:repair))
            if result.count >= 40 { break }
        }
        return result
    }
}
