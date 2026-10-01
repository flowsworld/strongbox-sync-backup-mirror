import AppKit
import Foundation
import Darwin
import SyncCopiesCore

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, databases, notifications, googleDrive, history
    var id: Self { self }
    var title: String {
        switch self {
        case .general: "Allgemein"
        case .databases: "Datenbanken"
        case .notifications: "Mitteilungen"
        case .googleDrive: "Google Drive"
        case .history: "Verlauf"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .databases: "externaldrive"
        case .notifications: "bell"
        case .googleDrive: "checkmark.icloud"
        case .history: "clock"
        }
    }
}

struct DatabasePreferences: Codable, Sendable {
    var enabled = false
    var target: Data?
    var lastCopied: Date?
    var lastFailure: String?
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
    let message: String
    let isError: Bool
}

struct Preferences: Codable, Sendable {
    var source: Data?
    var defaultTarget: Data?
    var databases: [String: DatabasePreferences] = [:]
    var notifications = NotificationPreferences()
    var history: [HistoryEntry] = []
    var globalFailure: String?
}

struct DatabaseState: Sendable {
    var checked: Date?
    var backup: BackupInfo?
    var targetName: String?
    var error: String?
    var copied = false
}

private struct ScanResult: Sendable {
    let databases: [Database]
    let states: [UUID: DatabaseState]
}

enum ConfigurationError: LocalizedError {
    case missingTarget, collidingDestination
    var errorDescription: String? {
        switch self {
        case .missingTarget: "Wähle einen gemeinsamen oder eigenen Zielordner."
        case .collidingDestination: "Mehrere Datenbanken würden dieselbe Zieldatei ersetzen. Wähle unterschiedliche Zielordner."
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let isDemo: Bool
    @Published private(set) var preferences = Preferences()
    @Published private(set) var databases: [Database] = []
    @Published private(set) var states: [UUID: DatabaseState] = [:]
    @Published private(set) var isChecking = false
    @Published private(set) var problem: String?
    @Published private(set) var notificationStatus = "Nicht angefragt"
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginNeedsApproval = false
    @Published var page: SettingsPage = .databases
    @Published var expandedDatabases: Set<UUID> = []

    private let environment: AppEnvironment?
    private var notifications: NotificationService? { environment?.notifications }
    private(set) var startupConflict = false
    private(set) var isStopping = false
    private var instanceLock: InstanceLock?
    private var scanTask: Task<Void, Never>?
    var onOpenSettings: (() -> Void)?
    private let preferencesURL: URL
    private var persistenceFailed = false
    private var loadFailed = false
    private var pendingNotifications: [(UUID, WritableKeyPath<NotificationPreferences, Bool>, String, String, String?)] = []
    private var scanAgain = false
    private var generation = 0
    private var sourceScope: FolderAccess?
    private var monitoredPaths: Set<String> = []
    private var monitor: FileMonitor?
    private var notificationAttemptRunning = false

    init(demo: Bool = false, environment suppliedEnvironment: AppEnvironment? = nil) {
        isDemo = demo
        environment = demo ? nil : (suppliedEnvironment ?? AppEnvironment.live())
        preferencesURL = environment?.preferencesURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SyncCopies/preferences.json")
        if demo {
            let privateDB = Database(id: UUID(), filename: "Privat.kdbx", displayName: "Privat")
            let workDB = Database(id: UUID(), filename: "Arbeit.kdbx", displayName: "Arbeit")
            let clubDB = Database(id: UUID(), filename: "Verein.kdbx", displayName: "Verein")
            databases = [privateDB, workDB, clubDB]
            preferences.databases[privateDB.id.uuidString] = DatabasePreferences(enabled: true, lastCopied: Date().addingTimeInterval(-240))
            preferences.databases[workDB.id.uuidString] = DatabasePreferences(enabled: true, target: Data(), lastCopied: Date().addingTimeInterval(-7200))
            states[privateDB.id] = DatabaseState(checked: Date(), targetName: "Google Drive › Lesekopien")
            states[workDB.id] = DatabaseState(checked: Date(), targetName: "NAS › Lesekopien", error: "Der Zielordner ist nicht erreichbar. Verbinde das NAS.")
            preferences.history = [HistoryEntry(date: Date(), databaseID: workDB.id, name: "Arbeit", message: "Ziel nicht erreichbar", isError: true), HistoryEntry(date: Date().addingTimeInterval(-240), databaseID: privateDB.id, name: "Privat", message: "Neue Kopie erstellt", isError: false)]
            notificationStatus = "Vorschau mit Beispieldaten"
            return
        }
        do {
            try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            instanceLock = try InstanceLock(url: preferencesURL.deletingLastPathComponent().appendingPathComponent(".instance.lock"))
        } catch {
            startupConflict = (error as? InstanceLockError) == .alreadyRunning
            loadFailed = true
            problem = error.localizedDescription
            return
        }
        do {
            if FileManager.default.fileExists(atPath: preferencesURL.path) {
                preferences = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: preferencesURL))
            }
        } catch {
            loadFailed = true
            persistenceFailed = true
            problem = "Die gespeicherten Einstellungen konnten nicht gelesen werden. \(error.localizedDescription)"
        }
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
        refresh()
    }

    var activeCount: Int { databases.filter { preference(for: $0).enabled }.count }
    var sourceGranted: Bool { isDemo || preferences.source != nil }
    var commonTargetName: String { isDemo ? "Google Drive › Lesekopien" : label(for: preferences.defaultTarget) }
    var failureCount: Int { states.values.filter { $0.error != nil }.count }
    func preference(for database: Database) -> DatabasePreferences {
        preferences.databases[database.id.uuidString] ?? DatabasePreferences()
    }
    func label(for bookmark: Data?) -> String {
        guard let bookmark else { return "Kein Ordner ausgewählt" }
        guard let environment else { return "Zugriff erneut erlauben" }
        do { return try environment.resolveFolder(bookmark).url.lastPathComponent }
        catch { return "Zugriff erneut erlauben" }
    }

    func chooseSource() {
        guard !isDemo, !isChecking, !isStopping, !loadFailed else { return }
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser
            // passwd provides the actual home rather than the app's sandbox home.
            let userHome = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir)) } ?? home
            guard let bookmark = try FolderPicker.choose(
                title: "Strongbox-Zugriff erlauben",
                message: "Erlaube den Lesezugriff auf Strongboxs lokale Backups und Datenbanknamen.",
                initialURL: userHome.appendingPathComponent("Library/Group Containers/group.strongbox.mac.mcguill"),
                readOnly: true
            ) else { return }
            preferences.source = bookmark
            generation += 1
            sourceScope = nil
            monitoredPaths = []
            monitor?.stop()
            if save() { refresh() }
        } catch { problem = error.localizedDescription }
    }

    func chooseTarget(for database: Database? = nil) {
        guard !isDemo, !isChecking, !isStopping, !loadFailed else { return }
        do {
            guard let bookmark = try FolderPicker.choose(
                title: "Zielordner wählen", message: "Wähle einen bestehenden Ordner für die Lesekopien.", readOnly: false
            ) else { return }
            if let database {
                var item = preference(for: database)
                item.target = bookmark
                preferences.databases[database.id.uuidString] = item
            } else { preferences.defaultTarget = bookmark }
            generation += 1
            if save() { refresh() }
        } catch { problem = error.localizedDescription }
    }

    func useCommonTarget(for database: Database) {
        guard !isDemo, !isChecking, !isStopping, !loadFailed else { return }
        var item = preference(for: database)
        item.target = nil
        preferences.databases[database.id.uuidString] = item
        generation += 1
        if save() { refresh() }
    }

    func setEnabled(_ enabled: Bool, for database: Database) {
        guard !isDemo, !isChecking, !isStopping, !loadFailed else { return }
        var item = preference(for: database)
        item.enabled = enabled
        if !enabled {
            item.lastFailure = nil
            pendingNotifications.removeAll { $0.4 == database.id.uuidString }
        }
        preferences.databases[database.id.uuidString] = item
        generation += 1
        if save() { refresh() }
    }

    func setNotification(_ key: WritableKeyPath<NotificationPreferences, Bool>, to value: Bool) {
        guard !isStopping, !loadFailed else { return }
        preferences.notifications[keyPath: key] = value
        pendingNotifications.removeAll { !preferences.notifications[keyPath: $0.1] }
        guard save() else { return }
        if value, !isDemo, let notifications {
            Task {
                do { try await notifications.requestAuthorization() }
                catch { problem = error.localizedDescription }
                await updateNotificationStatus()
            }
        }
    }

    func requestNotifications() {
        guard !isDemo, !isStopping, let notifications else { return }
        Task {
            do { try await notifications.requestAuthorization() }
            catch { problem = error.localizedDescription }
            await updateNotificationStatus()
        }
    }

    func testNotification() {
        guard !isDemo, !isStopping, let notifications else { return }
        Task {
            do {
                try await notifications.requestAuthorization()
                try await notifications.send(title: "Sync-Kopien", body: "Testmitteilung. Es wurde keine Datei kopiert.", databaseID: nil)
            } catch { problem = error.localizedDescription }
            await updateNotificationStatus()
        }
    }

    func setLogin(_ enabled: Bool) {
        guard !isDemo, !isStopping, !loadFailed, let environment else { return }
        do { try environment.setLogin(enabled) }
        catch { problem = error.localizedDescription }
        let login = environment.loginStatus()
        loginEnabled = login.enabled
        loginNeedsApproval = login.needsApproval
    }

    private func save() -> Bool {
        if isDemo { return true }
        guard !loadFailed else { return false }
        preferences.history = Array(preferences.history.prefix(200))
        do {
            try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(preferences)
            try data.write(to: preferencesURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preferencesURL.path)
            persistenceFailed = false
            return true
        } catch {
            persistenceFailed = true
            problem = "Einstellungen konnten nicht gespeichert werden. \(error.localizedDescription)"
            return false
        }
    }

    func shutdown() async {
        isStopping = true
        environment?.scheduler.stop()
        monitor?.stop()
        scanAgain = false
        await scanTask?.value
        sourceScope = nil
        instanceLock = nil
    }

    func refresh() {
        guard !isDemo, !isStopping, let environment else { return }
        guard !loadFailed, let bookmark = preferences.source else { return }
        if persistenceFailed, !save() { return }
        guard !isChecking else { scanAgain = true; return }
        isChecking = true
        let snapshot = preferences
        let currentGeneration = generation
        scanTask = Task {
            do {
                let result = try await Task.detached(priority: .utility) { try Self.scan(bookmark, preferences: snapshot, resolveFolder: environment.resolveFolder) }.value
                guard currentGeneration == generation else {
                    isChecking = false
                    scanTask = nil
                    refresh()
                    return
                }
                databases = result.databases
                states = result.states
                if !persistenceFailed { problem = nil }
                let recoveredSource = preferences.globalFailure != nil
                preferences.globalFailure = nil
                let enabledIDs = Set(databases.filter { preference(for: $0).enabled }.map { $0.id.uuidString })
                pendingNotifications.removeAll { $0.4.map { !enabledIDs.contains($0) } ?? ($0.1 == \.failures) }
                if recoveredSource {
                    preferences.history.insert(HistoryEntry(date: Date(), databaseID: nil, name: "Strongbox", message: "Lesezugriff funktioniert wieder", isError: false), at: 0)
                    if preferences.notifications.recoveries { pendingNotifications.append((UUID(), \.recoveries, "Strongbox: Fehler behoben", "Die lokalen Backups können wieder geprüft werden.", nil)) }
                }
                for database in databases where preference(for: database).enabled {
                    guard let state = states[database.id] else { continue }
                    if let failure = state.error {
                        if preference(for: database).lastFailure != failure {
                            record(database, message: failure, isError: true)
                            if preferences.notifications.failures { queueNotification(database, kind: \.failures, title: "\(database.displayName) konnte nicht kopiert werden", body: failure) }
                        }
                        preferences.databases[database.id.uuidString, default: DatabasePreferences()].lastFailure = failure
                    } else {
                        pendingNotifications.removeAll { $0.4 == database.id.uuidString && $0.1 == \.failures }
                        if preference(for: database).lastFailure != nil {
                            preferences.databases[database.id.uuidString, default: DatabasePreferences()].lastFailure = nil
                            record(database, message: "Fehler behoben", isError: false)
                            if preferences.notifications.recoveries { queueNotification(database, kind: \.recoveries, title: "\(database.displayName): Fehler behoben", body: "Die Lesekopie kann wieder aktualisiert werden.") }
                        }
                        if state.copied {
                            preferences.databases[database.id.uuidString, default: DatabasePreferences()].lastCopied = state.checked
                            record(database, message: "Neue Kopie erstellt", isError: false)
                            if preferences.notifications.copies { queueNotification(database, kind: \.copies, title: "\(database.displayName) wurde kopiert", body: "Die neue Lesekopie liegt im gewählten Zielordner.") }
                        }
                    }
                }
                _ = save()
                if !isStopping { armMonitor() }
            } catch {
                problem = error.localizedDescription
                states = [:]
                sourceScope = nil
                monitoredPaths = []
                monitor?.stop()
                if preferences.globalFailure != problem {
                    preferences.history.insert(HistoryEntry(date: Date(), databaseID: nil, name: "Strongbox", message: error.localizedDescription, isError: true), at: 0)
                    if preferences.notifications.failures { pendingNotifications.append((UUID(), \.failures, "Strongbox konnte nicht gelesen werden", error.localizedDescription, nil)) }
                    preferences.globalFailure = problem
                    _ = save()
                }
            }
            if !isStopping { await deliverNotifications() }
            isChecking = false
            scanTask = nil
            if scanAgain, !isStopping { scanAgain = false; refresh() }
        }
    }

    private nonisolated static func scan(_ bookmark: Data, preferences: Preferences, resolveFolder: @Sendable (Data) throws -> FolderAccess) throws -> ScanResult {
        let source = try resolveFolder(bookmark)
        defer { withExtendedLifetime(source) {} }
        let databases = try StrongboxCatalog.read(groupContainer: source.url)
        let active = databases.filter { preferences.databases[$0.id.uuidString]?.enabled == true }
        var targets: [UUID: FolderAccess] = [:]
        defer { withExtendedLifetime(targets) {} }
        var states: [UUID: DatabaseState] = [:]
        var destinations: [CopyDestination] = []
        for database in active {
            do {
                guard let data = preferences.databases[database.id.uuidString]?.target ?? preferences.defaultTarget else { throw ConfigurationError.missingTarget }
                let folder = try resolveFolder(data)
                let destination = CopyDestination(databaseID: database.id, directory: folder.url, filename: database.filename)
                _ = try DestinationPlanner.conflictingDatabaseIDs([destination], sourceRoot: source.url)
                destinations.append(destination)
                targets[database.id] = folder
            } catch { states[database.id] = DatabaseState(checked: Date(), error: error.localizedDescription) }
        }
        let conflicts = try DestinationPlanner.conflictingDatabaseIDs(destinations, sourceRoot: source.url)
        for database in active {
            guard states[database.id] == nil else { continue }
            if conflicts.contains(database.id) {
                states[database.id] = DatabaseState(checked: Date(), error: ConfigurationError.collidingDestination.localizedDescription)
                continue
            }
            guard let target = targets[database.id] else { continue }
            var state = DatabaseState(checked: Date(), targetName: target.url.lastPathComponent)
            do {
                let backup = try StrongboxBackups.newest(for: database, groupContainer: source.url)
                state.backup = backup
                state.copied = try MirrorEngine.copy(backup: backup, to: target.url, filename: database.filename) == .copied
            } catch { state.error = error.localizedDescription }
            states[database.id] = state
        }
        return ScanResult(databases: databases, states: states)
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
        } catch {
            let message = "Dateiüberwachung nicht verfügbar. Die regelmäßige Prüfung bleibt aktiv. \(error.localizedDescription)"
            if preferences.history.first?.message != message {
                preferences.history.insert(HistoryEntry(date: Date(), databaseID: nil, name: "App", message: message, isError: true), at: 0)
                _ = save()
            }
        }
    }

    private func record(_ database: Database, message: String, isError: Bool) {
        preferences.history.insert(HistoryEntry(date: Date(), databaseID: database.id, name: database.displayName, message: message, isError: isError), at: 0)
        preferences.history = Array(preferences.history.prefix(200))
    }
    private func queueNotification(_ database: Database, kind: WritableKeyPath<NotificationPreferences, Bool>, title: String, body: String) {
        pendingNotifications.append((UUID(), kind, title, body, database.id.uuidString))
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
            guard preferences.notifications[keyPath: pending.1] else { continue }
            do {
                try await notifications.send(title: pending.2, body: pending.3, databaseID: pending.4)
            } catch {
                // Events without permission are kept in history, not delivered late.
                pendingNotifications.removeAll()
                notificationStatus = error.localizedDescription
                return
            }
        }
    }
    private func updateNotificationStatus() async {
        guard let notifications, !isStopping else { return }
        await notifications.refreshAuthorization()
        notificationStatus = notifications.status
    }
}
