// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SyncCopies",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SyncCopies", targets: ["SyncCopies"])],
    targets: [
        .target(name: "SyncCopiesCore"),
        .executableTarget(name: "SyncCopies", dependencies: ["SyncCopiesCore"]),
        .testTarget(name: "SyncCopiesCoreTests", dependencies: ["SyncCopiesCore"]),
        .testTarget(name: "SyncCopiesAppTests", dependencies: ["SyncCopies", "SyncCopiesCore"]),
    ]
)
