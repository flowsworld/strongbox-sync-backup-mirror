import Combine
import Darwin
import Foundation
import SyncCopiesCore

struct DriveLocalSnapshot: Sendable {
    let fingerprint: UploadLocalFingerprint
    let validate: @Sendable () async throws -> Void
}

struct DriveLocalInput: Sendable {
    let id: UUID
    let name: String
    let filename: String
    let destinationID: String
    let makeSnapshot: @Sendable () async throws -> DriveLocalSnapshot
}

struct DriveVerificationBinding: Codable, Equatable, Sendable {
    let accountID: String
    let folderID: String
    let folderName: String
}

struct DriveNotificationPreferences: Codable, Equatable, Sendable {
    var errors = true
    var overdue = true
    var recoveries = true
    var confirmed = false

    func permits(_ kind: DriveVerificationEvent.Kind) -> Bool {
        switch kind {
        case .error: errors
        case .overdue: overdue
        case .recovery: recoveries
        case .confirmed: confirmed
        }
    }
}

struct DriveVerificationEvent: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable { case error, overdue, recovery, confirmed }
    let id: UUID
    let databaseID: UUID
    let databaseName: String
    let kind: Kind
    let problem: UploadVerificationFailure?
    let confirmed: Bool
}

enum DriveNotificationDelivery: Sendable { case delivered, permissionDenied }

enum DriveControllerFailure: Error, Equatable {
    case unavailable, busy, settingsUnavailable, invalidSavedState, accountUnavailable, folderUnavailable, connectionFailed

    var messageKey: String {
        switch self {
        case .unavailable: "Google Drive is not configured for this build."
        case .busy: "Wait for the current update preparation to finish."
        case .settingsUnavailable: "Google Drive settings could not be saved or read."
        case .invalidSavedState: "Invalid Google Drive verification settings were reset."
        case .accountUnavailable: "The Google Drive account is unavailable."
        case .folderUnavailable: "The Google Drive folder could not be verified."
        case .connectionFailed: "Google Drive sign-in could not be completed."
        }
    }
}

/// App-specific seams. Credentials remain behind Accounts, and delivery owns OS authorization.
struct DriveVerificationEnvironment {
    let listAccounts: @Sendable () async throws -> [GoogleDriveAccount]
    let connect: @Sendable () async throws -> GoogleDriveAccount
    let cancelConnect: @Sendable () async -> Void
    let disconnect: @Sendable (String) async throws -> Void
    let resolveFolder: @Sendable (String, String) async throws -> GoogleDriveFolder
    let remoteFile: @Sendable (String, String, String) async throws -> UploadRemoteFile?
    let localInputs: @MainActor () throws -> [DriveLocalInput]
    let deliver: @MainActor (DriveVerificationEvent) async throws -> DriveNotificationDelivery
    let cancelNotification: @MainActor (UUID) -> Void
    let history: @MainActor (DriveVerificationEvent) -> Void
    let clock: @MainActor () -> UInt64
    var credentialCleanupStatus: (@Sendable () async throws -> Bool)? = nil

    static func live(accounts: GoogleDriveAccounts, signIn: GoogleDriveSignIn, transport: GoogleDriveTransport,
                     localInputs: @escaping @MainActor () throws -> [DriveLocalInput],
                     deliver: @escaping @MainActor (DriveVerificationEvent) async throws -> DriveNotificationDelivery,
                     cancelNotification: @escaping @MainActor (UUID) -> Void,
                     history: @escaping @MainActor (DriveVerificationEvent) -> Void) -> Self {
        Self(listAccounts: { try await accounts.list() }, connect: {
            let result = try await signIn.authorize()
            try Task.checkCancellation()
            return try await accounts.save(identity: result.identity, tokens: result.tokens).account
        }, cancelConnect: { await signIn.cancel() }, disconnect: { id in
            _ = try await accounts.disconnect(accountID: id, revokeGoogleGrant: false)
        }, resolveFolder: { accountID, folderID in
            let token = try await accounts.accessToken(accountID: accountID)
            let data = try await transport.metadata(GoogleDriveMetadata.folderRequest(id: folderID), accessToken: token)
            return try GoogleDriveMetadata.resolveFolder(data, requestedID: folderID)
        }, remoteFile: { try await accounts.remoteFile(accountID: $0, folderID: $1, filename: $2) },
             localInputs: localInputs, deliver: deliver, cancelNotification: cancelNotification, history: history,
             clock: { UInt64(max(0, Date().timeIntervalSince1970)) },
             credentialCleanupStatus: { try await accounts.hasPendingCleanup() })
    }
}

/// Checks are serialized independently of copying. A generation invalidates every suspended result.
@MainActor
final class DriveVerificationController: ObservableObject {
    @Published private(set) var accounts: [GoogleDriveAccount] = []
    @Published private(set) var bindings: [UUID: DriveVerificationBinding] = [:]
    @Published private(set) var results: [UUID: UploadVerificationState] = [:]
    @Published private(set) var preferences = DriveNotificationPreferences()
    @Published private(set) var failure: DriveControllerFailure?
    @Published private(set) var isConnecting = false
    @Published private(set) var isChecking = false
    @Published private(set) var cleanupPending = false
    var isAvailable: Bool { environment != nil }
    var canChangeSettings: Bool { !stopped && !demo }
    static let permissionURL = URL(string: "https://myaccount.google.com/connections")!

    private let settingsURL: URL
    private let environment: DriveVerificationEnvironment?
    private let demo: Bool
    private var settings = Settings()
    private var generation: UInt64 = 0
    private var connectionGeneration: UInt64 = 0
    private var connectionTask: Task<Void, Never>?
    private var connectionCancellation: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var checkRequested = false
    @Published private var stopped = false
    private var mutations: [UUID: Task<Void, any Error>] = [:]
    private var activeDatabaseIDs: Set<UUID> = []
    private struct CurrentCopy {
        let context: UploadVerificationContext
        let sha256: String
    }
    private var validatedCopies: [UUID: CurrentCopy] = [:]
    // Successful enqueue removes the retry record before the OS displays its
    // delayed request. Keep bounded cancellation ownership until invalidated.
    private var scheduledAlerts: [UUID: [DriveVerificationEvent.Kind: DriveVerificationEvent]] = [:]

    init(settingsURL: URL, environment: DriveVerificationEnvironment?, demo: Bool = false) {
        self.settingsURL = settingsURL
        self.environment = demo ? nil : environment
        self.demo = demo
        if demo { return }
        do { settings = try Self.load(settingsURL) }
        catch let error as DriveControllerFailure {
            failure = error
            if error == .invalidSavedState {
                do { try Self.save(settings, to: settingsURL) }
                catch { failure = .settingsUnavailable }
            }
        }
        catch { failure = .invalidSavedState }
        publish()
    }

    func start() async {
        guard let environment, !stopped else { return }
        let captured = generation
        do {
            // Listing retries deferred credential removal, so shutdown must own and await it.
            try await performMutation {
                let loaded = try await environment.listAccounts()
                try Task.checkCancellation()
                let pending = try await environment.credentialCleanupStatus?() ?? false
                try Task.checkCancellation()
                guard captured == self.generation, !self.stopped else { return }
                self.accounts = loaded
                self.cleanupPending = pending
                if self.failure != .invalidSavedState { self.failure = nil }
            }
        } catch {
            guard captured == generation, !stopped, !Task.isCancelled else { return }
            failure = .accountUnavailable
        }
    }

    func connect() {
        guard let environment else { failure = .unavailable; return }
        guard !stopped, connectionTask == nil, connectionCancellation == nil else { return }
        connectionGeneration &+= 1
        let captured = connectionGeneration
        isConnecting = true
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await environment.connect()
                guard !Task.isCancelled, captured == connectionGeneration else { return }
                invalidateChecks()
                await start()
                requestCheck()
            } catch {
                if !Task.isCancelled, captured == connectionGeneration { failure = .connectionFailed }
            }
            guard captured == connectionGeneration else { return }
            isConnecting = false
            connectionTask = nil
        }
    }

    func cancelConnect() {
        // Stop may call this again while the original sign-in is still rolling back staged credentials.
        guard connectionCancellation == nil else { return }
        connectionGeneration &+= 1
        let captured = connectionGeneration
        let old = connectionTask
        connectionTask?.cancel()
        connectionTask = nil
        isConnecting = false
        if let environment {
            connectionCancellation = Task { [weak self] in
                await environment.cancelConnect()
                await old?.value
                guard let self, captured == connectionGeneration else { return }
                connectionCancellation = nil
            }
        }
    }

    /// Resolution must complete against the same account credential generation before saving a binding.
    func selectFolder(databaseID: UUID, accountID: String, input: String) async throws {
        try await performMutation {
            try await self.bindFolder(databaseID: databaseID, accountID: accountID, input: input)
        }
    }

    private func bindFolder(databaseID: UUID, accountID: String, input: String) async throws {
        guard let environment, !stopped else { throw DriveControllerFailure.unavailable }
        guard let account = accounts.first(where: { $0.id == accountID }) else { throw DriveControllerFailure.accountUnavailable }
        let folderID: String
        do { folderID = try GoogleDriveMetadata.folderID(from: input) }
        catch { throw DriveControllerFailure.folderUnavailable }
        invalidateChecks()
        let captured = generation
        let folder: GoogleDriveFolder
        do { folder = try await environment.resolveFolder(accountID, folderID) }
        catch { throw DriveControllerFailure.folderUnavailable }
        let current = try await environment.listAccounts()
        guard captured == generation, current.contains(account) else { throw DriveControllerFailure.accountUnavailable }
        var next = settings
        let oldEvents = next.records[databaseID]?.pending ?? []
        next.bindings[databaseID] = DriveVerificationBinding(accountID: accountID, folderID: folder.id, folderName: folder.name)
        next.records.removeValue(forKey: databaseID)
        try commit(next)
        oldEvents.forEach { environment.cancelNotification($0.id) }
        accounts = current
        requestCheck()
    }

    func disable(databaseID: UUID) throws {
        guard !stopped else { throw DriveControllerFailure.busy }
        invalidateChecks()
        var next = settings
        let pending = next.records[databaseID]?.pending ?? []
        next.bindings.removeValue(forKey: databaseID)
        next.records.removeValue(forKey: databaseID)
        try commit(next)
        if let environment { pending.forEach { environment.cancelNotification($0.id) } }
    }

    /// Stops checks locally before touching the account registry. Never revokes Google's grant implicitly.
    func disconnect(accountID: String) async throws {
        try await performMutation { try await self.disconnectAccount(accountID) }
    }

    private func disconnectAccount(_ accountID: String) async throws {
        guard let environment else { throw DriveControllerFailure.unavailable }
        invalidateChecks()
        var next = settings
        let ids = next.bindings.filter { $0.value.accountID == accountID }.map(\.key)
        let pending = ids.flatMap { next.records[$0]?.pending ?? [] }
        for id in ids { next.bindings.removeValue(forKey: id); next.records.removeValue(forKey: id) }
        try commit(next)
        pending.forEach { environment.cancelNotification($0.id) }
        do { try await environment.disconnect(accountID); await start() }
        catch { failure = .accountUnavailable; throw DriveControllerFailure.accountUnavailable }
    }

    func setPreferences(_ preferences: DriveNotificationPreferences) throws {
        guard !stopped else { throw DriveControllerFailure.busy }
        var next = settings
        next.preferences = preferences
        var removed: [DriveVerificationEvent] = []
        for id in Array(next.records.keys) {
            removed += next.records[id]!.pending.filter { !preferences.permits($0.kind) }
            next.records[id]!.pending.removeAll { !preferences.permits($0.kind) }
        }
        try commit(next)
        if let environment { removed.forEach { environment.cancelNotification($0.id) } }
        cancelScheduled { !preferences.permits($0.kind) }
    }

    /// Parent calls immediately when copy destinations/content or enabled local databases change.
    func localCopiesChanged() {
        invalidateChecks()
    }

    /// Timer, wake and completed local scans coalesce into one serialized worker.
    func requestCheck() {
        guard environment != nil, !stopped else { return }
        checkRequested = true
        guard checkTask == nil else { return }
        checkTask = Task { [weak self] in
            guard let self else { return }
            isChecking = true
            while checkRequested {
                checkRequested = false
                let captured = generation
                await checkAll(generation: captured)
                // Cancellation invalidates this run, not a newly requested run in the same worker.
                if Task.isCancelled { break }
            }
            checkTask = nil
            isChecking = false
            if checkRequested { requestCheck() }
        }
    }

    func stop() {
        stopped = true
        cancelConnect()
        invalidateChecks()
        checkRequested = false
        for task in mutations.values { task.cancel() }
    }

    /// Shutdown waits for owned network work to finish cancellation before making settings durable.
    func quiesceAndPersist() async -> Bool {
        let connection = connectionTask
        let check = checkTask
        let pendingMutations = Array(mutations.values)
        stop()
        let captured = generation
        let cancellation = connectionCancellation
        await connection?.value
        await cancellation?.value
        await check?.value
        // Each caller still receives its operation's error. Here only ownership
        // matters: no folder or account operation may outlive this stop gate.
        for task in pendingMutations { _ = await task.result }
        guard captured == generation, stopped, !Task.isCancelled else { return false }
        if demo { return true }
        do { try Self.save(settings, to: settingsURL); return true }
        catch { failure = .settingsUnavailable; return false }
    }

    func resume() {
        guard stopped else { return }
        stopped = false
        requestCheck()
    }

    private func performMutation(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        guard !stopped else { throw DriveControllerFailure.busy }
        try Task.checkCancellation()
        let id = UUID()
        let task = Task { try Task.checkCancellation(); try await operation() }
        mutations[id] = task
        defer { mutations.removeValue(forKey: id) }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func invalidateChecks() {
        generation &+= 1
        checkTask?.cancel()
        validatedCopies.removeAll()
        results = [:]
        cancelScheduled { _ in true }
        for record in settings.records.values {
            if let environment { record.pending.forEach { environment.cancelNotification($0.id) } }
        }
    }

    private func cancelScheduled(where shouldCancel: (DriveVerificationEvent) -> Bool) {
        for id in Array(scheduledAlerts.keys) {
            for event in scheduledAlerts[id]?.values.filter(shouldCancel) ?? [] {
                environment?.cancelNotification(event.id)
                scheduledAlerts[id]?.removeValue(forKey: event.kind)
            }
            if scheduledAlerts[id]?.isEmpty == true { scheduledAlerts.removeValue(forKey: id) }
        }
    }

    private func checkAll(generation captured: UInt64) async {
        guard let environment else { return }
        validatedCopies.removeAll()
        results = [:]
        let inputs: [DriveLocalInput]
        do {
            let current = try await environment.listAccounts()
            let pending = try await environment.credentialCleanupStatus?() ?? false
            guard captured == generation, !Task.isCancelled else { return }
            if current != accounts { accounts = current }
            cleanupPending = pending
            inputs = try environment.localInputs()
        } catch {
            guard captured == generation, !Task.isCancelled else { return }
            for id in settings.bindings.keys {
                await recordResult(id: id, name: "Database", context: nil, local: nil,
                                   outcome: .failure(Self.problem(error)), generation: captured)
            }
            return
        }
        // An input is present only while its local database and copy selection are enabled.
        let active = Set(inputs.map(\.id))
        activeDatabaseIDs = active
        cancelScheduled { !active.contains($0.databaseID) }
        publish()
        for input in inputs {
            guard captured == generation, !Task.isCancelled else { return }
            guard let binding = settings.bindings[input.id] else { continue }
            let context: UploadVerificationContext
            do {
                guard let account = accounts.first(where: { $0.id == binding.accountID }) else {
                    throw UploadVerificationFailure.credentialsUnavailable
                }
                context = try UploadVerificationContext(providerID: "google-drive",
                    accountID: account.id + ":" + account.credentialID.uuidString,
                    folderID: binding.folderID, filename: input.filename, destinationID: input.destinationID)
            } catch {
                await recordResult(id: input.id, name: input.name, context: nil, local: nil,
                                   outcome: .failure(Self.problem(error)), generation: captured)
                continue
            }
            var snapshot: DriveLocalSnapshot?
            do {
                snapshot = try await input.makeSnapshot()
                guard captured == generation, !Task.isCancelled, let snapshot else { return }
                validatedCopies[input.id] = CurrentCopy(context: context, sha256: snapshot.fingerprint.sha256)
                let previous = settings.records[input.id]?.state
                if previous?.context != context || previous?.localSHA256 != snapshot.fingerprint.sha256 {
                    let pending = UploadVerification.evaluate(context: context, local: snapshot.fingerprint,
                                                               outcome: .missing, now: environment.clock())
                    var next = settings
                    let old = next.records[input.id]?.pending ?? []
                    var reset = Record(state: pending)
                    reset.awaitingFirstQuery = true
                    // A content replacement does not turn the same provider problem into a new error alert.
                    if previous?.context == context {
                        reset.errorKey = next.records[input.id]?.errorKey
                        reset.pending = old.filter { $0.kind == .error }
                    }
                    next.records[input.id] = reset
                    results[input.id] = pending
                    try commit(next)
                    old.forEach { environment.cancelNotification($0.id) }
                    cancelScheduled { $0.databaseID == input.id }
                }
                publish()
                let remote = try await environment.remoteFile(binding.accountID, binding.folderID, input.filename)
                let currentAccounts = try await environment.listAccounts()
                guard captured == generation, !Task.isCancelled else { return }
                guard currentAccounts == accounts else { localCopiesChanged(); requestCheck(); return }
                // Account cleanup may suspend. Validate the held local file only
                // after that lookup, immediately before publishing the observation.
                try await snapshot.validate()
                guard captured == generation, !Task.isCancelled else { return }
                await recordResult(id: input.id, name: input.name, context: context, local: snapshot.fingerprint,
                                   outcome: remote.map(UploadCheckOutcome.file) ?? .missing, generation: captured)
            } catch {
                guard captured == generation, !Task.isCancelled else { return }
                await recordResult(id: input.id, name: input.name, context: context, local: snapshot?.fingerprint,
                                   outcome: .failure(Self.problem(error)), generation: captured)
            }
        }
    }

    private func recordResult(id: UUID, name: String, context: UploadVerificationContext?, local: UploadLocalFingerprint?,
                              outcome: UploadCheckOutcome, generation captured: UInt64) async {
        guard let environment, captured == generation, !Task.isCancelled, settings.bindings[id] != nil else { return }
        let previous = settings.records[id]
        let observedPrevious = previous?.awaitingFirstQuery == true ? nil : previous?.state
        let state = UploadVerification.evaluate(previous: observedPrevious, context: context, local: local,
                                                outcome: outcome, now: environment.clock())
        var record = previous ?? Record(state: state)
        record.state = state
        record.awaitingFirstQuery = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let contextKey = (try? encoder.encode(state.context)).map { $0.base64EncodedString() } ?? "unknown"
        let contentKey = contextKey + ":" + (state.localSHA256 ?? "unknown")
        let newConfirmation = record.confirmedKey != contentKey
        let recovering = record.errorKey != nil
        var kind: DriveVerificationEvent.Kind?
        var problem: UploadVerificationFailure?
        let confirmed = state.status == .confirmed
        switch state.status {
        case .error(let code):
            problem = code
            let key = contextKey + ":" + code.rawValue
            if record.errorKey != key { kind = .error; record.errorKey = key }
        case .overdue:
            if recovering { kind = .recovery }
            else if record.overdueKey != contentKey { kind = .overdue }
            record.overdueKey = contentKey
            record.errorKey = nil
        case .pending:
            if recovering { kind = .recovery }
            record.errorKey = nil
            record.overdueKey = nil
        case .confirmed:
            if recovering { kind = .recovery }
            else if record.confirmedKey != contentKey { kind = .confirmed }
            record.confirmedKey = contentKey
            record.errorKey = nil
            record.overdueKey = nil
        }
        // An alert queued during an older status must never appear after recovery or new content.
        let scheduled = scheduledAlerts[id].map { Array($0.values) } ?? []
        let obsolete = (record.pending + scheduled).filter { event in
            switch event.kind {
            case .error:
                if case .error(let current) = state.status { return event.problem != current }
                return true
            case .overdue: return state.status != .overdue
            case .confirmed: return !confirmed
            case .recovery:
                if case .error = state.status { return true }
                return event.confirmed != confirmed
            }
        }
        record.pending.removeAll { event in obsolete.contains(where: { $0.id == event.id }) }
        if obsolete.contains(where: { $0.kind == .recovery }) {
            // Retry a recovery using its current confirmation fact, never the old queued wording.
            switch state.status {
            case .error: break
            default: if kind == nil || kind == .confirmed { kind = .recovery }
            }
        }
        let event = kind.map { DriveVerificationEvent(id: UUID(), databaseID: id, databaseName: name,
                                                     kind: $0, problem: problem, confirmed: confirmed) }
        if let event {
            if settings.preferences.permits(event.kind) { record.pending.append(event) }
            else if event.kind == .recovery, confirmed, newConfirmation, settings.preferences.confirmed {
                record.pending.append(DriveVerificationEvent(id: event.id, databaseID: id, databaseName: name,
                                                            kind: .confirmed, problem: nil, confirmed: true))
            }
        }
        var next = settings
        next.records[id] = record
        // Even a persistence failure must not leave a historical confirmation displayed as current.
        if activeDatabaseIDs.contains(id) { results[id] = state }
        do { try commit(next) }
        catch { failure = .settingsUnavailable; return }
        obsolete.forEach { environment.cancelNotification($0.id) }
        cancelScheduled { event in obsolete.contains(where: { $0.id == event.id }) }
        if let event { environment.history(event) }
        await deliverPending(id: id, generation: captured)
    }

    private func deliverPending(id: UUID, generation captured: UInt64) async {
        guard let environment else { return }
        for event in settings.records[id]?.pending ?? [] {
            guard captured == generation, !Task.isCancelled else { return }
            do {
                let delivery = try await environment.deliver(event)
                guard captured == generation, !Task.isCancelled else { environment.cancelNotification(event.id); return }
                if delivery == .delivered {
                    if let previous = scheduledAlerts[id]?[event.kind], previous.id != event.id {
                        environment.cancelNotification(previous.id)
                    }
                    scheduledAlerts[id, default: [:]][event.kind] = event
                }
                // Permission denial consumes the event too. It must not be replayed after later authorization.
                var next = settings
                next.records[id]?.pending.removeAll { $0.id == event.id }
                try commit(next)
            } catch {
                guard captured == generation, !Task.isCancelled else { environment.cancelNotification(event.id); return }
                // A delivery failure stays in the persisted queue for the next scheduled check.
            }
        }
    }

    private func commit(_ next: Settings) throws {
        do { if !demo { try Self.save(next, to: settingsURL) } }
        catch { failure = .settingsUnavailable; throw DriveControllerFailure.settingsUnavailable }
        settings = next
        failure = nil
        publish()
    }

    private func publish() {
        bindings = settings.bindings
        preferences = settings.preferences
        results = settings.records.filter { id, record in
            guard settings.bindings[id] != nil, activeDatabaseIDs.contains(id) else { return false }
            guard record.state.status == .confirmed else { return true }
            guard let current = validatedCopies[id] else { return false }
            return current.context == record.state.context && current.sha256 == record.state.localSHA256
        }.mapValues(\.state)
    }

    private static func problem(_ error: any Error) -> UploadVerificationFailure {
        if let error = error as? UploadVerificationFailure { return error }
        if let error = error as? GoogleDriveAccountFailure {
            switch error {
            case .credentialsDenied: return .accessDenied
            default: return .credentialsUnavailable
            }
        }
        if let error = error as? GoogleDriveTransportFailure {
            switch error {
            case .accessDenied: return .accessDenied
            case .authorizationRejected, .invalidAccessToken: return .credentialsUnavailable
            case .invalidResponse, .responseTooLarge, .redirect: return .invalidRemoteMetadata
            case .disallowedRequest: return .invalidConfiguration
            default: return .providerUnavailable
            }
        }
        if error is GoogleDriveOAuthFailure { return .credentialsUnavailable }
        if error is GoogleDriveMetadataError { return .invalidRemoteMetadata }
        if let error = error as? MirrorError { return error == .changedFile ? .localFileChanged : .localFileUnavailable }
        return .providerUnavailable
    }

    private struct Record: Codable {
        var state: UploadVerificationState
        var errorKey: String?
        var overdueKey: String?
        var confirmedKey: String?
        var awaitingFirstQuery: Bool?
        var pending: [DriveVerificationEvent] = []
    }

    private struct Settings: Codable {
        var version = 1
        var preferences = DriveNotificationPreferences()
        var bindings: [UUID: DriveVerificationBinding] = [:]
        var records: [UUID: Record] = [:]
    }

    private static func load(_ url: URL) throws -> Settings {
        guard url.isFileURL else { throw DriveControllerFailure.settingsUnavailable }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return Settings() }
            throw DriveControllerFailure.settingsUnavailable
        }
        defer { close(descriptor) }
        var stamp = stat()
        guard fstat(descriptor, &stamp) == 0, stamp.st_mode & S_IFMT == S_IFREG,
              stamp.st_size >= 0, stamp.st_size <= 1_048_576 else { throw DriveControllerFailure.invalidSavedState }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw DriveControllerFailure.settingsUnavailable }
            if count == 0 { break }
            guard data.count + count <= 1_048_576 else { throw DriveControllerFailure.invalidSavedState }
            data.append(contentsOf: buffer.prefix(count))
        }
        let settings: Settings
        do { settings = try JSONDecoder().decode(Settings.self, from: data) }
        catch { throw DriveControllerFailure.invalidSavedState }
        guard settings.version == 1, settings.bindings.count <= 1000, settings.records.count <= 1000 else {
            throw DriveControllerFailure.invalidSavedState
        }
        for binding in settings.bindings.values {
            guard binding.accountID.hasPrefix("google-drive:"), binding.accountID.utf8.count <= 512,
                  !binding.folderName.isEmpty, binding.folderName.unicodeScalars.count <= 1024,
                  (try? GoogleDriveMetadata.folderID(from: binding.folderID)) == binding.folderID else {
                throw DriveControllerFailure.invalidSavedState
            }
        }
        for (id, record) in settings.records {
            guard settings.bindings[id] != nil, record.pending.count <= 16,
                  Set(record.pending.map(\.id)).count == record.pending.count,
                  record.pending.allSatisfy({ $0.databaseID == id && $0.databaseName.utf8.count <= 4096 }) else {
                throw DriveControllerFailure.invalidSavedState
            }
        }
        return settings
    }

    private static func save(_ settings: Settings, to url: URL) throws {
        guard url.isFileURL else { throw DriveControllerFailure.settingsUnavailable }
        let data = try JSONEncoder().encode(settings)
        guard data.count <= 1_048_576 else { throw DriveControllerFailure.settingsUnavailable }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var template = Array(directory.appendingPathComponent(".drive-settings-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw DriveControllerFailure.settingsUnavailable }
        let temporary = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        defer { close(descriptor); unlink(temporary) }
        guard fchmod(descriptor, 0o600) == 0 else { throw DriveControllerFailure.settingsUnavailable }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw DriveControllerFailure.settingsUnavailable }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, rename(temporary, url.path) == 0 else { throw DriveControllerFailure.settingsUnavailable }
        let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw DriveControllerFailure.settingsUnavailable }
        defer { close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else { throw DriveControllerFailure.settingsUnavailable }
    }
}
