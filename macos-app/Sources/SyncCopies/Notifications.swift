import Foundation
import UserNotifications
import SyncCopiesCore

/// The system boundary. Automated tests supply effects without touching OS permissions.
@MainActor
struct NotificationOperations {
    let authorization: () async -> UNAuthorizationStatus
    let requestAuthorization: () async throws -> Bool
    let add: @MainActor (UNNotificationRequest) async throws -> Void
    let removePending: ([String]) -> Void
    let cancelPending: (String) -> Void
    let discardPending: () -> Void
}

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private var inFlight: [WritableKeyPath<NotificationPreferences, Bool>: Set<String>] = [:]
    private var prefixes: [WritableKeyPath<NotificationPreferences, Bool>: String] = [:]
    private var driveAttempts: [UUID: UUID] = [:]
    var onSelectDatabase: ((String) -> Void)?
    private(set) var status = L10n.text("Not checked yet")
    private(set) var isAuthorized = false
    private let operations: NotificationOperations

    init(operations: NotificationOperations) {
        self.operations = operations
        super.init()
    }

    override convenience init() {
        let center = UNUserNotificationCenter.current()
        self.init(operations: NotificationOperations(
            authorization: {
                // Extract the Sendable enum in Apple's callback for older macOS SDKs.
                await withCheckedContinuation { continuation in
                    center.getNotificationSettings { @Sendable settings in
                        continuation.resume(returning: settings.authorizationStatus)
                    }
                }
            },
            requestAuthorization: {
                try await withCheckedThrowingContinuation { continuation in
                    center.requestAuthorization(options: [.alert, .sound]) { @Sendable allowed, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: allowed) }
                    }
                }
            },
            add: { request in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    center.add(request) { @Sendable error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
            },
            removePending: { center.removePendingNotificationRequests(withIdentifiers: $0) },
            cancelPending: { prefix in
                center.getPendingNotificationRequests { requests in
                    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: requests
                        .filter { $0.identifier.hasPrefix(prefix) }.map(\.identifier))
                }
            },
            discardPending: { center.removeAllPendingNotificationRequests() }
        ))
        center.delegate = self
    }

    /// Call only after acquiring the settings lock, so a duplicate app cannot
    /// discard requests owned by the process that is already running.
    func discardStaleRequests() {
        operations.discardPending()
    }

    func refreshAuthorization() async {
        _ = await authorizationStatus()
    }

    func requestAuthorization() async throws {
        let allowed = try await operations.requestAuthorization()
        await refreshAuthorization()
        guard allowed else { throw FolderPermissionError.notificationsDenied }
    }

    func send(
        title: String, body: String, databaseID: String?,
        kind: WritableKeyPath<NotificationPreferences, Bool>? = nil,
        isCurrent: () -> Bool = { true }
    ) async throws {
        let prefix: String
        if let kind {
            prefix = prefixes[kind] ?? UUID().uuidString + ":"
            prefixes[kind] = prefix
        } else { prefix = "test:" }
        guard [.authorized, .provisional].contains(await authorizationStatus()) else {
            throw FolderPermissionError.notificationsDenied
        }
        // The preferences may change while the authorization query suspends.
        guard isCurrent() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let databaseID { content.userInfo["databaseID"] = databaseID }
        if let kind {
            content.userInfo["kind"] = kind == \.failures ? "failures" : (kind == \.copies ? "copies" : "recoveries")
        }
        // Category alerts get a short cancellation window. Immediate delivery can
        // precede the add callback, so removing requests only afterwards is too late.
        let trigger = kind.map { _ in UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false) }
        let identifier = prefix + UUID().uuidString
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        if let kind { inFlight[kind, default: []].insert(identifier) }
        defer { if let kind { inFlight[kind]?.remove(identifier) } }
        try await operations.add(request)
        // add itself can suspend after the category has been turned off.
        if !isCurrent() { operations.removePending([identifier]) }
    }

    func cancelPending(kind: WritableKeyPath<NotificationPreferences, Bool>) {
        // Removal is submitted after add in the system's serial request queue,
        // even when add has not called its completion handler yet.
        operations.removePending(Array(inFlight[kind] ?? []))
        if let prefix = prefixes.removeValue(forKey: kind) { operations.cancelPending(prefix) }
    }

    func sendDrive(id: UUID, title: String, body: String, databaseID: String) async throws {
        let attempt = UUID()
        driveAttempts[id] = attempt
        defer { if driveAttempts[id] == attempt { driveAttempts.removeValue(forKey: id) } }
        guard [.authorized, .provisional].contains(await authorizationStatus()) else {
            throw FolderPermissionError.notificationsDenied
        }
        guard !Task.isCancelled, driveAttempts[id] == attempt else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo["databaseID"] = databaseID
        let identifier = "drive:" + id.uuidString
        let request = UNNotificationRequest(identifier: identifier, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        try await operations.add(request)
        if Task.isCancelled || driveAttempts[id] != attempt { operations.removePending([identifier]) }
    }

    func cancelDrive(id: UUID) {
        driveAttempts.removeValue(forKey: id)
        operations.removePending(["drive:" + id.uuidString])
    }

    func selectDatabase(_ id: String?) {
        guard let id, UUID(uuidString: id) != nil else { return }
        onSelectDatabase?(id)
    }

    private func authorizationStatus() async -> UNAuthorizationStatus {
        let authorization = await operations.authorization()
        isAuthorized = [.authorized, .provisional].contains(authorization)
        switch authorization {
        case .notDetermined: status = L10n.text("Permission not requested yet")
        case .denied: status = L10n.text("Not allowed in macOS")
        case .authorized: status = L10n.text("Allowed")
        case .provisional: status = L10n.text("Quiet notifications allowed")
        @unknown default: status = L10n.text("Unknown macOS status")
        }
        return authorization
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
            Task { @MainActor [weak self] in self?.selectDatabase(databaseID) }
        }
        completionHandler()
    }
}
