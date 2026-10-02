// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Store and ordinary development graphs do not resolve or link the updater.
let directUpdates = ProcessInfo.processInfo.environment["DIESIS_DISTRIBUTION"] == "direct"
let updaterPackages: [Package.Dependency] = directUpdates
    ? [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")] : []
let updaterTargets: [Target.Dependency] = directUpdates
    ? [.product(name: "Sparkle", package: "Sparkle")] : []

let package = Package(
    name: "SyncCopies",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SyncCopies", targets: ["SyncCopies"])],
    dependencies: updaterPackages,
    targets: [
        .target(name: "SyncCopiesCore", resources: [.process("Resources")]),
        .executableTarget(name: "SyncCopies", dependencies: [.target(name: "SyncCopiesCore")] + updaterTargets,
                          swiftSettings: directUpdates ? [.define("DIESIS_DIRECT_UPDATES")] : [],
                          linkerSettings: directUpdates ? [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])] : []),
        .testTarget(name: "SyncCopiesCoreTests", dependencies: ["SyncCopiesCore"]),
        .testTarget(name: "SyncCopiesAppTests", dependencies: ["SyncCopies", "SyncCopiesCore"]),
    ]
)
