// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "SemanticMeshCore", platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "SemanticMeshCore", targets: ["SemanticMeshCore"])],
    targets: [.target(name: "SemanticMeshCore", path: "Core"),
              .testTarget(name: "SemanticMeshCoreTests", dependencies: ["SemanticMeshCore"], path: "Tests")])
