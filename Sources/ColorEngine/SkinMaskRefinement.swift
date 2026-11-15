import CoreImage

/// Recover visible skin that the face parser assigned to hair in a shaded
/// jaw/neck. Growth starts from parsed skin and cannot cross excluded features,
/// clothing, or pixels unlike this person's measured skin colour.
enum SkinMaskRefinement {
    static func refine(_ face: SemanticFace, image: CIImage, clothing: CIImage, hands: CIImage? = nil,
                       context: CIContext) throws -> SemanticFace {
        let extent = image.extent, box = face.info.bounds
        guard let skin = face.regions[.skin], let neck = face.regions[.neck],
              let hair = face.regions[.hair],
              let profile = try? SkinColorMath.profile(image, mask: skin, box: box, context: context) else { return face }
        let rect = CGRect(x: box.minX-box.width*0.30, y: box.minY-box.height*0.85,
            width: box.width*1.60, height: box.height*1.95).integral.intersection(extent)
        let scale = min(1, 768/max(rect.width,rect.height))
        let transform = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let bounds = CGRect(x: 0,y: 0,width: rect.width*scale,height: rect.height*scale).integral
        let w = Int(bounds.width), h = Int(bounds.height)
        func pixels(_ mask: CIImage) -> [Float] {
            var values = [Float](repeating: 0,count: w*h*4)
            values.withUnsafeMutableBytes {
                context.render(mask.cropped(to:rect).transformed(by:transform), toBitmap:$0.baseAddress!,
                    rowBytes:w*16,bounds:bounds,format:.RGBAf,colorSpace:SkinColorMath.linearP3)
            }
            return values
        }
        let black = CIImage(color:.black).cropped(to:extent)
        let handSkin = try SkinProcessing.bodyCandidate(image,profile:profile,tolerance:2.2)
            .applyingFilter("CIMultiplyCompositing",parameters:[kCIInputBackgroundImageKey:hands ?? black])
        var blocked = clothing.applyingFilter("CIMaximumCompositing",parameters:[kCIInputBackgroundImageKey:handSkin])
        for kind in [MaskKind.eyes,.eyebrows,.lips,.teeth] {
            if let mask = face.regions[kind] {
                blocked = blocked.applyingFilter("CIMaximumCompositing",parameters:[kCIInputBackgroundImageKey:mask])
            }
        }
        blocked = blocked.applyingFilter("CIMorphologyMaximum",parameters:[kCIInputRadiusKey:max(1,box.width*0.008)])
        let colours = pixels(try SkinProcessing.bodyCandidate(image,profile:profile,tolerance:1.5))
        let excluded = pixels(blocked), seeds = pixels(skin)
        var visited = [Bool](repeating:false,count:w*h), queue:[Int] = []
        for i in 0..<w*h where seeds[i*4] > 0.85 && colours[i*4] > 0.55 && excluded[i*4] < 0.1 {
            queue.append(i); visited[i] = true
        }
        var cursor = 0
        while cursor < queue.count {
            if cursor.isMultiple(of:4096) { try Task.checkCancellation() }
            let i = queue[cursor]; cursor += 1
            let x = i%w, y = i/w
            for (dx,dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                let xx = x+dx, yy = y+dy
                guard xx >= 0,xx < w,yy >= 0,yy < h else { continue }
                let j = yy*w+xx
                if !visited[j] && colours[j*4] > 0.55 && excluded[j*4] < 0.1 {
                    visited[j] = true; queue.append(j)
                }
            }
        }
        let bytes = visited.map { $0 ? UInt8(255) : 0 }
        // Limit recovery to the vicinity of the semantic seed with a soft fade.
        // A hard crop through a hand/chest would otherwise become a bright box.
        let reach = skin.applyingGaussianBlur(sigma:max(1,box.width*0.09))
            .applyingFilter("CIColorMatrix",parameters:[
                "inputRVector":CIVector(x:3,y:0,z:0,w:0),
                "inputGVector":CIVector(x:0,y:3,z:0,w:0),
                "inputBVector":CIVector(x:0,y:0,z:3,w:0)])
            .applyingFilter("CIColorClamp")
        let recovered = try MaskBounds.pad(CIImage(bitmapData:Data(bytes),bytesPerRow:w,
            size:CGSize(width:w,height:h),format:.L8,colorSpace:nil)
            .transformed(by:transform.inverted()),to:extent)
            .applyingGaussianBlur(sigma:max(0.6,box.width*0.002))
            .applyingFilter("CIMultiplyCompositing",parameters:[kCIInputBackgroundImageKey:reach]).cropped(to:extent)
        var regions = face.regions
        regions[.skin] = skin.applyingFilter("CIMaximumCompositing",parameters:[kCIInputBackgroundImageKey:recovered])
        // Neck membership fades across the lower jaw; it must not introduce a
        // horizontal boundary when coordinated independently of the face.
        let lower = try MaskBounds.pad(CIImage(color:.white).cropped(to:CGRect(x:extent.minX,y:extent.minY,
            width:extent.width,height:max(1,box.minY+box.height*0.02-extent.minY))),to:extent)
            .applyingGaussianBlur(sigma:max(1,box.height*0.03)).cropped(to:extent)
        let recoveredNeck = recovered.applyingFilter("CIMultiplyCompositing",parameters:[kCIInputBackgroundImageKey:lower])
        regions[.neck] = neck.applyingFilter("CIMaximumCompositing",parameters:[kCIInputBackgroundImageKey:recoveredNeck])
        regions[.hair] = hair.applyingFilter("CIMultiplyCompositing",parameters:[
            kCIInputBackgroundImageKey:recovered.applyingFilter("CIColorInvert")])
        for kind in [MaskKind.skin,.neck,.hair] {
            regions[kind] = regions[kind]?.applyingFilter("CIMultiplyCompositing",parameters:[
                kCIInputBackgroundImageKey:handSkin.applyingFilter("CIColorInvert")])
        }
        return SemanticFace(info:face.info,regions:regions)
    }
}
