import CoreImage
import Foundation
import Vision

struct Face: Codable { let x:Double;let y:Double;let width:Double;let height:Double;let confidence:Float }
struct Record: Codable { let file:String;let faces:[Face] }
let args=Array(CommandLine.arguments.dropFirst())
guard args.count==2 else { fatalError("reference-face-bounds <input-list.json> <output.json>") }
let paths=try JSONDecoder().decode([String].self,from:Data(contentsOf:URL(fileURLWithPath:args[0])))
let context=CIContext(options:[.cacheIntermediates:false])
let space=CGColorSpace(name:CGColorSpace.sRGB)!
var records:[Record]=[]
for (index,path) in paths.enumerated() {
    try autoreleasepool {
        guard let source=CIImage(contentsOf:URL(fileURLWithPath:path),options:[.applyOrientationProperty:true]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let scale=min(1,1600/max(source.extent.width,source.extent.height))
        let reduced=source.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        guard let image=context.createCGImage(reduced,from:reduced.extent,format:.RGBA8,colorSpace:space) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let request=VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage:image).perform([request])
        let faces=(request.results ?? []).filter {$0.confidence>=0.6}.map { face in
            let b=face.boundingBox
            return Face(x:b.minX,y:1-b.maxY,width:b.width,height:b.height,confidence:face.confidence)
        }
        records.append(Record(file:path,faces:faces))
    }
    if (index+1)%100==0 { print("人脸定位 \(index+1)/\(paths.count)");fflush(stdout) }
}
let encoder=JSONEncoder()
try encoder.encode(records).write(to:URL(fileURLWithPath:args[1]),options:.atomic)
print("完成人脸定位 \(records.count)")
