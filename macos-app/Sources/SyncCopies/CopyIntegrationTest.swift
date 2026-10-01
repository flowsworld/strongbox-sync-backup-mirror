import AppKit
import Darwin
import Foundation
import SyncCopiesCore

@objc(SyncCopiesIntegrationMetadataFixture)
private final class CopyMetadataFixture: NSObject, NSCoding {
    let id = UUID()
    let filename: String
    init(_ filename: String) { self.filename = filename }
    required init?(coder: NSCoder) { return nil }
    func encode(with coder: NSCoder) {
        coder.encode(10, forKey: "storageProvider")
        coder.encode(id.uuidString as NSString, forKey: "uuid")
        coder.encode("Fixture" as NSString, forKey: "nickName")
        let name = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        coder.encode(URL(string: "strongbox-cloud:/\(name)?uuid=\(id.uuidString)")! as NSURL, forKey: "fileUrl")
    }
}

/// Opt-in diagnostic mode. Destinations are private fixtures or an explicitly granted, prepared temporary test folder.
@MainActor
enum CopyIntegrationTest {
    private struct Check: Codable {
        let name: String
        let status: String
        let code: String?
    }
    private struct Report: Codable {
        let mode: String
        let timestamp: String
        let databaseCount: Int
        let passed: Int
        let failed: Int
        let checks: [Check]
        let limitations: [String]
    }
    private enum Failure: Error { case assertion, cancelled, unavailableHome, invalidTarget, targetMismatch }

    static func run(fixturesOnly: Bool, targetURL: URL? = nil) -> Int32 {
        let manager = FileManager.default
        let support = manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SyncCopies/copy-test", isDirectory: true)
        var checks: [Check] = []
        var databaseCount = 0
        func check(_ name: String, _ body: () throws -> Void) {
            do {
                try body()
                checks.append(Check(name: name, status: "pass", code: nil))
            } catch {
                checks.append(Check(name: name, status: "fail", code: errorCode(error)))
            }
        }
        do {
            try makeDirectory(support)
            let source: URL
            let scope: ScopedFolder?
            let targetScope: ScopedFolder?
            let destinationRoot: URL
            if fixturesOnly {
                let run = support.appendingPathComponent("runs/\(UUID().uuidString)", isDirectory: true)
                try makeDirectory(run)
                destinationRoot = run.resolvingSymlinksInPath()
                source = destinationRoot.appendingPathComponent("fixture-source", isDirectory: true)
                try makeFixtures(source, names: ["first.kdbx", "second.kdbx"])
                scope = nil
                targetScope = nil
            } else {
                let bookmarkURL = support.appendingPathComponent("copy-test-source.bookmark")
                let bookmark: Data
                if manager.fileExists(atPath: bookmarkURL.path) {
                    bookmark = try Data(contentsOf: bookmarkURL)
                } else {
                    guard let user = getpwuid(getuid()), let home = user.pointee.pw_dir else { throw Failure.unavailableHome }
                    let initial = URL(fileURLWithPath: String(cString: home), isDirectory: true)
                        .appendingPathComponent("Library/Group Containers/group.strongbox.mac.mcguill", isDirectory: true)
                    guard let selected = try FolderPicker.choose(
                        title: "Strongbox-Backups lesend testen / Test read-only access",
                        message: "Nur Metadaten und verschlüsselte Backups lesen. Testkopien bleiben im vorbereiteten privaten Testordner außerhalb von Cloud-Ordnern. / Read metadata and encrypted backups only. Test copies stay in the prepared private test folder outside cloud folders.",
                        initialURL: initial, readOnly: true
                    ) else { throw Failure.cancelled }
                    bookmark = selected
                    try bookmark.write(to: bookmarkURL, options: .atomic)
                    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bookmarkURL.path)
                }
                scope = try ScopedFolder(bookmark: bookmark)
                source = scope!.url
                guard let targetURL, targetURL.isFileURL else { throw Failure.invalidTarget }
                // Foundation standardization abbreviates /private/tmp to the
                // /tmp symlink. Keep the explicit physical path for Core traversal.
                let expected = targetURL
                let prefix = "strongbox-mirror-copy-test-"
                guard expected.deletingLastPathComponent().path == "/private/tmp",
                      expected.lastPathComponent.hasPrefix(prefix),
                      UUID(uuidString: String(expected.lastPathComponent.dropFirst(prefix.count))) != nil,
                      try physicalPath(expected) == expected.path else { throw Failure.invalidTarget }
                let targetBookmarkURL = support.appendingPathComponent("copy-test-target.bookmark")
                var retained: ScopedFolder?
                if manager.fileExists(atPath: targetBookmarkURL.path) {
                    do {
                        retained = try ScopedFolder(bookmark: Data(contentsOf: targetBookmarkURL))
                        if try retained.map({ try physicalPath($0.url) }) != expected.path { retained = nil }
                    } catch {
                        // A previous disposable target can disappear. Record that its
                        // grant was retired, then request only this exact prepared target.
                        checks.append(Check(name: "previous_test_target_grant", status: "skip", code: errorCode(error)))
                        retained = nil
                    }
                }
                if retained == nil {
                    guard let bookmark = try FolderPicker.choose(
                        title: "Separaten Testordner freigeben / Allow isolated test folder",
                        message: "Nur den vorbereiteten Testordner auswählen. Bestehende Zielordner sind ausgeschlossen. / Choose only the prepared test folder. Existing destinations are excluded.",
                        initialURL: expected, readOnly: false
                    ) else { throw Failure.cancelled }
                    let selected = try ScopedFolder(bookmark: bookmark)
                    guard try physicalPath(selected.url) == expected.path else { throw Failure.targetMismatch }
                    try bookmark.write(to: targetBookmarkURL, options: .atomic)
                    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetBookmarkURL.path)
                    retained = selected
                }
                guard let retained else { throw Failure.invalidTarget }
                let permissions = try manager.attributesOfItem(atPath: retained.url.path)[.posixPermissions] as? NSNumber
                guard permissions?.intValue == 0o700 else { throw Failure.invalidTarget }
                targetScope = retained
                destinationRoot = expected.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try makeDirectory(destinationRoot)
            }
            defer { withExtendedLifetime(scope) {}; withExtendedLifetime(targetScope) {} }
            let root = destinationRoot
            let common = root.appendingPathComponent("common", isDirectory: true)
            let overrides = root.appendingPathComponent("overrides", isDirectory: true)
            try makeDirectory(common)
            try makeDirectory(overrides)
            let databases = try StrongboxCatalog.read(groupContainer: source)
            databaseCount = databases.count
            try require(!databases.isEmpty)
            checks.append(Check(name: "catalog_read", status: "pass", code: nil))
            if databases.count > 1 {
                checks.append(Check(name: "multiple_databases_available", status: "pass", code: nil))
            } else {
                checks.append(Check(name: "multiple_databases_available", status: "skip", code: "single_database"))
            }
            let destinations = databases.map { CopyDestination(databaseID: $0.id, directory: common, filename: $0.filename) }
            let conflicts = try DestinationPlanner.conflictingDatabaseIDs(destinations, sourceRoot: source)
            try require(conflicts.isEmpty)
            checks.append(Check(name: "common_destination_preflight", status: "pass", code: nil))
            for (index, database) in databases.enumerated() {
                let prefix = "database_\(index + 1)"
                var backup: BackupInfo?
                check("\(prefix)_newest_backup") {
                    backup = try StrongboxBackups.newest(for: database, groupContainer: source)
                }
                guard let backup else { continue }
                let copy = common.appendingPathComponent(database.filename)
                check("\(prefix)_initial_copy") {
                    try require(try MirrorEngine.copy(backup: backup, to: common, filename: database.filename) == .copied)
                    try assertMatchesStableSource(backup, copy: copy)
                    try require(try identity(copy).mode & 0o777 == 0o600)
                }
                check("\(prefix)_unchanged_keeps_inode") {
                    let before = try identity(copy)
                    try require(try MirrorEngine.copy(backup: backup, to: common, filename: database.filename) == .unchanged)
                    try require(try identity(copy) == before)
                }
                check("\(prefix)_separate_override") {
                    let target = overrides.appendingPathComponent("database-\(index + 1)", isDirectory: true)
                    try makeDirectory(target)
                    let plan = databases.map { item in
                        CopyDestination(databaseID: item.id, directory: item.id == database.id ? target : common, filename: item.filename)
                    }
                    try require(try DestinationPlanner.conflictingDatabaseIDs(plan, sourceRoot: source).isEmpty)
                    try require(try MirrorEngine.copy(backup: backup, to: target, filename: database.filename) == .copied)
                    try assertMatchesStableSource(backup, copy: target.appendingPathComponent(database.filename))
                    try assertMatchesStableSource(backup, copy: copy)
                }
                check("\(prefix)_changed_test_copy_restored") {
                    // This is the fresh private test copy, never a user's configured destination.
                    try Data("deliberately changed TEST copy".utf8).write(to: copy)
                    try require(try MirrorEngine.copy(backup: backup, to: common, filename: database.filename) == .copied)
                    try assertMatchesStableSource(backup, copy: copy)
                }
                if fixturesOnly {
                    check("\(prefix)_newer_backup_replaces_copy") {
                        let newer = backup.url.deletingLastPathComponent().appendingPathComponent("newer.bak")
                        usleep(20_000)
                        try Data("synthetic encrypted fixture, newer revision".utf8).write(to: newer)
                        let selected = try StrongboxBackups.newest(for: database, groupContainer: source)
                        try require(selected.url == newer)
                        try require(try MirrorEngine.copy(backup: selected, to: common, filename: database.filename) == .copied)
                        try assertMatchesStableSource(selected, copy: copy)
                    }
                    check("\(prefix)_empty_newest_preserves_copy") {
                        let before = try Data(contentsOf: copy)
                        usleep(20_000)
                        let empty = backup.url.deletingLastPathComponent().appendingPathComponent("empty.bak")
                        try Data().write(to: empty)
                        do {
                            _ = try StrongboxBackups.newest(for: database, groupContainer: source)
                            throw Failure.assertion
                        } catch MirrorError.emptyBackup { }
                        try require(try Data(contentsOf: copy) == before)
                    }
                }
            }
            if fixturesOnly {
                for (name, names) in [("same_filename", ["same.kdbx", "same.kdbx"]), ("unicode_filename", ["Straße.kdbx", "STRASSE.kdbx"])] {
                    check("\(name)_collision_blocks_before_write") {
                        let fixture = root.appendingPathComponent(name, isDirectory: true)
                        try makeFixtures(fixture, names: names)
                        let target = root.appendingPathComponent("\(name)-target", isDirectory: true)
                        try makeDirectory(target)
                        let entries = try StrongboxCatalog.read(groupContainer: fixture)
                        try require(entries.count == names.count)
                        let plan = entries.map { CopyDestination(databaseID: $0.id, directory: target, filename: $0.filename) }
                        let blocked = try DestinationPlanner.conflictingDatabaseIDs(plan, sourceRoot: fixture)
                        try require(blocked == Set(entries.map(\.id)))
                        try require(try manager.contentsOfDirectory(atPath: target.path).isEmpty)
                    }
                }
            }
        } catch {
            checks.append(Check(name: "run_setup_or_preflight", status: "fail", code: errorCode(error)))
        }
        var report = Report(mode: fixturesOnly ? "fixtures" : "real_read_only", timestamp: ISO8601DateFormatter().string(from: Date()), databaseCount: databaseCount,
                            passed: checks.filter { $0.status == "pass" }.count,
                            failed: checks.filter { $0.status == "fail" }.count,
                            checks: checks,
                            limitations: ["manual_diagnostic_not_background_app", fixturesOnly ? "private_sandbox_destinations_only" : "explicit_private_temporary_destination_only", "no_cloud_upload_or_verification", "no_login_wake_or_notifications_test", fixturesOnly ? "synthetic_files_not_real_encrypted_databases" : "source_changes_never_simulated"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(report)
            let file = support.appendingPathComponent("latest-result.json")
            try data.write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            checks.append(Check(name: "report_write", status: "fail", code: "report_write_failed"))
            report = Report(mode: report.mode, timestamp: report.timestamp, databaseCount: databaseCount, passed: report.passed,
                            failed: report.failed + 1, checks: checks, limitations: report.limitations)
        }
        if let data = try? encoder.encode(report) { print(String(decoding: data, as: UTF8.self)) }
        return report.failed == 0 ? 0 : 1
    }

    private static func physicalPath(_ url: URL) throws -> String {
        guard let path = realpath(url.path, nil) else { throw Failure.invalidTarget }
        defer { free(path) }
        return String(cString: path)
    }

    private static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private static func require(_ condition: Bool) throws {
        guard condition else { throw Failure.assertion }
    }
    private struct Identity: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let mode: UInt16
        let birthSeconds: Int
        let birthNanos: Int
        let modificationSeconds: Int
        let modificationNanos: Int
        let changeSeconds: Int
        let changeNanos: Int
    }
    private static func identity(_ url: URL) throws -> Identity {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw MirrorError.unsafeFile }
        defer { Darwin.close(descriptor) }
        var stamp = stat()
        guard fstat(descriptor, &stamp) == 0, stamp.st_mode & S_IFMT == S_IFREG else { throw MirrorError.unsafeFile }
        return Identity(device: stamp.st_dev, inode: stamp.st_ino, size: stamp.st_size, mode: stamp.st_mode,
                        birthSeconds: stamp.st_birthtimespec.tv_sec, birthNanos: stamp.st_birthtimespec.tv_nsec,
                        modificationSeconds: stamp.st_mtimespec.tv_sec, modificationNanos: stamp.st_mtimespec.tv_nsec,
                        changeSeconds: stamp.st_ctimespec.tv_sec, changeNanos: stamp.st_ctimespec.tv_nsec)
    }
    private static func assertMatchesStableSource(_ backup: BackupInfo, copy: URL) throws {
        let before = try identity(backup.url)
        let source = try Data(contentsOf: backup.url)
        let copied = try Data(contentsOf: copy)
        let after = try identity(backup.url)
        try require(before == after && before.size == backup.size && source == copied)
        try require(Date(timeIntervalSince1970: Double(before.birthSeconds) + Double(before.birthNanos) / 1_000_000_000) == backup.creationDate)
    }
    private static func makeFixtures(_ root: URL, names: [String]) throws {
        try makeDirectory(root)
        let entries = names.map(CopyMetadataFixture.init)
        let archive = NSKeyedArchiver(requiringSecureCoding: false)
        archive.setClassName("DatabaseMetadata", for: CopyMetadataFixture.self)
        archive.encode(entries as NSArray, forKey: NSKeyedArchiveRootObjectKey)
        archive.finishEncoding()
        let preferences = root.appendingPathComponent("Library/Preferences", isDirectory: true)
        try makeDirectory(preferences)
        try PropertyListSerialization.data(fromPropertyList: ["databases": archive.encodedData], format: .binary, options: 0)
            .write(to: preferences.appendingPathComponent("group.strongbox.mac.mcguill.plist"))
        for item in entries {
            let folder = root.appendingPathComponent("backups/\(item.id.uuidString)", isDirectory: true)
            try makeDirectory(folder)
            try Data("synthetic encrypted fixture".utf8).write(to: folder.appendingPathComponent("initial.bak"))
        }
    }
    private static func errorCode(_ error: any Error) -> String {
        switch error {
        case Failure.assertion: return "assertion_failed"
        case Failure.cancelled: return "source_grant_cancelled"
        case Failure.unavailableHome: return "home_unavailable"
        case Failure.invalidTarget: return "invalid_isolated_target"
        case Failure.targetMismatch: return "target_selection_mismatch"
        case FolderPermissionError.staleBookmark: return "source_bookmark_stale"
        case FolderPermissionError.accessDenied: return "source_access_denied"
        case FolderPermissionError.notDirectory: return "source_not_directory"
        case MirrorError.emptyBackup: return "empty_backup"
        case MirrorError.missingBackup: return "missing_backup"
        case MirrorError.changedFile: return "source_or_destination_changed"
        case is MirrorError: return "mirror_error"
        default: return "operation_failed"
        }
    }
}
