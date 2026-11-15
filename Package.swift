// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Ps",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Ps", targets: ["Ps"]),
        .executable(name: "PhotoCatalog", targets: ["PhotoCatalog"]),
        .executable(name: "PortraitRetouch", targets: ["PortraitRetouch"]),
        .executable(name: "ReferenceMatch", targets: ["ReferenceMatch"]),
        .executable(name: "ReferenceMasks", targets: ["ReferenceMasks"])
    ],
    targets: [
        .target(name: "ColorEngine", resources: [.copy("Models"), .copy("Styles")]),
        .executableTarget(name: "PhotoCatalog"),
        .executableTarget(name: "Ps", dependencies: ["ColorEngine"]),
        .executableTarget(name: "PortraitRetouch", dependencies: ["ColorEngine"]),
        .executableTarget(name: "ReferenceMatch", dependencies: ["ColorEngine"]),
        .executableTarget(name: "ReferenceMasks", dependencies: ["ColorEngine"]),
        .testTarget(name: "ColorEngineTests", dependencies: ["ColorEngine"]),
        .testTarget(name: "ReferenceMatchTests", dependencies: ["ReferenceMatch"]),
        .testTarget(name: "StudioTests", dependencies: ["Ps", "ColorEngine"])
    ]
)
