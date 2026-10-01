import AppKit
import Foundation

/// An immutable folder plus the lifetime of its security-scoped grant. Already
/// accessible folders are used for sandbox-owned fixtures and isolated tests.
struct FolderAccess: @unchecked Sendable {
    let url: URL
    private let scope: ScopedFolder?

    init(bookmark: Data) throws {
        let scope = try ScopedFolder(bookmark: bookmark)
        self.scope = scope
        url = scope.url
    }

    init(url: URL) {
        self.url = url
        scope = nil
    }
}

/// External effects used by the normal model. Tests supply an isolated settings
/// file and folder resolver, while retaining the real scheduler and monitor.
@MainActor
struct AppEnvironment {
    let preferencesURL: URL
    let resolveFolder: @Sendable (Data) throws -> FolderAccess
    let scheduler: AppScheduler
    let notifications: NotificationService?
    let loginStatus: () -> (enabled: Bool, needsApproval: Bool)
    let setLogin: (Bool) throws -> Void

    static func live() -> AppEnvironment {
        AppEnvironment(
            preferencesURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/SyncCopies/preferences.json"),
            resolveFolder: { try FolderAccess(bookmark: $0) },
            scheduler: AppScheduler(),
            notifications: NotificationService(),
            loginStatus: { (LoginService.enabled, LoginService.requiresApproval) },
            setLogin: LoginService.setEnabled
        )
    }
}
