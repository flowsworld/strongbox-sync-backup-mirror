import AppKit
import Foundation
import CryptoKit
import Darwin
import SyncCopiesCore

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, databases, notifications, googleDrive, history, info
    var id: Self { self }
    var title: String {
        switch self {
        case .general: L10n.text("General")
        case .databases: L10n.text("Databases")
        case .notifications: L10n.text("Notifications")
        case .googleDrive: L10n.text("Google Drive")
        case .history: L10n.text("History")
        case .info: L10n.text("Info")
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .databases: "externaldrive"
        case .notifications: "bell"
        case .googleDrive: "checkmark.icloud"
        case .history: "clock"
        case .info: "info.circle"
        }
    }
}

struct DatabasePreferences: Codable, Sendable {
    var enabled = false
    var target: Data?
    var lastCopied: Date?
    var lastReconciled: Date?
    var lastFailure: LocalizedMessage?
}

struct NotificationPreferences: Codable, Sendable {
    var failures = true
    var copies = false
    var recoveries = false
}

struct HistoryEntry: Codable, Identifiable, Sendable {
    var id = UUID()
    let date: Date
    let databaseID: UUID?
    let name: String
    let message: LocalizedMessage
    let isError: Bool
    var displayName: String { databaseID == nil && name == "App" ? L10n.appName : name }
}

struct Preferences: Codable, Sendable {
    var source: Data?
    var defaultTarget: Data?
    var databases: [String: DatabasePreferences] = [:]
    var notifications = NotificationPreferences()
    var history: [HistoryEntry] = []
    var globalFailure: LocalizedMessage?
}

private struct PendingNotification {
    let kind: WritableKeyPath<NotificationPreferences, Bool>
    let title: String
    let body: String
    let databaseID: String?
}

struct DatabaseState: Sendable {
    var checked: Date?
    var backup: BackupInfo?
    var targetName: String?
    var error: LocalizedMessage?
    var copied = false
}

enum SourceReadStatus: Sendable, Equatable {
    case notGranted, checking, available, unavailable, unconfirmed

    var title: String {
        switch self {
        case .notGranted: L10n.text("Read access required")
        case .checking: L10n.text("Checking read access…")
        case .available: L10n.text("Read access allowed")
        case .unavailable: L10n.text("Read access failed")
        case .unconfirmed: L10n.text("Read access not confirmed yet")
        }
    }
}

private struct SourceScanFailure: LocalizedError, LocalizedMessageError, Sendable {
    let message: LocalizedMessage
    let sourcePath: String?
    let readStatus: SourceReadStatus
    var errorDescription: String? { message.rendered() }
}

private struct ScanResult: Sendable {
    let sourcePath: String
    let folderPaths: [Data: String]
    let sourcePermissionDenied: Bool
    let databases: [Database]
    let states: [UUID: DatabaseState]
}

enum ConfigurationError: LocalizedError, LocalizedMessageError {
    case missingTarget, collidingDestination
    var errorDescription: String? { message.rendered() }

    var message: LocalizedMessage {
        switch self {
        case .missingTarget: LocalizedMessage(key: "Choose a shared or individual destination folder.")
        case .collidingDestination: LocalizedMessage(key: "Multiple databases would replace the same destination file. Choose different destination folders.")
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let isDemo: Bool
    let isSetupPreview: Bool
    @Published private(set) var preferences = Preferences()
    @Published private(set) var databases: [Database] = []
    @Published private(set) var states: [UUID: DatabaseState] = [:]
    @Published private(set) var isChecking = false
    @Published private(set) var sourceReadStatus: SourceReadStatus = .notGranted
    @Published private var folderPaths: [Data: String] = [:]
    @Published private(set) var problem: String?
    @Published private(set) var notificationStatus = L10n.text("Not requested")
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginNeedsApproval = false
    @Published var page: SettingsPage = .databases
    @Published var expandedDatabases: Set<UUID> = []

    private let environment: AppEnvironment?
    private let folderMounts: @Sendable () -> [FolderPathDisplay.Mount]
    private var notifications: NotificationService? { environment?.notifications }
    private(set) var startupConflict = false
    private(set) var isStopping = false
    private var instanceLock: InstanceLock?
    private var scanTask: Task<Void, Never>?
    var onOpenSettings: (() -> Void)?
    var onLocalScanStarted: (() -> Void)?
    var onLocalScanComplete: (() -> Void)?
    private let preferencesURL: URL
    private var persistenceFailed = false
    private var loadFailed = false
    private var pendingNotifications: [PendingNotification] = []
    private var scanAgain = false
    private var generation = 0
    private var updatePreparationGeneration = 0
    private var isTerminating = false
    private var sourceScope: FolderAccess?
    private var monitoredPaths: Set<String> = []
    private var monitor: FileMonitor?
    private var notificationAttemptRunning = false
    private var notificationRevisions: [WritableKeyPath<NotificationPreferences, Bool>: Int] = [:]

    init(demo: Bool = false, setupPreview: Bool = false, environment suppliedEnvironment: AppEnvironment? = nil, folderMounts: @escaping @Sendable () -> [FolderPathDisplay.Mount] = FolderPathDisplay.mountedSMBFolders) {
        isDemo = demo
        isSetupPreview = demo && setupPreview
        self.folderMounts = folderMounts
        environment = demo ? nil : (suppliedEnvironment ?? AppEnvironment.live())
        preferencesURL = environment?.preferencesURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SyncCopies/preferences.json")
        if isSetupPreview {
            page = .general
            notificationStatus = L10n.text("Preview with sample data")
            return
        }
        if demo {
            let privateDB = Database(id: UUID(), filename: "Personal.kdbx", displayName: L10n.text("Personal"))
            let workDB = Database(id: UUID(), filename: "Work.kdbx", displayName: L10n.text("Work"))
            let clubDB = Database(id: UUID(), filename: "Club.kdbx", displayName: L10n.text("Club"))
            databases = [privateDB, workDB, clubDB]
            preferences.databases[privateDB.id.uuidString] = DatabasePreferences(enabled: true, lastCopied: Date().addingTimeInterval(-240))
            preferences.databases[workDB.id.uuidString] = DatabasePreferences(enabled: true, target: Data(), lastCopied: Date().addingTimeInterval(-7200))
            states[privateDB.id] = DatabaseState(checked: Date(), targetName: "/Users/Beispiel/Google Drive/Lesekopien")
            states[workDB.id] = DatabaseState(checked: Date(), targetName: "/Volumes/NAS/Lesekopien", error: LocalizedMessage(key: "The destination folder is unreachable. Connect the NAS."))
            preferences.history = [HistoryEntry(date: Date(), databaseID: workDB.id, name: L10n.text("Work"), message: LocalizedMessage(key: "Destination unreachable"), isError: true), HistoryEntry(date: Date().addingTimeInterval(-240), databaseID: privateDB.id, name: L10n.text("Personal"), message: LocalizedMessage(key: "New copy created"), isError: false)]
            sourceReadStatus = .available
            notificationStatus = L10n.text("Preview with sample data")
            return
        }
        do {
            try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            instanceLock = try InstanceLock(url: preferencesURL.deletingLastPathComponent().appendingPathComponent(".instance.lock"))
        } catch {
            startupConflict = (error as? InstanceLockError) == .alreadyRunning
            loadFailed = true
            problem = LocalizedMessage.from(error).rendered()
            return
        }
        do {
            if FileManager.default.fileExists(atPath: preferencesURL.path) {
                preferences = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: preferencesURL))
            }
        } catch {
            loadFailed = true
            persistenceFailed = true
            problem = L10n.format("Saved settings could not be read. %@", LocalizedMessage.from(error).rendered())
        }
        if needsSetup { page = .general }
        notifications?.discardStaleRequests()
        monitor = FileMonitor { [weak self] in
            self?.monitoredPaths = []
            self?.refresh()
        }
        notifications?.onSelectDatabase = { [weak self] id in
            self?.page = .databases
            if let uuid = UUID(uuidString: id) { self?.expandedDatabases.insert(uuid) }
            self?.onOpenSettings?()
        }
        guard let environment else { return }
        let login = environment.loginStatus()
        loginEnabled = login.enabled
        loginNeedsApproval = login.needsApproval
        environment.scheduler.start { [weak self] in self?.refresh() }
        Task { await updateNotificationStatus() }
        rememberTargetPaths()
        if let source = preferences.source { rememberBookmarkPath(source, mounts: folderMounts()) }
        refresh()
    }

    var needsSetup: Bool {
        isSetupPreview || (!isDemo && !preferences.databases.values.contains { $0.enabled && ($0.lastReconciled != nil || $0.lastCopied != nil) })
    }
    var activeCount: Int { databases.filter { preference(for: $0).enabled }.count }
    // A saved bookmark enables retrying; sourceReadStatus describes actual read access.
    var sourceGranted: Bool { (isDemo && !isSetupPreview) || preferences.source != nil }
    var commonTargetName: String { isDemo && !isSetupPreview ? "/Users/Beispiel/Google Drive/Lesekopien" : label(for: preferences.defaultTarget) }
    var sourceFolderPath: String { isDemo && !isSetupPreview ? "/Users/Beispiel/Library/Group Containers/group.strongbox.mac.mcguill" : label(for: preferences.source) }
    var canChooseSource: Bool {
        !isDemo && !isChecking && !isStopping && !loadFailed &&
        (sourceReadStatus != .available || preferences.globalFailure != nil)
    }
    func targetFolderPath(for database: Database) -> String {
        if isDemo { return states[database.id]?.targetName ?? commonTargetName }
        return label(for: preference(for: database).target ?? preferences.defaultTarget)
    }
    var failureCount: Int { states.values.filter { $0.error != nil }.count }
    func preference(for database: Database) -> DatabasePreferences {
        preferences.databases[database.id.uuidString] ?? DatabasePreferences()
    }
    func label(for bookmark: Data?) -> String {
        guard let bookmark else { return L10n.text("No folder selected") }
        return folderPaths[bookmark] ?? L10n.text("Folder path unavailable")
    }

    private func rememberBookmarkPath(_ bookmark: Data, mounts: [FolderPathDisplay.Mount]) {
        // Resolving a path for display neither starts a security scope nor proves read access.
        var stale = false
        if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
            folderPaths[bookmark] = FolderPathDisplay.label(for: url.path, mounts: mounts, previous: folderPaths[bookmark])
        }
    }

    private func rememberTargetPaths() {
        guard let environment else { return }
        let mounts = folderMounts()
        let targets = [preferences.defaultTarget] + preferences.databases.values.map(\.target)
        for bookmark in targets.compactMap({ $0 }) {
            // This cache is best effort. The scan reports access failures for enabled targets.
            if let folder = try? environment.resolveFolder(bookmark) {
                folderPaths[bookmark] = FolderPathDisplay.label(for: folder.url.path, mounts: mounts, previous: folderPaths[bookmark])
            } else { rememberBookmarkPath(bookmark, mounts: mounts) }
        }
    }

    func chooseSource() {
        guard canChooseSource else { return }
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser
            // passwd provides the actual home rather than the app's sandbox home.
            let userHome = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir)) } ?? home
            guard let bookmark = try FolderPicker.choose(
                title: L10n.text("Allow Strongbox access"),
                message: L10n.text("Allow read access to Strongbox's local backups and database names."),
                initialURL: userHome.appendingPathComponent("Library/Group Containers/group.strongbox.mac.mcguill"),
                readOnly: true
            ) else { return }
            preferences.source = bookmark
            invalidateCloudCopies()
            rememberBookmarkPath(bookmark, mounts: folderMounts())
            sourceReadStatus = .notGranted
            generation += 1
            sourceScope = nil
            monitoredPaths = []
            monitor?.stop()
            if save() { refresh() }
        } catch { problem = LocalizedMessage.from(error).rendered() }
    }

    func chooseTarget(for database: Database? = nil) {
        guard !isDemo, !isChecking, !isStopping, !loadFailed else { return }
        do {
            guard let bookmark = try FolderPicker.choose(
                title: L10n.text("Choose destination folder"), message: L10n.text("Choose an existing folder for the read-only copies."), readOnly: false
            ) else { return }
            if let database {
                var item = preference(for: database)
                item.target = bookmark
                preferences.databases[database.id.uuidString] = item
            } else { preferences.defaultTarget = bookmark }
            invalidateCloudCopies()
            rememberTargetPaths()
            generation += 1
            if save() { refresh() }
        } catch { problem = LocalizedMessage.from(error).rendered() }
    }

    func useCommonTarget(for database: Database) {
        guard !isDemo, !isChecking, !isStopping, !loadFailed else { return }
        var item = preference(for: database)
        item.target = nil
        preferences.databases[database.id.uuidString] = item
        invalidateCloudCopies()
        generation += 1
        if save() { refresh() }
    }

    func setEnabled(_ enabled: Bool, for database: Database) {
        guard !isDemo, !isChecking, !isStopping, !loadFailed else { return }
        var item = preference(for: database)
        item.enabled = enabled
        if !enabled {
            item.lastFailure = nil
            pendingNotifications.removeAll { $0.databaseID == database.id.uuidString }
        }
        preferences.databases[database.id.uuidString] = item
        invalidateCloudCopies()
        generation += 1
        if save() { refresh() }
    }

    func setNotification(_ key: WritableKeyPath<NotificationPreferences, Bool>, to value: Bool) {
        guard !isStopping, !loadFailed else { return }
        preferences.notifications[keyPath: key] = value
        if !value {
            notificationRevisions[key, default: 0] += 1
            notifications?.cancelPending(kind: key)
        }
        pendingNotifications.removeAll { !preferences.notifications[keyPath: $0.kind] }
        guard save() else { return }
        if value, !isDemo, let notifications {
            Task {
                do { try await notifications.requestAuthorization() }
                catch { problem = LocalizedMessage.from(error).rendered() }
                await updateNotificationStatus()
            }
        }
    }

    func requestNotifications() {
        guard !isDemo, !isStopping, let notifications else { return }
        Task {
            do { try await notifications.requestAuthorization() }
            catch { problem = LocalizedMessage.from(error).rendered() }
            await updateNotificationStatus()
        }
    }

    func testNotification() {
        guard !isDemo, !isStopping, let notifications else { return }
        Task {
            do {
                try await notifications.requestAuthorization()
                try await notifications.send(title: L10n.appName, body: L10n.text("Test notification. No file was copied."), databaseID: nil)
            } catch { problem = LocalizedMessage.from(error).rendered() }
            await updateNotificationStatus()
        }
    }

    func setLogin(_ enabled: Bool) {
        guard !isDemo, !isStopping, !loadFailed, let environment else { return }
        do { try environment.setLogin(enabled) }
        catch { problem = LocalizedMessage.from(error).rendered() }
        let login = environment.loginStatus()
        loginEnabled = login.enabled
        loginNeedsApproval = login.needsApproval
    }

    private func save(durable: Bool = false) -> Bool {
        if isDemo { return true }
        guard !loadFailed else { return false }
        preferences.history = Array(preferences.history.prefix(200))
        do {
            try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(preferences)
            try data.write(to: preferencesURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preferencesURL.path)
            if durable { try synchronizeSettings() }
            persistenceFailed = false
            return true
        } catch {
            persistenceFailed = true
            problem = L10n.format("Settings could not be saved. %@", LocalizedMessage.from(error).rendered())
            return false
        }
    }

    /// Quiesce copies without releasing the instance lock or folder grants. A
    /// failed durable save cancels installation and restores normal scheduling.
    func prepareForUpdate() async -> Bool {
        if isDemo || isTerminating { return false }
        updatePreparationGeneration += 1
        let preparation = updatePreparationGeneration
        isStopping = true
        environment?.scheduler.stop()
        monitor?.stop()
        monitoredPaths = []
        scanAgain = false
        await scanTask?.value
        guard !Task.isCancelled, preparation == updatePreparationGeneration else { return false }
        guard save(durable: true) else {
            resumeAfterCancelledUpdate()
            return false
        }
        return true
    }

    func resumeAfterCancelledUpdate() {
        guard isStopping, !isTerminating else { return }
        updatePreparationGeneration += 1
        isStopping = false
        monitoredPaths = []
        environment?.scheduler.start { [weak self] in self?.refresh() }
        armMonitor()
        refresh()
    }

    private func synchronizeSettings() throws {
        for (url, flags) in [(preferencesURL, O_RDONLY), (preferencesURL.deletingLastPathComponent(), O_RDONLY | O_DIRECTORY)] {
            let descriptor = open(url.path, flags | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { _ = close(descriptor) }
            while fsync(descriptor) != 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    func quiesceForTermination() async {
        isTerminating = true
        updatePreparationGeneration += 1
        isStopping = true
        environment?.scheduler.stop()
        monitor?.stop()
        monitoredPaths = []
        scanAgain = false
        await scanTask?.value
    }

    func persistForUpdateTermination() -> Bool {
        isStopping && save(durable: true)
    }

    func cancelTermination() {
        isTerminating = false
        resumeAfterCancelledUpdate()
    }

    func completeShutdown() {
        guard isStopping else { return }
        sourceScope = nil
        instanceLock = nil
    }

    func shutdown() async {
        await quiesceForTermination()
        completeShutdown()
    }

    func refresh() {
        guard !isDemo, !isStopping, let environment else { return }
        guard !loadFailed, let bookmark = preferences.source else { return }
        if persistenceFailed, !save() { return }
        guard !isChecking else { scanAgain = true; return }
        isChecking = true
        onLocalScanStarted?()
        sourceReadStatus = .checking
        let snapshot = preferences
        let previousPaths = folderPaths
        let folderMounts = folderMounts
        let currentGeneration = generation
        scanTask = Task {
            do {
                let result = try await Task.detached(priority: .utility) { try Self.scan(bookmark, preferences: snapshot, previousPaths: previousPaths, mounts: folderMounts(), resolveFolder: environment.resolveFolder) }.value
                guard currentGeneration == generation else {
                    isChecking = false
                    scanTask = nil
                    refresh()
                    return
                }
                sourceReadStatus = result.sourcePermissionDenied ? .unavailable : .available
                folderPaths[bookmark] = result.sourcePath
                folderPaths.merge(result.folderPaths) { _, latest in latest }
                databases = result.databases
                states = result.states
                for database in databases {
                    if states[database.id]?.targetName == nil, states[database.id] != nil {
                        states[database.id]?.targetName = targetFolderPath(for: database)
                    }
                }
                if !persistenceFailed { problem = nil }
                let recoveredSource = preferences.globalFailure != nil
                preferences.globalFailure = nil
                let enabledIDs = Set(databases.filter { preference(for: $0).enabled }.map { $0.id.uuidString })
                pendingNotifications.removeAll { $0.databaseID.map { !enabledIDs.contains($0) } ?? ($0.kind == \.failures) }
                if recoveredSource {
                    preferences.history.insert(HistoryEntry(date: Date(), databaseID: nil, name: "Strongbox", message: LocalizedMessage(key: "Read access is working again"), isError: false), at: 0)
                    if preferences.notifications.recoveries { pendingNotifications.append(PendingNotification(kind: \.recoveries, title: L10n.text("Strongbox: Error resolved"), body: L10n.text("Local backups can be checked again."), databaseID: nil)) }
                }
                for database in databases where preference(for: database).enabled {
                    guard let state = states[database.id] else { continue }
                    if let failure = state.error {
                        if preference(for: database).lastFailure != failure {
                            record(database, message: failure, isError: true)
                            if preferences.notifications.failures { queueNotification(database, kind: \.failures, title: L10n.format("%@ could not be copied", database.displayName), body: failure.rendered()) }
                        }
                        preferences.databases[database.id.uuidString, default: DatabasePreferences()].lastFailure = failure
                    } else {
                        preferences.databases[database.id.uuidString, default: DatabasePreferences()].lastReconciled = state.checked
                        pendingNotifications.removeAll { $0.databaseID == database.id.uuidString && $0.kind == \.failures }
                        if preference(for: database).lastFailure != nil {
                            preferences.databases[database.id.uuidString, default: DatabasePreferences()].lastFailure = nil
                            record(database, message: LocalizedMessage(key: "Error resolved"), isError: false)
                            if preferences.notifications.recoveries { queueNotification(database, kind: \.recoveries, title: L10n.format("%@: Error resolved", database.displayName), body: L10n.text("The read-only copy can be updated again.")) }
                        }
                        if state.copied {
                            preferences.databases[database.id.uuidString, default: DatabasePreferences()].lastCopied = state.checked
                            record(database, message: LocalizedMessage(key: "New copy created"), isError: false)
                            if preferences.notifications.copies { queueNotification(database, kind: \.copies, title: L10n.format("%@ was copied", database.displayName), body: L10n.text("The new read-only copy is in the selected destination folder.")) }
                        }
                    }
                }
                _ = save()
                if !isStopping { armMonitor() }
            } catch {
                if let failure = error as? SourceScanFailure {
                    sourceReadStatus = failure.readStatus
                    if let path = failure.sourcePath { folderPaths[bookmark] = path }
                } else {
                    // Errors after the catalog was read, such as destination validation,
                    // do not invalidate the independently verified source access.
                    sourceReadStatus = (error as? MirrorError) == .sourcePermissionDenied ? .unavailable : .available
                }
                problem = LocalizedMessage.from(error).rendered()
                states = [:]
                sourceScope = nil
                monitoredPaths = []
                monitor?.stop()
                let failure = LocalizedMessage.from(error)
                if preferences.globalFailure != failure {
                    preferences.history.insert(HistoryEntry(date: Date(), databaseID: nil, name: "Strongbox", message: LocalizedMessage.from(error), isError: true), at: 0)
                    if preferences.notifications.failures { pendingNotifications.append(PendingNotification(kind: \.failures, title: L10n.text("Strongbox could not be read"), body: failure.rendered(), databaseID: nil)) }
                    preferences.globalFailure = failure
                    _ = save()
                }
            }
            if !isStopping { onLocalScanComplete?(); await deliverNotifications() }
            isChecking = false
            scanTask = nil
            if scanAgain, !isStopping { scanAgain = false; refresh() }
        }
    }

    var driveSettingsDirectory: URL {
        preferencesURL.deletingLastPathComponent().appendingPathComponent("google-drive", isDirectory: true)
    }

    private func invalidateCloudCopies() {
        states = [:]
        onLocalScanStarted?()
    }

    /// Each check holds both the exact copied inode and its scoped folder grant.
    func driveLocalInputs() -> [DriveLocalInput] {
        guard !isDemo, let environment else { return [] }
        let resolveFolder = environment.resolveFolder
        return databases.filter { preference(for: $0).enabled }.map { database in
            let bookmark = preference(for: database).target ?? preferences.defaultTarget
            let ready = sourceReadStatus == .available && preferences.globalFailure == nil &&
                states[database.id]?.error == nil && states[database.id]?.checked != nil &&
                preference(for: database).lastCopied != nil
            let identity = bookmark.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "unconfigured"
            return DriveLocalInput(id: database.id, name: database.displayName, filename: database.filename,
                                   destinationID: identity, makeSnapshot: {
                guard ready, let bookmark else { throw UploadVerificationFailure.localFileUnavailable }
                return try await Task.detached(priority: .utility) {
                    let folder = try resolveFolder(bookmark)
                    let snapshot = try UploadFingerprint.snapshot(directory: folder.url, filename: database.filename)
                    return DriveLocalSnapshot(fingerprint: snapshot.fingerprint, validate: {
                        try await Task.detached(priority: .utility) {
                            try snapshot.validate()
                            withExtendedLifetime(folder) {}
                        }.value
                    })
                }.value
            })
        }
    }

    func recordDriveEvent(_ event: DriveVerificationEvent) {
        guard !isDemo, !loadFailed else { return }
        preferences.history.insert(HistoryEntry(date: Date(), databaseID: event.databaseID,
                                               name: event.databaseName, message: event.message,
                                               isError: event.kind == .error || event.kind == .overdue), at: 0)
        _ = save()
    }

    func deliverDriveEvent(_ event: DriveVerificationEvent) async throws -> DriveNotificationDelivery {
        guard let notifications else { return .permissionDenied }
        do {
            try await notifications.sendDrive(id: event.id, title: L10n.format("%@: Google Drive", event.databaseName),
                                              body: event.message.rendered(), databaseID: event.databaseID.uuidString)
            return .delivered
        } catch FolderPermissionError.notificationsDenied { return .permissionDenied }
    }

    func cancelDriveNotification(_ id: UUID) { notifications?.cancelDrive(id: id) }

    private nonisolated static func sourceFailureStatus(_ error: any Error) -> SourceReadStatus {
        switch error as? MirrorError {
        case .permissionDenied, .sourcePermissionDenied: return .unavailable
        case .invalidMetadata, .invalidDatabase, .inconsistentIdentifier: return .available
        default: break
        }
        switch error as? FolderPermissionError {
        case .staleBookmark, .accessDenied: return .unavailable
        default: break
        }
        let failure = error as NSError
        if failure.domain == NSPOSIXErrorDomain, [Int(EACCES), Int(EPERM)].contains(failure.code) { return .unavailable }
        if failure.domain == NSCocoaErrorDomain, failure.code == CocoaError.fileReadNoPermission.rawValue { return .unavailable }
        if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? any Error {
            if sourceFailureStatus(underlying) == .unavailable { return .unavailable }
        }
        return .unconfirmed
    }

    private nonisolated static func scan(_ bookmark: Data, preferences: Preferences, previousPaths: [Data: String], mounts: [FolderPathDisplay.Mount], resolveFolder: @Sendable (Data) throws -> FolderAccess) throws -> ScanResult {
        let source: FolderAccess
        do { source = try resolveFolder(bookmark) }
        catch { throw SourceScanFailure(message: LocalizedMessage.from(error), sourcePath: nil, readStatus: sourceFailureStatus(error)) }
        defer { withExtendedLifetime(source) {} }
        let sourcePath = FolderPathDisplay.label(for: source.url.path, mounts: mounts, previous: previousPaths[bookmark])
        let databases: [Database]
        do { databases = try StrongboxCatalog.read(groupContainer: source.url) }
        catch {
            throw SourceScanFailure(message: LocalizedMessage.from(error), sourcePath: sourcePath, readStatus: sourceFailureStatus(error))
        }
        let active = databases.filter { preferences.databases[$0.id.uuidString]?.enabled == true }
        var targets: [UUID: FolderAccess] = [:]
        var targetNames: [UUID: String] = [:]
        defer { withExtendedLifetime(targets) {} }
        var states: [UUID: DatabaseState] = [:]
        var destinations: [CopyDestination] = []
        var folderPaths: [Data: String] = [:]
        var sourcePermissionDenied = false
        for database in active {
            do {
                guard let data = preferences.databases[database.id.uuidString]?.target ?? preferences.defaultTarget else { throw ConfigurationError.missingTarget }
                let folder = try resolveFolder(data)
                let path = FolderPathDisplay.label(for: folder.url.path, mounts: mounts, previous: previousPaths[data])
                folderPaths[data] = path
                targetNames[database.id] = path
                let destination = CopyDestination(databaseID: database.id, directory: folder.url, filename: database.filename)
                _ = try DestinationPlanner.conflictingDatabaseIDs([destination], sourceRoot: source.url)
                destinations.append(destination)
                targets[database.id] = folder
            } catch {
                if (error as? MirrorError) == .sourcePermissionDenied { sourcePermissionDenied = true }
                states[database.id] = DatabaseState(checked: Date(), error: LocalizedMessage.from(error))
            }
        }
        let conflicts = try DestinationPlanner.conflictingDatabaseIDs(destinations, sourceRoot: source.url) { destination, error in
            states[destination.databaseID] = DatabaseState(checked: Date(), targetName: targetNames[destination.databaseID], error: LocalizedMessage.from(error))
        }
        for database in active {
            guard states[database.id] == nil else { continue }
            if conflicts.contains(database.id) {
                states[database.id] = DatabaseState(checked: Date(), targetName: targetNames[database.id], error: ConfigurationError.collidingDestination.message)
                continue
            }
            guard let target = targets[database.id] else { continue }
            var state = DatabaseState(checked: Date(), targetName: targetNames[database.id])
            do {
                state.backup = try StrongboxBackups.newest(for: database, groupContainer: source.url)
            } catch {
                if sourceFailureStatus(error) == .unavailable { sourcePermissionDenied = true }
                state.error = LocalizedMessage.from(error)
            }
            if let backup = state.backup {
                do { state.copied = try MirrorEngine.copy(backup: backup, to: target.url, filename: database.filename) == .copied }
                catch {
                    if (error as? MirrorError) == .sourcePermissionDenied { sourcePermissionDenied = true }
                    state.error = LocalizedMessage.from(error)
                }
            }
            states[database.id] = state
        }
        return ScanResult(sourcePath: sourcePath, folderPaths: folderPaths, sourcePermissionDenied: sourcePermissionDenied, databases: databases, states: states)
    }

    private func armMonitor() {
        do {
            guard let source = preferences.source, let environment else { return }
            sourceScope = try environment.resolveFolder(source)
            guard let root = sourceScope?.url else { return }
            let backupRoot = root.appendingPathComponent("backups")
            var urls = [root, root.appendingPathComponent("Library"), root.appendingPathComponent("Library/Preferences"), backupRoot]
            urls += databases.map { backupRoot.appendingPathComponent($0.id.uuidString) }
            urls = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            let paths = Set(urls.map(\.path))
            guard paths != monitoredPaths else { return }
            try monitor?.watch(urls)
            monitoredPaths = paths
            // Files can change after the scan but before new directory watches
            // are installed. Recheck once with those watches already active.
            scanAgain = true
        } catch {
            if Self.sourceFailureStatus(error) == .unavailable { sourceReadStatus = .unavailable }
            let message = LocalizedMessage(key: "File monitoring is unavailable. Periodic checks remain active. %@", causes: [LocalizedMessage.from(error)])
            if preferences.history.first?.message != message {
                preferences.history.insert(HistoryEntry(date: Date(), databaseID: nil, name: "App", message: message, isError: true), at: 0)
                _ = save()
            }
        }
    }

    private func record(_ database: Database, message: LocalizedMessage, isError: Bool) {
        preferences.history.insert(HistoryEntry(date: Date(), databaseID: database.id, name: database.displayName, message: message, isError: isError), at: 0)
        preferences.history = Array(preferences.history.prefix(200))
    }
    private func queueNotification(_ database: Database, kind: WritableKeyPath<NotificationPreferences, Bool>, title: String, body: String) {
        pendingNotifications.append(PendingNotification(kind: kind, title: title, body: body, databaseID: database.id.uuidString))
    }
    private func deliverNotifications() async {
        guard !notificationAttemptRunning, let notifications else {
            pendingNotifications.removeAll()
            return
        }
        notificationAttemptRunning = true
        defer { notificationAttemptRunning = false }
        while !pendingNotifications.isEmpty {
            let pending = pendingNotifications.removeFirst()
            guard preferences.notifications[keyPath: pending.kind] else { continue }
            do {
                let revision = notificationRevisions[pending.kind, default: 0]
                try await notifications.send(title: pending.title, body: pending.body, databaseID: pending.databaseID, kind: pending.kind) { [weak self] in
                    guard let self, !self.isStopping,
                          self.notificationRevisions[pending.kind, default: 0] == revision,
                          self.preferences.notifications[keyPath: pending.kind] else { return false }
                    return pending.databaseID.map { self.preferences.databases[$0]?.enabled == true } ?? true
                }
                notificationStatus = notifications.status
            } catch {
                // Events without permission are kept in history, not delivered late.
                pendingNotifications.removeAll()
                notificationStatus = LocalizedMessage.from(error).rendered()
                return
            }
        }
    }
    func updateNotificationStatus() async {
        guard let notifications, !isStopping else { return }
        await notifications.refreshAuthorization()
        notificationStatus = notifications.status
        if notifications.isAuthorized, problem == FolderPermissionError.notificationsDenied.localizedDescription {
            problem = nil
        }
    }
}
