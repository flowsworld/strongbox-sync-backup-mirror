// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SyncCopies",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SyncCopies", targets: ["SyncCopies"])],
    targets: [
        .target(name: "SyncCopiesCore", resources: [.process("Resources")]),
        .executableTarget(name: "SyncCopies", dependencies: ["SyncCopiesCore"]),
        .testTarget(name: "SyncCopiesCoreTests", dependencies: ["SyncCopiesCore"]),
        .testTarget(name: "SyncCopiesAppTests", dependencies: ["SyncCopies", "SyncCopiesCore"]),
    ]
)
