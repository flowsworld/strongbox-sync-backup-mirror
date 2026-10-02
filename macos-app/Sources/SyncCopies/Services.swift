import AppKit
import Darwin
import Foundation
import SyncCopiesCore
import ServiceManagement
import UserNotifications

enum FolderPermissionError: LocalizedError, LocalizedMessageError {
    case staleBookmark
    case accessDenied
    case notDirectory
    case notificationsDenied

    var errorDescription: String? { message.rendered() }

    var message: LocalizedMessage {
        switch self {
        case .staleBookmark: LocalizedMessage(key: "The saved folder permission is out of date. Please allow access to the folder again.")
        case .accessDenied: LocalizedMessage(key: "The permitted folder is inaccessible. Please allow access again.")
        case .notDirectory: LocalizedMessage(key: "Please choose a folder that is not a symbolic link.")
        case .notificationsDenied: LocalizedMessage(key: "Notifications are not allowed. You can change the permission in macOS System Settings.")
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
        panel.prompt = readOnly ? L10n.text("Allow read access") : L10n.text("Choose destination folder")
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
