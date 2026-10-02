import AppKit
import Darwin
import Foundation
import ServiceManagement
import UserNotifications

enum FolderPermissionError: LocalizedError {
    case staleBookmark
    case accessDenied
    case notDirectory
    case notificationsDenied

    var errorDescription: String? {
        switch self {
        case .staleBookmark: "Die gespeicherte Ordnerfreigabe ist veraltet. Bitte den Ordner erneut freigeben."
        case .accessDenied: "Der freigegebene Ordner ist nicht zugänglich. Bitte die Freigabe erneuern."
        case .notDirectory: "Bitte einen Ordner auswählen, der kein symbolischer Link ist."
        case .notificationsDenied: "Mitteilungen sind nicht erlaubt. Die Freigabe lässt sich in den macOS-Systemeinstellungen ändern."
        }
    }
}

/// Keeps one security-scoped grant alive for the duration of a read or copy operation.
final class ScopedFolder {
    let url: URL

    init(bookmark: Data) throws {
        var stale = false
        let resolved = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale else { throw FolderPermissionError.staleBookmark }
        guard resolved.startAccessingSecurityScopedResource() else { throw FolderPermissionError.accessDenied }
        do {
            let values = try resolved.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw FolderPermissionError.notDirectory
            }
        } catch {
            resolved.stopAccessingSecurityScopedResource()
            throw error
        }
        url = resolved
    }

    deinit { url.stopAccessingSecurityScopedResource() }
}

@MainActor
enum FolderPicker {
    static func choose(title: String, message: String, initialURL: URL? = nil, readOnly: Bool) throws -> Data? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = readOnly ? "Lesezugriff erlauben" : "Zielordner wählen"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = !readOnly
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = initialURL
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // NSOpenPanel has already started the temporary security scope.
        defer { url.stopAccessingSecurityScopedResource() }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw FolderPermissionError.notDirectory
        }
        var options: URL.BookmarkCreationOptions = [.withSecurityScope]
        if readOnly { options.insert(.securityScopeAllowOnlyReadAccess) }
        return try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    var onSelectDatabase: ((String) -> Void)?
    private(set) var status = "Noch nicht geprüft"
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func refreshAuthorization() async {
        switch await authorizationStatus() {
        case .notDetermined: status = "Noch nicht freigegeben"
        case .denied: status = "In macOS nicht erlaubt"
        case .authorized: status = "Erlaubt"
        case .provisional: status = "Leise Mitteilungen erlaubt"
        @unknown default: status = "Unbekannter macOS-Status"
        }
    }

    func requestAuthorization() async throws {
        let allowed = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
            center.requestAuthorization(options: [.alert, .sound]) { @Sendable allowed, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: allowed) }
            }
        }
        await refreshAuthorization()
        guard allowed else { throw FolderPermissionError.notificationsDenied }
    }

    func send(title: String, body: String, databaseID: String?) async throws {
        guard [.authorized, .provisional].contains(await authorizationStatus()) else {
            throw FolderPermissionError.notificationsDenied
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let databaseID { content.userInfo = ["databaseID": databaseID] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            center.add(request) { @Sendable error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func authorizationStatus() async -> UNAuthorizationStatus {
        // Older SDKs do not mark UNNotificationSettings as Sendable. Extract
        // the value inside Apple's callback instead of crossing actors with it.
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { @Sendable settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let databaseID = response.notification.request.content.userInfo["databaseID"] as? String
        if let databaseID {
            Task { @MainActor [weak self] in self?.onSelectDatabase?(databaseID) }
        }
        completionHandler()
    }
}

@MainActor
enum LoginService {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }
}

/// Dispatch sources own their descriptors until cancellation completes.
private final class DirectoryWatch: @unchecked Sendable {
    let source: any DispatchSourceFileSystemObject

    init(url: URL, onChange: @escaping @MainActor @Sendable () -> Void) throws {
        let descriptor = open(url.path, O_EVTONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            let code = errno
            close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            close(descriptor)
            throw FolderPermissionError.notDirectory
        }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .revoke],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { Task { @MainActor in onChange() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    func cancel() { source.cancel() }
    deinit { source.cancel() }
}

@MainActor
final class FileMonitor {
    private let onChange: @MainActor @Sendable () -> Void
    private var watches: [DirectoryWatch] = []
    private var generation = UUID()

    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
    }

    /// Replaces the current set only when every requested directory could be opened.
    func watch(_ urls: [URL]) throws {
        var replacement: [DirectoryWatch] = []
        let nextGeneration = UUID()
        var paths: Set<String> = []
        for url in urls where paths.insert(url.standardizedFileURL.path).inserted {
            replacement.append(try DirectoryWatch(url: url) { [weak self] in
                guard let self, self.generation == nextGeneration else { return }
                self.onChange()
            })
        }
        stop()
        generation = nextGeneration
        watches = replacement
    }

    func stop() {
        generation = UUID()
        watches.forEach { $0.cancel() }
        watches.removeAll()
    }
}
