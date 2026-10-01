import Foundation
import Darwin
import AppKit
import Testing
@testable import SyncCopies
import SyncCopiesCore

@objc(SyncCopiesAppMetadataFixture)
private final class AppMetadataFixture: NSObject, NSCoding {
    let database: Database
    init(_ database: Database) { self.database = database }
    required init?(coder: NSCoder) { fatalError("Fixtures are encoded only") }
    func encode(with coder: NSCoder) {
        coder.encode(10, forKey: "storageProvider")
        coder.encode(database.id.uuidString as NSString, forKey: "uuid")
        coder.encode(database.displayName as NSString, forKey: "nickName")
        coder.encode(URL(string: "strongbox-cloud:/\(database.filename)?uuid=\(database.id.uuidString)")! as NSURL, forKey: "fileUrl")
    }
}

private final class ModelFixture: @unchecked Sendable {
    let root: URL
    let source: URL
    let common: URL
    let override: URL
    let preferencesURL: URL
    let first = Database(id: UUID(), filename: "first.kdbx", displayName: "First")
    let second = Database(id: UUID(), filename: "second.kdbx", displayName: "Second")
    init() throws {
        let candidate = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        guard let path = realpath(candidate.path, nil) else { throw CocoaError(.fileReadUnknown) }
        defer { free(path) }
        root = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        source = root.appendingPathComponent("source")
        common = root.appendingPathComponent("common")
        override = root.appendingPathComponent("override")
        preferencesURL = root.appendingPathComponent("settings/preferences.json")
        for folder in [common, override, preferencesURL.deletingLastPathComponent(), source.appendingPathComponent("Library/Preferences")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try catalog([first, second])
        try backup(first, bytes: "first encrypted fixture")
        try backup(second, bytes: "second encrypted fixture")
        var preferences = Preferences()
        preferences.source = Data("source".utf8)
        preferences.defaultTarget = Data("common".utf8)
        preferences.databases[first.id.uuidString] = DatabasePreferences(enabled: true)
        preferences.databases[second.id.uuidString] = DatabasePreferences(enabled: true, target: Data("override".utf8))
        try JSONEncoder().encode(preferences).write(to: preferencesURL)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func catalog(_ databases: [Database]) throws {
        let archive = NSKeyedArchiver(requiringSecureCoding: false)
        archive.setClassName("DatabaseMetadata", for: AppMetadataFixture.self)
        archive.encode(databases.map(AppMetadataFixture.init) as NSArray, forKey: NSKeyedArchiveRootObjectKey)
        archive.finishEncoding()
        let data = try PropertyListSerialization.data(fromPropertyList: ["databases": archive.encodedData], format: .binary, options: 0)
        try data.write(to: source.appendingPathComponent("Library/Preferences/group.strongbox.mac.mcguill.plist"), options: .atomic)
    }
    func backup(_ database: Database, bytes: String, name: String = "backup.bak") throws {
        let folder = source.appendingPathComponent("backups/\(database.id.uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: folder.appendingPathComponent(name))
    }
    @MainActor func environment(interval: TimeInterval = 3600, wakeCenter: NotificationCenter = NotificationCenter(), loginStatus: @escaping () -> (enabled: Bool, needsApproval: Bool) = { (false, false) }, setLogin: @escaping (Bool) throws -> Void = { _ in }) -> AppEnvironment {
        AppEnvironment(preferencesURL: preferencesURL, resolveFolder: { [self] data in
            let url: URL
            switch String(decoding: data, as: UTF8.self) {
            case "source": url = source
            case "common": url = common
            case "override": url = override
            default: throw CocoaError(.fileReadNoPermission)
            }
            guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileReadNoSuchFile) }
            return FolderAccess(url: url)
        }, scheduler: AppScheduler(interval: interval, wakeCenter: wakeCenter), notifications: nil, loginStatus: loginStatus, setLogin: setLogin)
    }
}

private final class SimulatedGrant: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    var isRevoked: Bool { lock.withLock { revoked } }
    func setRevoked(_ value: Bool) { lock.withLock { revoked = value } }
}

private final class ResolutionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    let release = DispatchSemaphore(value: 0)
    var hasEntered: Bool { lock.withLock { entered } }
    func wait() {
        lock.withLock { entered = true }
        release.wait()
    }
}

@MainActor
struct AppModelTests {
    private func settled(_ model: AppModel) async throws {
        for _ in 0..<400 {
            if !model.isChecking { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The model did not finish its check")
    }

    private func eventually(_ condition: () throws -> Bool) async throws -> Bool {
        for _ in 0..<400 {
            if try condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func persistedSelectionAndTargetsSurviveRestart() async throws {
        let fixture = try ModelFixture()
        let model = AppModel(environment: fixture.environment())
        try await settled(model)
        #expect(model.problem == nil)
        #expect(model.activeCount == 2)
        #expect(try Data(contentsOf: fixture.common.appendingPathComponent("first.kdbx")) == Data("first encrypted fixture".utf8))
        #expect(try Data(contentsOf: fixture.override.appendingPathComponent("second.kdbx")) == Data("second encrypted fixture".utf8))
        model.setEnabled(false, for: fixture.second)
        try await settled(model)
        await model.shutdown()
        let restarted = AppModel(environment: fixture.environment())
        try await settled(restarted)
        #expect(restarted.activeCount == 1)
        #expect(restarted.preference(for: fixture.second).target == Data("override".utf8))
        #expect(restarted.states[fixture.first.id]?.copied == false)
        await restarted.shutdown()
    }
    @Test func unavailableSourceClearsSuccessAndRestoredTargetRecovers() async throws {
        let fixture = try ModelFixture()
        let model = AppModel(environment: fixture.environment())
        try await settled(model)
        #expect(model.states[fixture.first.id]?.error == nil)
        let offline = fixture.root.appendingPathComponent("offline-target")
        try FileManager.default.moveItem(at: fixture.common, to: offline)
        model.refresh()
        try await settled(model)
        #expect(model.states[fixture.first.id]?.error != nil)
        #expect(model.states[fixture.second.id]?.error == nil)
        #expect(try Data(contentsOf: offline.appendingPathComponent("first.kdbx")) == Data("first encrypted fixture".utf8))
        try FileManager.default.moveItem(at: offline, to: fixture.common)
        model.refresh()
        try await settled(model)
        #expect(model.failureCount == 0)
        #expect(model.preference(for: fixture.first).lastFailure == nil)
        let sourceOffline = fixture.root.appendingPathComponent("offline-source")
        try FileManager.default.moveItem(at: fixture.source, to: sourceOffline)
        model.refresh()
        try await settled(model)
        #expect(model.problem != nil)
        #expect(model.states.isEmpty)
        try FileManager.default.moveItem(at: sourceOffline, to: fixture.source)
        model.refresh()
        try await settled(model)
        #expect(model.problem == nil)
        #expect(model.states[fixture.first.id]?.error == nil)
        await model.shutdown()
    }

    @Test func monitorFindsReplacementBackupDirectoryAndMetadata() async throws {
        let fixture = try ModelFixture()
        let model = AppModel(environment: fixture.environment())
        try await settled(model)
        let directory = fixture.source.appendingPathComponent("backups/\(fixture.first.id.uuidString)")
        try FileManager.default.moveItem(at: directory, to: fixture.root.appendingPathComponent("old-backups"))
        try fixture.backup(fixture.first, bytes: "replacement directory fixture")
        #expect(try await eventually { (try? Data(contentsOf: fixture.common.appendingPathComponent("first.kdbx"))) == Data("replacement directory fixture".utf8) })
        try fixture.backup(fixture.first, bytes: "second event fixture", name: "newer.bak")
        #expect(try await eventually { (try? Data(contentsOf: fixture.common.appendingPathComponent("first.kdbx"))) == Data("second event fixture".utf8) })
        let renamed = Database(id: fixture.first.id, filename: "renamed.kdbx", displayName: "Renamed")
        try fixture.catalog([renamed, fixture.second])
        #expect(try await eventually { model.databases.contains(renamed) && FileManager.default.fileExists(atPath: fixture.common.appendingPathComponent("renamed.kdbx").path) })
        #expect(try Data(contentsOf: directory.appendingPathComponent("backup.bak")) == Data("replacement directory fixture".utf8))
        await model.shutdown()
    }

    @Test func shutdownWaitsForInFlightWorkAndRejectsSecondInstance() async throws {
        let fixture = try ModelFixture()
        let gate = ResolutionGate()
        let base = fixture.environment(interval: 0.03)
        let resolve = base.resolveFolder
        let environment = AppEnvironment(preferencesURL: base.preferencesURL, resolveFolder: { data in
            if data == Data("source".utf8) { gate.wait() }
            return try resolve(data)
        }, scheduler: base.scheduler, notifications: nil, loginStatus: base.loginStatus, setLogin: base.setLogin)
        let model = AppModel(environment: environment)
        defer { gate.release.signal() }
        try #require(try await eventually { gate.hasEntered })
        let shutdown = Task { await model.shutdown() }
        try #require(try await eventually { model.isStopping })
        let duplicate = AppModel(environment: fixture.environment())
        #expect(duplicate.startupConflict)
        #expect(duplicate.databases.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.common.appendingPathComponent("first.kdbx").path))
        gate.release.signal()
        await shutdown.value
        #expect(!model.isChecking)
        #expect(try Data(contentsOf: fixture.common.appendingPathComponent("first.kdbx")) == Data("first encrypted fixture".utf8))
        let history = model.preferences.history.count
        try fixture.backup(fixture.first, bytes: "after shutdown", name: "after.bak")
        model.refresh()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.preferences.history.count == history)
        #expect(try Data(contentsOf: fixture.common.appendingPathComponent("first.kdbx")) == Data("first encrypted fixture".utf8))
        let restarted = AppModel(environment: fixture.environment())
        try await settled(restarted)
        #expect(!restarted.startupConflict)
        await restarted.shutdown()
        await duplicate.shutdown()
    }

    @Test func periodicAndWakeChecksRecoverRevokedSourceWithoutFileEvents() async throws {
        for useWake in [false, true] {
            let fixture = try ModelFixture()
            let grant = SimulatedGrant()
            let center = NotificationCenter()
            let base = fixture.environment(interval: useWake ? 3600 : 0.03, wakeCenter: center)
            let resolve = base.resolveFolder
            let environment = AppEnvironment(preferencesURL: base.preferencesURL, resolveFolder: { data in
                if data == Data("source".utf8), grant.isRevoked { throw CocoaError(.fileReadNoPermission) }
                return try resolve(data)
            }, scheduler: base.scheduler, notifications: nil, loginStatus: base.loginStatus, setLogin: base.setLogin)
            let model = AppModel(environment: environment)
            try await settled(model)
            grant.setRevoked(true)
            if useWake { center.post(name: NSWorkspace.didWakeNotification, object: nil) }
            #expect(try await eventually { model.problem != nil && model.states.isEmpty })
            grant.setRevoked(false)
            if useWake { center.post(name: NSWorkspace.didWakeNotification, object: nil) }
            #expect(try await eventually { model.problem == nil && model.states[fixture.first.id]?.checked != nil })
            await model.shutdown()
        }
    }

    @Test func loginChangesAreExplicitAndStoppedModelIgnoresChanges() async throws {
        let fixture = try ModelFixture()
        var enabled = false
        var requests: [Bool] = []
        let model = AppModel(environment: fixture.environment(loginStatus: { (enabled, enabled) }, setLogin: { value in
            enabled = value
            requests.append(value)
        }))
        try await settled(model)
        #expect(requests.isEmpty)
        #expect(!model.loginEnabled)
        model.setLogin(true)
        #expect(model.loginEnabled)
        #expect(model.loginNeedsApproval)
        model.setLogin(false)
        #expect(!model.loginEnabled)
        #expect(requests == [true, false])
        await model.shutdown()
        model.setLogin(true)
        model.setEnabled(false, for: fixture.first)
        model.setNotification(\.copies, to: true)
        #expect(requests == [true, false])
        #expect(model.preference(for: fixture.first).enabled)
        #expect(!model.preferences.notifications.copies)
    }

    @Test func staleOverrideAtRestartDoesNotPreventOtherDatabaseCopy() async throws {
        let fixture = try ModelFixture()
        var settings = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: fixture.preferencesURL))
        settings.databases[fixture.second.id.uuidString]?.target = Data("revoked-target".utf8)
        try JSONEncoder().encode(settings).write(to: fixture.preferencesURL)
        let existing = fixture.override.appendingPathComponent("second.kdbx")
        try Data("previous target copy".utf8).write(to: existing)
        let model = AppModel(environment: fixture.environment())
        try await settled(model)
        #expect(model.problem == nil)
        #expect(model.states[fixture.second.id]?.error != nil)
        #expect(model.states[fixture.first.id]?.error == nil)
        #expect(try Data(contentsOf: existing) == Data("previous target copy".utf8))
        #expect(model.preference(for: fixture.second).target == Data("revoked-target".utf8))
        await model.shutdown()
    }

    @Test func collidingDatabaseConfigurationPreservesExistingCopy() async throws {
        let fixture = try ModelFixture()
        let colliding = Database(id: fixture.second.id, filename: fixture.first.filename, displayName: "Collision")
        try fixture.catalog([fixture.first, colliding])
        var settings = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: fixture.preferencesURL))
        settings.databases[fixture.second.id.uuidString]?.target = nil
        try JSONEncoder().encode(settings).write(to: fixture.preferencesURL)
        let target = fixture.common.appendingPathComponent("first.kdbx")
        try Data("previous non-conflicting copy".utf8).write(to: target)
        let model = AppModel(environment: fixture.environment())
        try await settled(model)
        #expect(model.failureCount == 2)
        #expect(try Data(contentsOf: target) == Data("previous non-conflicting copy".utf8))
        #expect(model.states.values.allSatisfy { !$0.copied })
        await model.shutdown()
    }

}
