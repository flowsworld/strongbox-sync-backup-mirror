import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let defaults = UserDefaults.standard

func errorCode(_ error: Error) -> String {
    if let error = error as? ProbeError { return error.rawValue }
    let error = error as NSError
    return "\(error.domain):\(error.code)"
}

func output(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

// Reports contain counts and error codes, not real database names, UUIDs, paths or bytes.
func report(_ result: [String: Any]) throws {
    let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: directory.appendingPathComponent("probe-result.json"), options: .atomic)
    try output(result)
}

func inspect(_ root: URL) throws -> [String: Any] {
    let rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
    guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw ProbeError.unsafeBackup }
    let preferences = root.appendingPathComponent("Library/Preferences/group.strongbox.mac.mcguill.plist")
    let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
    guard try backupRoot.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
        throw ProbeError.unsafeBackup
    }
    let databases = try catalog(preferences)
    var readable = 0
    var failures: [String: Int] = [:]
    for database in databases {
        do {
            _ = try sampleNewestBackup(backupRoot, database: database)
            readable += 1
        } catch {
            failures[errorCode(error), default: 0] += 1
        }
    }
    return ["databaseCount": databases.count, "readableBackupCount": readable,
            "backupFailures": failures, "allBackupsReadable": !databases.isEmpty && failures.isEmpty]
}

func bookmarkRoot() throws -> URL {
    guard let bookmark = UserDefaults.standard.data(forKey: "sourceBookmark") else { throw ProbeError.missingBookmark }
    var stale = false
    let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
    guard !stale else { throw ProbeError.staleBookmark }
    guard url.startAccessingSecurityScopedResource() else { throw ProbeError.inactiveBookmark }
    return url
}

do {
    guard let mode = arguments.first else { throw ProbeError.invalidMetadata }
    switch mode {
    case "--catalog":
        // Fixture runner only. This unsigned CLI mode does not prove sandbox access.
        guard arguments.count == 2 else { throw ProbeError.invalidMetadata }
        let value = try catalog(URL(fileURLWithPath: arguments[1]))
        let data = try JSONEncoder().encode(value)
        print(String(decoding: data, as: UTF8.self))
    case "--inspect-fixture":
        guard arguments.count == 2 else { throw ProbeError.invalidMetadata }
        try output(inspect(URL(fileURLWithPath: arguments[1], isDirectory: true)))
    case "--direct":
        guard arguments.count == 2 else { throw ProbeError.invalidMetadata }
        var result = try inspect(URL(fileURLWithPath: arguments[1], isDirectory: true))
        result["mode"] = mode
        result["timestamp"] = ISO8601DateFormatter().string(from: Date())
        try report(result)
    case "--denied":
        guard arguments.count == 2 else { throw ProbeError.invalidMetadata }
        var denied = false
        do { _ = try Data(contentsOf: URL(fileURLWithPath: arguments[1])) }
        catch { denied = true }
        try output(["mode": mode, "outsideFileDenied": denied])
        exit(denied ? 0 : 1)
    case "--grant":
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.title = "Strongbox: technischer Lesetest"
        panel.message = "Den Strongbox-Ordner freigeben. Der Test liest Metadaten und verschlüsselte Backups. Er verändert und kopiert keine Datenbanken."
        panel.prompt = "Lesezugriff testen"
        if arguments.count == 2 { panel.directoryURL = URL(fileURLWithPath: arguments[1], isDirectory: true) }
        guard panel.runModal() == .OK, let root = panel.url else { throw ProbeError.selectionCancelled }
        defer { root.stopAccessingSecurityScopedResource() }
        let bookmark = try root.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: "sourceBookmark")
        var result = try inspect(root)
        result["mode"] = mode
        result["bookmarkSaved"] = true
        result["timestamp"] = ISO8601DateFormatter().string(from: Date())
        try report(result)
    case "--resume", "--background":
        let root = try bookmarkRoot()
        defer { root.stopAccessingSecurityScopedResource() }
        var result = try inspect(root)
        if mode == "--background" {
            // A fresh process with no window, retained bookmark and two delayed reads.
            for _ in 0..<2 {
                RunLoop.current.run(until: Date().addingTimeInterval(5))
                result = try inspect(root)
            }
            result["sampleCount"] = 3
        }
        result["mode"] = mode
        result["timestamp"] = ISO8601DateFormatter().string(from: Date())
        try report(result)
    default:
        throw ProbeError.invalidMetadata
    }
} catch {
    let result: [String: Any] = ["mode": arguments.first ?? "missing", "error": errorCode(error),
                               "timestamp": ISO8601DateFormatter().string(from: Date())]
    do {
        if ["--catalog", "--inspect-fixture", "--denied"].contains(arguments.first ?? "") {
            try output(result)
        } else {
            try report(result)
        }
    }
    catch { fputs("Could not write probe result: \(errorCode(error))\n", stderr) }
    exit(1)
}
