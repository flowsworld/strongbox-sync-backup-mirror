import Darwin
import Foundation
import Testing
import SyncCopiesCore
@testable import SyncCopies

private actor DriveServerFixture {
    let account = GoogleDriveAccount(identity: try! GoogleDriveIdentity(drivePermissionID: "synthetic-account", emailAddress: "fixture@example.invalid"), credentialID: UUID())
    var listed: [GoogleDriveAccount] = []
    var remote: UploadRemoteFile?
    var problem: UploadVerificationFailure?
    var calls = 0
    var blocked = false
    var suspended: CheckedContinuation<Void, Never>?
    var folderBlocked = false
    var folderSuspended: CheckedContinuation<Void, Never>?
    var connectionBlocked = false
    var connectionSuspended: CheckedContinuation<Void, Never>?
    var connectionCancellations = 0
    var connectionRollbackFails = false
    var disconnects = 0
    var connected = true
    var cleanupPending = false
    var listingFails = false

    func setListingFailure(_ fails: Bool) { listingFails = fails }
    func list() throws -> [GoogleDriveAccount] {
        if listingFails { throw GoogleDriveAccountFailure.credentialsUnavailable }
        return accounts()
    }
    func accounts() -> [GoogleDriveAccount] { connected ? (listed.isEmpty ? [account] : listed) : [] }
    func connect() async throws -> GoogleDriveAccount {
        if connectionBlocked { await withCheckedContinuation { connectionSuspended = $0 } }
        if connectionRollbackFails { throw GoogleDriveAccountFailure.rollbackFailed }
        return account
    }
    func blockConnection() { connectionBlocked = true }
    func failConnectionRollback() { connectionRollbackFails = true }
    func releaseConnection() { connectionBlocked = false; connectionSuspended?.resume(); connectionSuspended = nil }
    func cancelConnection() { connectionCancellations += 1 }
    func disconnect() { disconnects += 1; connected = false }
    func setCleanupPending(_ pending: Bool) { cleanupPending = pending }
    func folder(_ id: String) async throws -> GoogleDriveFolder {
        if folderBlocked { await withCheckedContinuation { folderSuspended = $0 } }
        return try GoogleDriveMetadata.resolveFolder(Data("{\"id\":\"\(id == "root" ? "resolved-root" : id)\",\"name\":\"Fixture folder\",\"mimeType\":\"application/vnd.google-apps.folder\",\"trashed\":false}".utf8), requestedID: id)
    }
    func query() async throws -> UploadRemoteFile? {
        calls += 1
        let captured = remote
        if blocked { await withCheckedContinuation { suspended = $0 } }
        if let problem { throw problem }
        return captured
    }
    func set(remote: UploadRemoteFile?, problem: UploadVerificationFailure? = nil) { self.remote = remote; self.problem = problem }
    func setBlocked(_ value: Bool) { blocked = value }
    func release() { blocked = false; suspended?.resume(); suspended = nil }
    func blockFolder() { folderBlocked = true }
    func releaseFolder() { folderBlocked = false; folderSuspended?.resume(); folderSuspended = nil }
    func rotate() {
        listed = [GoogleDriveAccount(identity: try! GoogleDriveIdentity(drivePermissionID: "synthetic-account"), credentialID: UUID())]
    }
}

private actor DriveSnapshotGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor DriveAccountCleanupGate {
    private(set) var calls = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        calls += 1
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private actor DriveDisconnectGate {
    private var remaining: [GoogleDriveAccount]
    private var continuation: CheckedContinuation<Void, Never>?
    private var busy = false
    var entered: Bool { continuation != nil }
    init(first: GoogleDriveAccount, second: GoogleDriveAccount) {
        remaining = [first, second]
    }
    func list() -> [GoogleDriveAccount] { remaining }
    func disconnect(_ id: String) async throws {
        guard !busy else { throw GoogleDriveAccountFailure.busy }
        busy = true
        defer { busy = false }
        remaining.removeAll { $0.id == id }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class DriveControllerFixture {
    let root: URL
    let server = DriveServerFixture()
    let id = UUID()
    var now: UInt64 = 100
    var fingerprint = try! UploadLocalFingerprint(size: 12, sha256: String(repeating: "a", count: 64), md5: String(repeating: "b", count: 32))
    var localFailure: UploadVerificationFailure?
    var catalogFailure: UploadVerificationFailure?
    var validationFailure: UploadVerificationFailure?
    var validationFileFailure: MirrorError?
    var localEnabled = true
    var delivered: [DriveVerificationEvent] = []
    var history: [DriveVerificationEvent] = []
    var cancelled: [UUID] = []
    var deliveryFails = false
    var permissionDenied = false
    var snapshotGate: DriveSnapshotGate?
    var accountCleanupGate: DriveAccountCleanupGate?

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    var settingsURL: URL { root.appendingPathComponent("drive-settings.json") }
    var environment: DriveVerificationEnvironment {
        let server = server
        let cleanupGate = accountCleanupGate
        return DriveVerificationEnvironment(listAccounts: {
            if let cleanupGate { await cleanupGate.wait() }
            return try await server.list()
        }, connect: { try await server.connect() },
            cancelConnect: { await server.cancelConnection() }, disconnect: { _ in await server.disconnect() }, resolveFolder: { _, id in try await server.folder(id) },
            remoteFile: { _, _, _ in try await server.query() }, localInputs: { [self] in
                if let catalogFailure { throw catalogFailure }
                guard localEnabled else { return [] }
                let local = fingerprint, localProblem = localFailure, validationProblem = validationFailure
                let fileProblem = validationFileFailure
                let gate = snapshotGate
                return [DriveLocalInput(id: id, name: "Fixture database", filename: "fixture.kdbx", destinationID: "destination-1", makeSnapshot: {
                    if let gate { await gate.wait() }
                    if let localProblem { throw localProblem }
                    return DriveLocalSnapshot(fingerprint: local, validate: {
                        if let validationProblem { throw validationProblem }
                        if let fileProblem { throw fileProblem }
                    })
                })]
            }, deliver: { [self] event in
                if deliveryFails { throw UploadVerificationFailure.providerUnavailable }
                delivered.append(event)
                return permissionDenied ? .permissionDenied : .delivered
            }, cancelNotification: { [self] in cancelled.append($0) }, history: { [self] in history.append($0) }, clock: { [self] in now })
    }
    func controller() -> DriveVerificationController { DriveVerificationController(settingsURL: settingsURL, environment: environment) }
    func bind(_ controller: DriveVerificationController) async throws {
        await controller.start()
        try await controller.selectFolder(databaseID: id, accountID: (await server.accounts())[0].id, input: "root")
        try await settle(controller)
    }
    func matching() throws -> UploadRemoteFile {
        try UploadRemoteFile(id: "remote-fixture", size: fingerprint.size, sha256: fingerprint.sha256)
    }
    func settle(_ controller: DriveVerificationController) async throws {
        for _ in 0..<100 { await Task.yield() }
        for _ in 0..<10_000 {
            if !controller.isChecking { return }
            await Task.yield()
        }
        Issue.record("Drive check did not settle")
        throw UploadVerificationFailure.providerUnavailable
    }
    func awaitQuery() async throws {
        for _ in 0..<10_000 {
            if await server.suspended != nil { return }
            await Task.yield()
        }
        Issue.record("Simulated query did not start")
        throw UploadVerificationFailure.providerUnavailable
    }
    func awaitFolder() async throws {
        for _ in 0..<10_000 {
            if await server.folderSuspended != nil { return }
            await Task.yield()
        }
        Issue.record("Simulated folder resolution did not start")
        throw UploadVerificationFailure.providerUnavailable
    }
    func remove() { try! FileManager.default.removeItem(at: root) }
}

@MainActor
struct DriveVerificationControllerTests {
    @Test func shutdownWaitsForStartedCredentialCleanupAndRejectsNewStarts() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        let gate = DriveAccountCleanupGate()
        fixture.accountCleanupGate = gate
        let controller = fixture.controller()
        let initialLoad = Task { await controller.start() }
        for _ in 0..<10_000 {
            if await gate.calls > 0 { break }
            await Task.yield()
        }
        #expect(await gate.calls == 1)
        var shutdownFinished = false
        let shutdown = Task {
            let ready = await controller.quiesceAndPersist()
            shutdownFinished = true
            return ready
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(!shutdownFinished)
        let stoppedLoad = Task { await controller.start() }
        for _ in 0..<100 { await Task.yield() }
        #expect(await gate.calls == 1)
        await gate.release()
        await initialLoad.value
        await stoppedLoad.value
        #expect(await shutdown.value)
        #expect(controller.accounts.isEmpty)
        #expect(controller.failure == nil)
    }

    @Test func cancelledSignInReportsAFailedCredentialRollback() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        await fixture.server.blockConnection()
        await fixture.server.failConnectionRollback()
        let controller = fixture.controller()
        controller.connect()
        for _ in 0..<10_000 {
            if await fixture.server.connectionSuspended != nil { break }
            await Task.yield()
        }
        try #require(await fixture.server.connectionSuspended != nil)
        controller.cancelConnect()
        await fixture.server.releaseConnection()
        for _ in 0..<10_000 {
            if controller.failure == .connectionFailed { break }
            await Task.yield()
        }
        #expect(controller.failure == .connectionFailed)
        #expect(!controller.isConnecting)
        #expect(await controller.quiesceAndPersist())
    }

    @Test func successfulCompleteRefreshClearsAnEarlierAccountFailureWithoutBindings() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        let controller = fixture.controller()
        await fixture.server.setListingFailure(true)
        await controller.start()
        #expect(controller.failure == .accountUnavailable)
        await fixture.server.setListingFailure(false)
        fixture.catalogFailure = .localFileUnavailable
        controller.requestCheck()
        try await fixture.settle(controller)
        #expect(controller.failure == .accountUnavailable)
        fixture.catalogFailure = nil
        controller.requestCheck()
        try await fixture.settle(controller)
        #expect(controller.accounts == (await fixture.server.accounts()))
        #expect(controller.bindings.isEmpty)
        #expect(controller.failure == nil)
    }

    @Test func accountCleanupStatusIsPublishedAndRefreshedWithoutRequiredFixtureHooks() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        let server = fixture.server
        var environment = fixture.environment
        environment.credentialCleanupStatus = { await server.cleanupPending }
        let controller = DriveVerificationController(settingsURL: fixture.settingsURL, environment: environment)
        await server.setCleanupPending(true)
        await controller.start()
        #expect(controller.cleanupPending)
        await server.setCleanupPending(false)
        controller.requestCheck()
        try await fixture.settle(controller)
        #expect(!controller.cleanupPending)
        let ordinaryFixture = fixture.controller()
        await ordinaryFixture.start()
        #expect(!ordinaryFixture.cleanupPending)
    }

    @Test func savedConfirmationStaysHiddenUntilTheCurrentSnapshotIsKnown() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        await fixture.server.set(remote: try fixture.matching())
        let controller = fixture.controller()
        try await fixture.bind(controller)
        #expect(controller.results[fixture.id]?.status == .confirmed)
        fixture.fingerprint = try UploadLocalFingerprint(size: 13, sha256: String(repeating: "c", count: 64), md5: String(repeating: "d", count: 32))
        let gate = DriveSnapshotGate()
        fixture.snapshotGate = gate
        controller.localCopiesChanged()
        controller.requestCheck()
        for _ in 0..<10_000 {
            if await gate.entered { break }
            await Task.yield()
        }
        #expect(await gate.entered)
        #expect(controller.results[fixture.id]?.status != .confirmed)
        try controller.setPreferences(controller.preferences)
        #expect(controller.results[fixture.id]?.status != .confirmed)
        await gate.release()
        try await fixture.settle(controller)
        #expect(controller.results[fixture.id]?.status == .pending)
        #expect(controller.results[fixture.id]?.localSHA256 == fixture.fingerprint.sha256)
    }

    @Test func repeatedCancellationStillWaitsForTheOriginalConnectionRollback() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        let controller = fixture.controller()
        await fixture.server.blockConnection()
        controller.connect()
        for _ in 0..<10_000 {
            if await fixture.server.connectionSuspended != nil { break }
            await Task.yield()
        }
        #expect(await fixture.server.connectionSuspended != nil)
        controller.cancelConnect()
        controller.cancelConnect()
        var finished = false
        let shutdown = Task { let ready = await controller.quiesceAndPersist(); finished = true; return ready }
        for _ in 0..<100 { await Task.yield() }
        #expect(!finished)
        await fixture.server.releaseConnection()
        #expect(await shutdown.value)
        #expect(finished)
    }

    @Test(arguments: [false, true]) func queuedRecoveryUsesTheCurrentConfirmationFact(originallyConfirmed: Bool) async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        await fixture.server.set(remote: nil, problem: .accessDenied)
        let controller = fixture.controller()
        try await fixture.bind(controller)
        fixture.deliveryFails = true
        await fixture.server.set(remote: originallyConfirmed ? try fixture.matching() : nil)
        controller.requestCheck()
        try await fixture.settle(controller)
        #expect(fixture.history.last?.kind == .recovery)
        #expect(fixture.history.last?.confirmed == originallyConfirmed)
        fixture.deliveryFails = false
        await fixture.server.set(remote: originallyConfirmed ? nil : try fixture.matching())
        controller.requestCheck()
        try await fixture.settle(controller)
        #expect(fixture.delivered.last?.kind == .recovery)
        #expect(fixture.delivered.last?.confirmed == !originallyConfirmed)
    }

    @Test func supersededFailedErrorDeliveriesDoNotInvalidateSettingsOnRestart() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        fixture.deliveryFails = true
        await fixture.server.set(remote: nil, problem: .accessDenied)
        let controller = fixture.controller()
        try await fixture.bind(controller)
        for index in 0..<20 {
            await fixture.server.set(remote: nil, problem: index.isMultiple(of: 2) ? .providerUnavailable : .accessDenied)
            controller.requestCheck()
            try await fixture.settle(controller)
        }
        let restarted = fixture.controller()
        #expect(restarted.bindings[fixture.id] == controller.bindings[fixture.id])
        #expect(restarted.failure == nil)
        await restarted.start()
        fixture.deliveryFails = false
        restarted.requestCheck()
        try await fixture.settle(restarted)
        #expect(fixture.delivered.count == 1)
        #expect(fixture.delivered.first?.problem == .accessDenied)
    }

    @Test func updateQuiesceWaitsForFolderOperationsAndRejectsFurtherMutations() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        let controller = fixture.controller()
        await controller.start()
        await fixture.server.blockFolder()
        let binding = Task { try await controller.selectFolder(databaseID: fixture.id, accountID: (await fixture.server.accounts())[0].id, input: "root") }
        try await fixture.awaitFolder()
        var prepared = false
        let preparation = Task { let result = await controller.quiesceAndPersist(); prepared = true; return result }
        for _ in 0..<100 { await Task.yield() }
        #expect(!prepared)
        #expect(throws: DriveControllerFailure.busy) { try controller.disable(databaseID: fixture.id) }
        #expect(throws: DriveControllerFailure.busy) { try controller.setPreferences(DriveNotificationPreferences()) }
        await #expect(throws: DriveControllerFailure.busy) { try await controller.disconnect(accountID: "google-drive:synthetic-account") }
        await fixture.server.releaseFolder()
        #expect(await preparation.value)
        await #expect(throws: (any Error).self) { try await binding.value }
        #expect(controller.bindings.isEmpty)
        controller.resume()
        try await fixture.bind(controller)
        #expect(controller.bindings[fixture.id] != nil)
    }

    @Test func firstMismatchDoesNotCountTimeSpentWaitingForItsResponse() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        let controller = fixture.controller()
        await controller.start()
        await fixture.server.setBlocked(true)
        try await controller.selectFolder(databaseID: fixture.id, accountID: (await fixture.server.accounts())[0].id, input: "root")
        try await fixture.awaitQuery()
        fixture.now += 800
        await fixture.server.release()
        try await fixture.settle(controller)
        #expect(controller.results[fixture.id]?.pendingSeconds == 0)
    }

    @Test func changedContentCanRecoverImmediatelyWithoutConfirmationAlerts() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        await fixture.server.set(remote: nil, problem: .accessDenied)
        let controller = fixture.controller()
        try await fixture.bind(controller)
        fixture.fingerprint = try UploadLocalFingerprint(size: 14, sha256: String(repeating: "c", count: 64), md5: String(repeating: "d", count: 32))
        await fixture.server.set(remote: try fixture.matching())
        controller.localCopiesChanged()
        controller.requestCheck()
        try await fixture.settle(controller)
        #expect(fixture.delivered.map(\.kind) == [.error, .recovery])
        #expect(fixture.delivered.last?.confirmed == true)
    }

    @Test func unchangedRecoveryDoesNotRepeatConfirmationWhenRecoveryAlertsAreOff() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        let controller = fixture.controller()
        var preferences = DriveNotificationPreferences()
        preferences.recoveries = false
        preferences.confirmed = true
        try controller.setPreferences(preferences)
        await fixture.server.set(remote: try fixture.matching())
        try await fixture.bind(controller)
        await fixture.server.set(remote: nil, problem: .accessDenied)
        controller.requestCheck()
        try await fixture.settle(controller)
        await fixture.server.set(remote: try fixture.matching())
        controller.requestCheck()
        try await fixture.settle(controller)
        #expect(fixture.delivered.map(\.kind) == [.confirmed, .error])
    }

    @Test func unavailableAndDemoHaveNoExternalOrPersistenceEffects() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        let unavailable = DriveVerificationController(settingsURL: fixture.settingsURL, environment: nil)
        unavailable.connect()
        #expect(unavailable.failure == .unavailable)
        #expect(!unavailable.isAvailable)
        let demo = DriveVerificationController(settingsURL: fixture.settingsURL, environment: fixture.environment, demo: true)
        await demo.start()
        demo.requestCheck()
        demo.connect()
        demo.localCopiesChanged()
        #expect(await demo.quiesceAndPersist())
        #expect(!demo.isAvailable)
        #expect(await fixture.server.calls == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.settingsURL.path))
    }

    @Test func resolvedFolderAndPrivateSettingsContainNoCredentials() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        let controller = fixture.controller()
        await controller.start()
        await #expect(throws: DriveControllerFailure.folderUnavailable) {
            try await controller.selectFolder(databaseID: fixture.id, accountID: (await fixture.server.accounts())[0].id, input: "https://untrusted.invalid/folder")
        }
        #expect(controller.bindings.isEmpty)
        try await fixture.bind(controller)
        #expect(controller.bindings[fixture.id]?.folderID == "resolved-root")
        #expect(controller.preferences == DriveNotificationPreferences())
        #expect(controller.results[fixture.id]?.status == .pending)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.settingsURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let text = try String(contentsOf: fixture.settingsURL, encoding: .utf8)
        #expect(!text.contains("accessToken"))
        #expect(!text.contains("refreshToken"))
        #expect(!text.contains("clientSecret"))
    }

    @Test func errorsNeverDisplayHistoricalConfirmationAndDeduplicateAcrossRestart() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        await fixture.server.set(remote: try fixture.matching())
        var controller = fixture.controller()
        try await fixture.bind(controller)
        #expect(controller.results[fixture.id]?.status == .confirmed)
        #expect(fixture.delivered.isEmpty)
        await fixture.server.set(remote: nil, problem: .accessDenied)
        fixture.now += 60
        controller.requestCheck()
        try await fixture.settle(controller)
        #expect(controller.results[fixture.id]?.status == .error(.accessDenied))
        #expect(controller.results[fixture.id]?.lastConfirmedAt == 100)
        #expect(fixture.delivered.map(\.kind) == [.error])
        fixture.fingerprint = try UploadLocalFingerprint(size: 13, sha256: String(repeating: "c", count: 64), md5: String(repeating: "d", count: 32))
        controller.localCopiesChanged()
        controller.requestCheck()
        try await fixture.settle(controller)
        #expect(fixture.delivered.map(\.kind) == [.error])
        #expect(controller.results[fixture.id]?.lastConfirmedAt == nil)
        controller = fixture.controller()
        await controller.start()
        fixture.now += 60
        controller.requestCheck()
        try await fixture.settle(controller)
        #expect(fixture.delivered.map(\.kind) == [.error])
        await fixture.server.set(remote: nil)
        controller.requestCheck()
        try await fixture.settle(controller)
        #expect(fixture.delivered.map(\.kind) == [.error, .recovery])
        #expect(fixture.delivered.last?.confirmed == false)
    }

    @Test func overdueCountsSuccessfulIntervalsAndDoesNotRepeat() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        let controller = fixture.controller()
        try await fixture.bind(controller)
        for timestamp: UInt64 in [1000, 1900, 2800] {
            fixture.now = timestamp
            controller.requestCheck()
            try await fixture.settle(controller)
        }
        #expect(controller.results[fixture.id]?.status == .overdue)
        #expect(fixture.delivered.map(\.kind) == [.overdue])
        await fixture.server.set(remote: nil, problem: .providerUnavailable)
        fixture.now = 3700
        controller.requestCheck()
        try await fixture.settle(controller)
        await fixture.server.set(remote: nil)
        fixture.now = 100_000
        controller.requestCheck()
        try await fixture.settle(controller)
        #expect(controller.results[fixture.id]?.pendingSeconds == 2700)
        #expect(fixture.delivered.map(\.kind) == [.overdue, .error, .recovery])
    }

    @Test func newContentPublishesPendingAndDiscardsOlderNetworkResult() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        await fixture.server.set(remote: try fixture.matching())
        let controller = fixture.controller()
        try await fixture.bind(controller)
        await fixture.server.setBlocked(true)
        controller.requestCheck()
        try await fixture.awaitQuery()
        fixture.fingerprint = try UploadLocalFingerprint(size: 14, sha256: String(repeating: "c", count: 64), md5: String(repeating: "d", count: 32))
        controller.localCopiesChanged()
        #expect(controller.results.isEmpty)
        controller.requestCheck()
        await fixture.server.release()
        await fixture.server.set(remote: nil)
        try await fixture.settle(controller)
        #expect(controller.results[fixture.id]?.status == .pending)
        #expect(controller.results[fixture.id]?.localSHA256 == fixture.fingerprint.sha256)
        #expect(controller.results[fixture.id]?.lastConfirmedAt == nil)
        fixture.localEnabled = false
        controller.localCopiesChanged()
        controller.requestCheck()
        try await fixture.settle(controller)
        #expect(controller.results.isEmpty)
    }

    @Test func deliveryFailureRetriesButPermissionDenialDoesNotReplay() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        fixture.deliveryFails = true
        await fixture.server.set(remote: nil, problem: .accessDenied)
        var controller = fixture.controller()
        try await fixture.bind(controller)
        #expect(fixture.history.map(\.kind) == [.error])
        #expect(fixture.delivered.isEmpty)
        controller.localCopiesChanged()
        controller.requestCheck()
        try await fixture.settle(controller)
        #expect(fixture.history.map(\.kind) == [.error])
        controller = fixture.controller()
        await controller.start()
        fixture.deliveryFails = false
        fixture.permissionDenied = true
        controller.requestCheck()
        try await fixture.settle(controller)
        #expect(fixture.delivered.count == 1)
        fixture.permissionDenied = false
        controller = fixture.controller()
        await controller.start()
        controller.requestCheck()
        try await fixture.settle(controller)
        #expect(fixture.delivered.count == 1)
        #expect(fixture.history.count == 1)
    }

    @Test func localValidationAndCredentialRotationCannotConfirmStaleCopies() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        await fixture.server.set(remote: try fixture.matching())
        fixture.validationFileFailure = .changedFile
        let controller = fixture.controller()
        try await fixture.bind(controller)
        #expect(controller.results[fixture.id]?.status == .error(.localFileChanged))
        fixture.validationFileFailure = nil
        await fixture.server.rotate()
        controller.requestCheck()
        try await fixture.settle(controller)
        #expect(controller.results[fixture.id]?.status == .confirmed)
        #expect(controller.results[fixture.id]?.context?.accountID.hasSuffix((await fixture.server.accounts())[0].credentialID.uuidString) == true)
        #expect(fixture.delivered.map(\.kind) == [.error])
    }

    @Test func preferencesAreIndependentAndFailedSettingsCannotEmitEvents() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        let controller = fixture.controller()
        var preferences = DriveNotificationPreferences()
        preferences.errors = false
        preferences.confirmed = true
        try controller.setPreferences(preferences)
        await fixture.server.set(remote: try fixture.matching())
        try await fixture.bind(controller)
        #expect(fixture.delivered.map(\.kind) == [.confirmed])
        await fixture.server.set(remote: nil, problem: .accessDenied)
        controller.requestCheck()
        try await fixture.settle(controller)
        #expect(fixture.delivered.map(\.kind) == [.confirmed])
        let brokenURL = fixture.root.appendingPathComponent("directory-instead-of-file")
        try FileManager.default.createDirectory(at: brokenURL, withIntermediateDirectories: false)
        let broken = DriveVerificationController(settingsURL: brokenURL, environment: fixture.environment)
        await broken.start()
        await #expect(throws: DriveControllerFailure.settingsUnavailable) {
            try await broken.selectFolder(databaseID: fixture.id, accountID: (await fixture.server.accounts())[0].id, input: "root")
        }
        #expect(broken.bindings.isEmpty)
        #expect(fixture.delivered.map(\.kind) == [.confirmed])
    }

    @Test func rejectedConcurrentDisconnectPreservesTheOtherAccountBinding() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        let first = await fixture.server.account
        let second = GoogleDriveAccount(identity: try GoogleDriveIdentity(drivePermissionID: "second-account"), credentialID: UUID())
        let registry = DriveDisconnectGate(first: first, second: second)
        let base = fixture.environment
        let environment = DriveVerificationEnvironment(listAccounts: { await registry.list() }, connect: base.connect,
            cancelConnect: base.cancelConnect, disconnect: { try await registry.disconnect($0) }, resolveFolder: base.resolveFolder,
            remoteFile: base.remoteFile, localInputs: base.localInputs, deliver: base.deliver,
            cancelNotification: base.cancelNotification, history: base.history, clock: base.clock)
        let controller = DriveVerificationController(settingsURL: fixture.settingsURL, environment: environment)
        await controller.start()
        try await controller.selectFolder(databaseID: fixture.id, accountID: first.id, input: "root")
        try await fixture.settle(controller)
        let otherDatabase = UUID()
        try await controller.selectFolder(databaseID: otherDatabase, accountID: second.id, input: "root")
        try await fixture.settle(controller)
        let original = try #require(controller.bindings[otherDatabase])
        let disconnect = Task { try await controller.disconnect(accountID: first.id) }
        for _ in 0..<10_000 {
            if await registry.entered { break }
            await Task.yield()
        }
        try #require(await registry.entered)
        await #expect(throws: DriveControllerFailure.accountUnavailable) {
            try await controller.disconnect(accountID: second.id)
        }
        #expect(controller.bindings[otherDatabase] == original)
        #expect((await registry.list()).contains(second))
        controller.requestCheck()
        try await fixture.settle(controller)
        #expect(controller.results[fixture.id] == nil)
        #expect(fixture.history.filter { $0.kind == .error }.isEmpty)
        #expect(fixture.delivered.filter { $0.kind == .error }.isEmpty)
        var changedPreferences = controller.preferences
        changedPreferences.confirmed = true
        try controller.setPreferences(changedPreferences)
        await registry.release()
        try await disconnect.value
        #expect(controller.preferences == changedPreferences)
        #expect(controller.bindings[fixture.id] == nil)
        #expect(controller.bindings[otherDatabase] == original)
        let reopened = fixture.controller()
        #expect(reopened.bindings[otherDatabase] == original)
    }

    @Test func scheduledRecoveryCannotBecomeAnotherRecoveryAfterConfirmation() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        await fixture.server.set(remote: nil, problem: .providerUnavailable)
        let controller = fixture.controller()
        try await fixture.bind(controller)
        await fixture.server.set(remote: nil)
        controller.requestCheck()
        try await fixture.settle(controller)
        #expect(fixture.delivered.map(\.kind) == [.error, .recovery])
        await fixture.server.set(remote: try fixture.matching())
        controller.requestCheck()
        try await fixture.settle(controller)
        #expect(controller.results[fixture.id]?.status == .confirmed)
        #expect(fixture.delivered.map(\.kind) == [.error, .recovery])
    }

    enum ScheduledCancellation: CaseIterable { case database, preferences, account, content, error }

    @Test(arguments: ScheduledCancellation.allCases)
    func completedEnqueueRemainsCancellable(action: ScheduledCancellation) async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        await fixture.server.set(remote: try fixture.matching())
        let controller = fixture.controller()
        var preferences = DriveNotificationPreferences()
        preferences.confirmed = true
        try controller.setPreferences(preferences)
        try await fixture.bind(controller)
        let event = try #require(fixture.delivered.first)
        #expect(event.kind == .confirmed)
        switch action {
        case .database: try controller.disable(databaseID: fixture.id)
        case .preferences:
            preferences.confirmed = false
            try controller.setPreferences(preferences)
        case .account: try await controller.disconnect(accountID: (await fixture.server.accounts())[0].id)
        case .content: controller.localCopiesChanged()
        case .error:
            await fixture.server.set(remote: nil, problem: .providerUnavailable)
            controller.requestCheck()
            try await fixture.settle(controller)
        }
        #expect(fixture.cancelled.contains(event.id))
    }

    @Test func disableCancelsPersistedAlertsAndQuiesceCanResume() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        fixture.deliveryFails = true
        await fixture.server.set(remote: nil, problem: .providerUnavailable)
        let controller = fixture.controller()
        try await fixture.bind(controller)
        #expect(fixture.history.count == 1)
        try controller.disable(databaseID: fixture.id)
        #expect(!fixture.cancelled.isEmpty)
        #expect(controller.results.isEmpty)
        #expect(await controller.quiesceAndPersist())
        controller.resume()
        controller.resume()
        try await fixture.settle(controller)
        fixture.deliveryFails = false
        let restarted = fixture.controller()
        await restarted.start()
        restarted.requestCheck()
        try await fixture.settle(restarted)
        #expect(fixture.delivered.isEmpty)
    }

    @Test func pendingIsPublishedBeforeQueryAndRequestsCoalesce() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        let controller = fixture.controller()
        await fixture.server.setBlocked(true)
        await controller.start()
        try await controller.selectFolder(databaseID: fixture.id, accountID: (await fixture.server.accounts())[0].id, input: "root")
        try await fixture.awaitQuery()
        #expect(controller.results[fixture.id]?.status == .pending)
        #expect(controller.results[fixture.id]?.localSHA256 == fixture.fingerprint.sha256)
        for _ in 0..<30 { controller.requestCheck() }
        await fixture.server.release()
        try await fixture.settle(controller)
        #expect(await fixture.server.calls == 2)
    }

    @Test func folderResolutionCannotCommitAfterAccountCredentialRotation() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        let controller = fixture.controller()
        await controller.start()
        let accountID = (await fixture.server.accounts())[0].id
        await fixture.server.blockFolder()
        let selection = Task {
            try await controller.selectFolder(databaseID: fixture.id, accountID: accountID, input: "root")
        }
        try await fixture.awaitFolder()
        await fixture.server.rotate()
        await fixture.server.releaseFolder()
        await #expect(throws: DriveControllerFailure.accountUnavailable) { try await selection.value }
        #expect(controller.bindings.isEmpty)
        #expect(await fixture.server.calls == 0)
    }

    @Test func corruptionResetsOnceWithoutRestoringAnOldConfirmation() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        try Data("{\"version\":999}".utf8).write(to: fixture.settingsURL)
        let controller = fixture.controller()
        #expect(controller.failure == .invalidSavedState)
        #expect(controller.results.isEmpty)
        let restarted = fixture.controller()
        #expect(restarted.failure == nil)
        #expect(restarted.bindings.isEmpty)
    }

    @Test func cancelledConnectionDoesNotPublishAndDisconnectIsLocal() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        let controller = fixture.controller()
        await fixture.server.blockConnection()
        controller.connect()
        for _ in 0..<10_000 {
            if await fixture.server.connectionSuspended != nil { break }
            await Task.yield()
        }
        #expect(await fixture.server.connectionSuspended != nil)
        controller.cancelConnect()
        await fixture.server.releaseConnection()
        for _ in 0..<100 { await Task.yield() }
        #expect(!controller.isConnecting)
        #expect(controller.accounts.isEmpty)
        #expect(await fixture.server.connectionCancellations == 1)
        try await fixture.bind(controller)
        let calls = await fixture.server.calls
        try await controller.disconnect(accountID: controller.accounts[0].id)
        #expect(controller.accounts.isEmpty)
        #expect(controller.bindings.isEmpty)
        #expect(controller.results.isEmpty)
        #expect(await fixture.server.disconnects == 1)
        #expect(await fixture.server.calls == calls)
        #expect(DriveVerificationController.permissionURL.absoluteString == "https://myaccount.google.com/connections")
    }

    @Test func catalogAndSnapshotFailuresReplaceCurrentConfirmation() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        await fixture.server.set(remote: try fixture.matching())
        let controller = fixture.controller()
        try await fixture.bind(controller)
        fixture.catalogFailure = .invalidConfiguration
        controller.requestCheck()
        try await fixture.settle(controller)
        #expect(controller.results[fixture.id]?.status == .error(.invalidConfiguration))
        fixture.catalogFailure = nil
        fixture.localFailure = .localFileUnavailable
        controller.requestCheck()
        try await fixture.settle(controller)
        #expect(controller.results[fixture.id]?.status == .error(.localFileUnavailable))
        #expect(controller.results[fixture.id]?.lastConfirmedAt == 100)
    }

    @Test func olderQuiesceCannotPersistAfterResumeAndAnotherShutdown() async throws {
        let fixture = try DriveControllerFixture()
        defer { fixture.remove() }
        let controller = fixture.controller()
        try await fixture.bind(controller)
        await fixture.server.setBlocked(true)
        controller.requestCheck()
        try await fixture.awaitQuery()
        var firstStarted = false
        let first = Task { firstStarted = true; return await controller.quiesceAndPersist() }
        for _ in 0..<10_000 {
            if firstStarted { break }
            await Task.yield()
        }
        #expect(firstStarted)
        controller.resume()
        var secondStarted = false
        let second = Task { secondStarted = true; return await controller.quiesceAndPersist() }
        for _ in 0..<10_000 {
            if secondStarted { break }
            await Task.yield()
        }
        #expect(secondStarted)
        await fixture.server.release()
        #expect(await first.value == false)
        #expect(await second.value == true)
        #expect(!controller.isChecking)
    }
}
