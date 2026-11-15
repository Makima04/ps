import CoreImage

/// Separate connected limb candidates so sunlit and shaded hands are not averaged together.
enum BodySkinComponents {
    struct Region {
        let mask: CIImage
        let bounds: CGRect
    }
    static func regions(_ mask: CIImage, context: CIContext) throws -> [Region] {
        let extent = mask.extent
        let scale = min(1, 768 / max(extent.width, extent.height))
        let transform = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let small = mask.transformed(by: transform)
        let bounds = small.extent.integral
        let w = Int(bounds.width), h = Int(bounds.height)
        var values = [Float](repeating: 0, count: w*h*4)
        values.withUnsafeMutableBytes {
            context.render(small, toBitmap: $0.baseAddress!, rowBytes: w*16, bounds: bounds,
                           format: .RGBAf, colorSpace: SkinColorMath.linearP3)
        }
        var visited = [Bool](repeating: false, count: w*h)
        var regions: [Region] = []
        for seed in 0..<w*h where !visited[seed] && values[seed*4] > 0.04 {
            try Task.checkCancellation()
            var queue = [seed], next = 0, core = 0
            visited[seed] = true
            var minX = w, maxX = 0, minY = h, maxY = 0
            while next < queue.count {
                let i = queue[next]; next += 1
                let x = i % w, y = i / w
                minX = min(minX,x); maxX = max(maxX,x); minY = min(minY,y); maxY = max(maxY,y)
                if values[i*4] > 0.85 { core += 1 }
                for (dx,dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                    let xx = x+dx, yy = y+dy
                    guard xx >= 0, xx < w, yy >= 0, yy < h else { continue }
                    let j = yy*w+xx
                    if !visited[j] && values[j*4] > 0.04 { visited[j] = true; queue.append(j) }
                }
            }
            // Tiny fragments and large garment-like components are never coordinated automatically.
            guard queue.count >= 32, queue.count < w*h/12, core >= max(12,queue.count/10) else { continue }
            let rw = maxX-minX+1, rh = maxY-minY+1
            var pixels = [UInt8](repeating: 0, count: rw*rh)
            for index in queue { pixels[(index/w-minY)*rw + index%w-minX] = 255 }
            // Rendered bitmap rows run top to bottom; CI placement uses bottom-left.
            let bottomY = h - 1 - maxY
            let binary = CIImage(bitmapData: Data(pixels), bytesPerRow: rw,
                                 size: CGSize(width: rw, height: rh), format: .L8, colorSpace: nil)
                .transformed(by: CGAffineTransform(translationX: Double(minX), y: Double(bottomY)))
                .transformed(by: transform.inverted())
            // Keep the original soft skirt. A binary cut at 0.55 creates visible
            // tone steps through a continuous arm even when the input is smooth.
            let padded = try MaskBounds.pad(binary, to: extent)
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 1/scale])
                .applyingGaussianBlur(sigma: 0.6/scale).cropped(to: extent)
            let selected = mask.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: padded])
            let rect = CGRect(x: extent.minX + Double(minX)/scale, y: extent.minY + Double(bottomY)/scale,
                              width: Double(rw)/scale, height: Double(rh)/scale).insetBy(dx: -2/scale, dy: -2/scale).intersection(extent)
            regions.append(Region(mask: selected, bounds: rect))
        }
        return Array(regions.sorted { $0.bounds.minX < $1.bounds.minX }.prefix(12))
    }
}
