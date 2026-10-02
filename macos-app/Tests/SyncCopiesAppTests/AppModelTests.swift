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

final class ModelFixture: @unchecked Sendable {
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
    @MainActor func environment(interval: TimeInterval = 3600, wakeCenter: NotificationCenter = NotificationCenter(), loginStatus: @escaping () -> (enabled: Bool, needsApproval: Bool) = { (false, false) }, setLogin: @escaping (Bool) throws -> Void = { _ in }, notifications: NotificationService? = nil) -> AppEnvironment {
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
        }, scheduler: AppScheduler(interval: interval, wakeCenter: wakeCenter), notifications: notifications, loginStatus: loginStatus, setLogin: setLogin)
    }
}

private final class SimulatedGrant: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    var isRevoked: Bool { lock.withLock { revoked } }
    func setRevoked(_ value: Bool) { lock.withLock { revoked = value } }
}

private final class ScanPhase: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    var hasStarted: Bool { lock.withLock { started } }
    func start() { lock.withLock { started = true } }
}

private final class SimulatedMounts: @unchecked Sendable {
    private let lock = NSLock()
    private var mounts: [FolderPathDisplay.Mount]
    init(_ mounts: [FolderPathDisplay.Mount]) { self.mounts = mounts }
    func snapshot() -> [FolderPathDisplay.Mount] { lock.withLock { mounts } }
    func unmount() { lock.withLock { mounts = [] } }
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
    @Test func wrongSavedSourceAllowsCorrectionAndPreservesExistingCopy() async throws {
        let fixture = try ModelFixture()
        let target = fixture.common.appendingPathComponent(fixture.first.filename)
        try Data("previous encrypted copy".utf8).write(to: target)
        let base = fixture.environment()
        let resolve = base.resolveFolder
        let environment = AppEnvironment(preferencesURL: base.preferencesURL, resolveFolder: { data in
            if data == Data("source".utf8) { return FolderAccess(url: fixture.common) }
            return try resolve(data)
        }, scheduler: base.scheduler, notifications: nil, loginStatus: base.loginStatus, setLogin: base.setLogin)
        let model = AppModel(environment: environment)
        try await settled(model)
        #expect(model.sourceReadStatus == .unconfirmed)
        #expect(model.canChooseSource)
        #expect(try Data(contentsOf: target) == Data("previous encrypted copy".utf8))
        await model.shutdown()
    }

    @Test func disappearingDestinationDoesNotBlockHealthyDatabase() async throws {
        let fixture = try ModelFixture()
        let phase = ScanPhase()
        let base = fixture.environment()
        let resolve = base.resolveFolder
        let environment = AppEnvironment(preferencesURL: base.preferencesURL, resolveFolder: { data in
            if data == Data("source".utf8) { phase.start() }
            if data == Data("override".utf8), phase.hasStarted,
               FileManager.default.fileExists(atPath: fixture.common.path) {
                try FileManager.default.removeItem(at: fixture.common)
            }
            return try resolve(data)
        }, scheduler: base.scheduler, notifications: nil, loginStatus: base.loginStatus, setLogin: base.setLogin)
        let model = AppModel(environment: environment)
        try await settled(model)
        #expect(model.sourceReadStatus == .available)
        #expect(model.states[fixture.first.id]?.error != nil)
        #expect(model.preference(for: fixture.second).lastCopied != nil)
        #expect(model.states[fixture.second.id]?.error == nil)
        #expect(model.preferences.globalFailure == nil)
        let target = fixture.override.appendingPathComponent(fixture.second.filename)
        #expect(try Data(contentsOf: target) == Data("second encrypted fixture".utf8))
        await model.shutdown()
    }

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

    @Test func savedSourceGrantDoesNotProveAccessWhileCheckIsPending() async throws {
        let fixture = try ModelFixture()
        let gate = ResolutionGate()
        let base = fixture.environment()
        let resolve = base.resolveFolder
        let environment = AppEnvironment(preferencesURL: base.preferencesURL, resolveFolder: { data in
            if data == Data("source".utf8), !gate.hasEntered { gate.wait() }
            return try resolve(data)
        }, scheduler: base.scheduler, notifications: nil, loginStatus: base.loginStatus, setLogin: base.setLogin)
        let model = AppModel(environment: environment)
        defer { gate.release.signal() }
        try #require(try await eventually { gate.hasEntered })
        #expect(model.sourceGranted)
        #expect(model.sourceReadStatus == .checking)
        #expect(!model.canChooseSource)
        gate.release.signal()
        try await settled(model)
        #expect(model.sourceReadStatus == .available)
        #expect(!model.canChooseSource)
        #expect(model.sourceFolderPath == fixture.source.path)
        await model.shutdown()
    }

    @Test func savedButDeniedSourceGrantCanBeRetriedAndRecovered() async throws {
        let fixture = try ModelFixture()
        let grant = SimulatedGrant()
        grant.setRevoked(true)
        let base = fixture.environment()
        let resolve = base.resolveFolder
        let environment = AppEnvironment(preferencesURL: base.preferencesURL, resolveFolder: { data in
            if data == Data("source".utf8), grant.isRevoked { throw FolderPermissionError.accessDenied }
            return try resolve(data)
        }, scheduler: base.scheduler, notifications: nil, loginStatus: base.loginStatus, setLogin: base.setLogin)
        let model = AppModel(environment: environment)
        try await settled(model)
        #expect(model.sourceGranted)
        #expect(model.sourceReadStatus == .unavailable)
        #expect(model.canChooseSource)
        grant.setRevoked(false)
        model.refresh()
        try await settled(model)
        #expect(model.sourceReadStatus == .available)
        #expect(!model.canChooseSource)
        #expect(model.sourceFolderPath == fixture.source.path)
        grant.setRevoked(true)
        model.refresh()
        try await settled(model)
        #expect(model.sourceReadStatus == .unavailable)
        #expect(model.canChooseSource)
        #expect(model.sourceFolderPath == fixture.source.path)
        await model.shutdown()
    }

    @Test func staleSavedSourceGrantRequiresExplicitRenewal() async throws {
        let fixture = try ModelFixture()
        let base = fixture.environment()
        let resolve = base.resolveFolder
        let environment = AppEnvironment(preferencesURL: base.preferencesURL, resolveFolder: { data in
            if data == Data("source".utf8) { throw FolderPermissionError.staleBookmark }
            return try resolve(data)
        }, scheduler: base.scheduler, notifications: nil, loginStatus: base.loginStatus, setLogin: base.setLogin)
        let model = AppModel(environment: environment)
        try await settled(model)
        #expect(model.sourceGranted)
        #expect(model.sourceReadStatus == .unavailable)
        #expect(model.canChooseSource)
        #expect(model.problem == FolderPermissionError.staleBookmark.localizedDescription)
        await model.shutdown()
    }

    @Test func unreadableMetadataDirectoryDetectsLossDespiteResolvedGrant() async throws {
        let fixture = try ModelFixture()
        let directory = fixture.source.appendingPathComponent("Library/Preferences")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        defer { _ = chmod(directory.path, 0o700) }
        let model = AppModel(environment: fixture.environment())
        try await settled(model)
        #expect(model.sourceGranted)
        #expect(model.sourceReadStatus == .unavailable)
        #expect(model.canChooseSource)
        #expect(model.problem != nil)
        #expect(model.sourceFolderPath == fixture.source.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        model.refresh()
        try await settled(model)
        #expect(model.sourceReadStatus == .available)
        #expect(!model.canChooseSource)
        #expect(model.problem == nil)
        await model.shutdown()
    }

    @Test func missingMetadataAllowsManualSourceCorrection() async throws {
        let fixture = try ModelFixture()
        try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("Library/Preferences/group.strongbox.mac.mcguill.plist"))
        let model = AppModel(environment: fixture.environment())
        try await settled(model)
        #expect(model.problem != nil)
        #expect(model.sourceReadStatus == .unconfirmed)
        #expect(model.canChooseSource)
        await model.shutdown()
    }

    @Test func transientSourceFailureAllowsManualSourceCorrection() async throws {
        let fixture = try ModelFixture()
        let base = fixture.environment()
        let resolve = base.resolveFolder
        let environment = AppEnvironment(preferencesURL: base.preferencesURL, resolveFolder: { data in
            if data == Data("source".utf8) { throw MirrorError.changedFile }
            return try resolve(data)
        }, scheduler: base.scheduler, notifications: nil, loginStatus: base.loginStatus, setLogin: base.setLogin)
        let model = AppModel(environment: environment)
        try await settled(model)
        #expect(model.problem == MirrorError.changedFile.localizedDescription)
        #expect(model.sourceReadStatus == .unconfirmed)
        #expect(model.canChooseSource)
        await model.shutdown()
    }

    @Test func unreadableBackupFolderOrFileRequiresSourceRenewal() async throws {
        for denyFolder in [true, false] {
            let fixture = try ModelFixture()
            let folder = fixture.source.appendingPathComponent("backups/\(fixture.first.id.uuidString)")
            let denied = denyFolder ? folder : folder.appendingPathComponent("backup.bak")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
            defer { _ = chmod(denied.path, denyFolder ? 0o700 : 0o600) }
            let model = AppModel(environment: fixture.environment())
            try await settled(model)
            #expect(model.states[fixture.first.id]?.error != nil)
            #expect(model.states[fixture.second.id]?.error == nil)
            #expect(model.sourceReadStatus == .unavailable)
            #expect(model.canChooseSource)
            try FileManager.default.setAttributes([.posixPermissions: denyFolder ? 0o700 : 0o600], ofItemAtPath: denied.path)
            model.refresh()
            try await settled(model)
            #expect(model.sourceReadStatus == .available)
            #expect(!model.canChooseSource)
            await model.shutdown()
        }
    }

    @Test func deniedTargetDoesNotRequestSourceRenewal() async throws {
        let fixture = try ModelFixture()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.common.path)
        defer { _ = chmod(fixture.common.path, 0o700) }
        let model = AppModel(environment: fixture.environment())
        try await settled(model)
        #expect(model.states[fixture.first.id]?.error != nil)
        #expect(model.states[fixture.second.id]?.error == nil)
        #expect(model.sourceReadStatus == .available)
        #expect(!model.canChooseSource)
        await model.shutdown()
    }

    @Test func copyPermissionFailuresRetainSourceOrTargetProvenance() throws {
        for denySource in [true, false] {
            let fixture = try ModelFixture()
            let backup = try StrongboxBackups.newest(for: fixture.first, groupContainer: fixture.source)
            let target = fixture.common.appendingPathComponent(fixture.first.filename)
            try Data("existing fixture copy".utf8).write(to: target)
            let denied = denySource ? backup.url : fixture.common
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
            defer { _ = chmod(denied.path, denySource ? 0o600 : 0o700) }
            #expect(throws: denySource ? MirrorError.sourcePermissionDenied : MirrorError.permissionDenied) {
                try MirrorEngine.copy(backup: backup, to: fixture.common, filename: fixture.first.filename)
            }
            try FileManager.default.setAttributes([.posixPermissions: denySource ? 0o600 : 0o700], ofItemAtPath: denied.path)
            #expect(try Data(contentsOf: target) == Data("existing fixture copy".utf8))
        }
    }

    @Test func malformedMetadataKeepsWorkingAccessSeparateFromCatalogFailure() async throws {
        let fixture = try ModelFixture()
        try Data("invalid fixture metadata".utf8).write(to: fixture.source.appendingPathComponent("Library/Preferences/group.strongbox.mac.mcguill.plist"))
        let model = AppModel(environment: fixture.environment())
        try await settled(model)
        #expect(model.problem == MirrorError.invalidMetadata.localizedDescription)
        #expect(model.sourceReadStatus == .available)
        #expect(!model.canChooseSource)
        #expect(model.sourceFolderPath == fixture.source.path)
        await model.shutdown()
    }

    @Test func targetFailurePreservesSourceAccessAndCompleteFolderPaths() async throws {
        let fixture = try ModelFixture()
        let model = AppModel(environment: fixture.environment())
        try await settled(model)
        #expect(model.sourceReadStatus == .available)
        #expect(model.commonTargetName == fixture.common.path)
        #expect(model.targetFolderPath(for: fixture.first) == fixture.common.path)
        #expect(model.targetFolderPath(for: fixture.second) == fixture.override.path)
        #expect(model.states[fixture.first.id]?.targetName == fixture.common.path)
        let offline = fixture.root.appendingPathComponent("offline-target")
        try FileManager.default.moveItem(at: fixture.common, to: offline)
        model.refresh()
        try await settled(model)
        #expect(model.states[fixture.first.id]?.error != nil)
        #expect(model.sourceReadStatus == .available)
        #expect(!model.canChooseSource)
        #expect(model.commonTargetName == fixture.common.path)
        #expect(model.states[fixture.first.id]?.targetName == fixture.common.path)
        #expect(model.targetFolderPath(for: fixture.first) == fixture.common.path)
        await model.shutdown()
    }

    @Test func networkFolderLabelsRetainServerShareAndLocalPathsAfterUnmount() async throws {
        let fixture = try ModelFixture()
        let mounts = SimulatedMounts([
            FolderPathDisplay.Mount(path: fixture.common.path, source: "//alice:secret@nas.example/Downloads"),
            FolderPathDisplay.Mount(path: fixture.override.path, source: "//work.example/Backups"),
        ])
        let model = AppModel(environment: fixture.environment(), folderMounts: { mounts.snapshot() })
        try await settled(model)
        let commonLabel = "smb://nas.example/Downloads\n\(fixture.common.path)"
        let overrideLabel = "smb://work.example/Backups\n\(fixture.override.path)"
        #expect(model.commonTargetName == commonLabel)
        #expect(model.targetFolderPath(for: fixture.first) == commonLabel)
        #expect(model.targetFolderPath(for: fixture.second) == overrideLabel)
        #expect(model.states[fixture.first.id]?.targetName == commonLabel)
        #expect(model.sourceFolderPath == fixture.source.path)
        mounts.unmount()
        // Even a still-resolvable bookmark must not erase the cached remote path.
        model.refresh()
        try await settled(model)
        #expect(model.commonTargetName == commonLabel)
        #expect(model.states[fixture.first.id]?.targetName == commonLabel)
        try FileManager.default.moveItem(at: fixture.common, to: fixture.root.appendingPathComponent("offline-target"))
        model.refresh()
        try await settled(model)
        #expect(model.states[fixture.first.id]?.error != nil)
        #expect(model.states[fixture.first.id]?.targetName == commonLabel)
        #expect(model.commonTargetName == commonLabel)
        #expect(model.targetFolderPath(for: fixture.second) == overrideLabel)
        await model.shutdown()
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
