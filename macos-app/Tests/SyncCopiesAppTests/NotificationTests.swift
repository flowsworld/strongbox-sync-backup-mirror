import Foundation
import Testing
import SyncCopiesCore
import UserNotifications
@testable import SyncCopies

@MainActor
private final class NotificationRecorder {
    var authorization: UNAuthorizationStatus = .authorized
    var requests: [UNNotificationRequest] = []
    var authorizationRequests = 0
    var discarded = 0
    var authorizationHook: (() async -> Void)?
    var removed: [String] = []
    var addHook: (() async -> Void)?

    func service() -> NotificationService {
        NotificationService(operations: NotificationOperations(
            authorization: { [self] in
                if let hook = authorizationHook { authorizationHook = nil; await hook() }
                return authorization
            },
            requestAuthorization: { [self] in
                authorizationRequests += 1
                return authorization == .authorized || authorization == .provisional
            },
            add: { [self] request in
                // The system can accept a request before its callback returns.
                requests.append(request)
                if let hook = addHook { addHook = nil; await hook() }
            },
            removePending: { [self] in removed += $0 },
            cancelPending: { [self] prefix in removed += requests.filter { $0.identifier.hasPrefix(prefix) }.map(\.identifier) },
            discardPending: { [self] in discarded += 1 }
        ))
    }
}

@MainActor
private final class NotificationGate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
struct NotificationTests {
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Notification test did not settle")
    }

    @Test func onlyTheProcessOwningSettingsDiscardsStaleRequests() async throws {
        let fixture = try ModelFixture()
        let recorder = NotificationRecorder()
        let model = AppModel(environment: fixture.environment(notifications: recorder.service()))
        try await eventually { !model.isChecking }
        #expect(recorder.discarded == 1)
        let duplicate = AppModel(environment: fixture.environment(notifications: recorder.service()))
        #expect(duplicate.startupConflict)
        #expect(recorder.discarded == 1)
        await duplicate.shutdown()
        await model.shutdown()
        let restarted = AppModel(environment: fixture.environment(notifications: recorder.service()))
        try await eventually { !restarted.isChecking }
        #expect(recorder.discarded == 2)
        await restarted.shutdown()
    }

    @Test func switchingOffCategoryCancelsAnInFlightAuthorizationCheck() async throws {
        let fixture = try ModelFixture()
        let recorder = NotificationRecorder()
        let model = AppModel(environment: fixture.environment(notifications: recorder.service()))
        try await eventually { !model.isChecking }
        let gate = NotificationGate()
        recorder.authorizationHook = { await gate.wait() }
        try FileManager.default.moveItem(at: fixture.common, to: fixture.root.appendingPathComponent("offline"))
        model.refresh()
        try await eventually { gate.entered }
        model.setNotification(\.failures, to: false)
        gate.release()
        try await eventually { !model.isChecking }
        #expect(recorder.requests.isEmpty)
        #expect(model.preferences.history.contains { $0.isError })
        await model.shutdown()
    }

    @Test(arguments: 0..<8)
    func categoriesAreIndependentAndFailuresSurviveRestart(choices: Int) async throws {
        let fixture = try ModelFixture()
        var settings = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: fixture.preferencesURL))
        settings.notifications = NotificationPreferences(failures: choices & 1 != 0, copies: choices & 2 != 0, recoveries: choices & 4 != 0)
        try JSONEncoder().encode(settings).write(to: fixture.preferencesURL)
        let recorder = NotificationRecorder()
        let model = AppModel(environment: fixture.environment(notifications: recorder.service()))
        try await eventually { !model.isChecking }
        #expect(recorder.requests.count == (settings.notifications.copies ? 2 : 0))
        recorder.requests.removeAll()
        model.refresh()
        try await eventually { !model.isChecking }
        #expect(recorder.requests.isEmpty)
        let offline = fixture.root.appendingPathComponent("offline")
        try FileManager.default.moveItem(at: fixture.common, to: offline)
        model.refresh()
        try await eventually { !model.isChecking }
        #expect(recorder.requests.count == (settings.notifications.failures ? 1 : 0))
        #expect(model.preferences.history.filter { $0.isError }.count == 1)
        recorder.requests.removeAll()
        model.refresh()
        try await eventually { !model.isChecking }
        #expect(recorder.requests.isEmpty)
        await model.shutdown()
        let restarted = AppModel(environment: fixture.environment(notifications: recorder.service()))
        try await eventually { !restarted.isChecking }
        #expect(recorder.requests.isEmpty)
        try FileManager.default.moveItem(at: offline, to: fixture.common)
        restarted.refresh()
        try await eventually { !restarted.isChecking }
        #expect(recorder.requests.count == (settings.notifications.recoveries ? 1 : 0))
        #expect(restarted.preferences.history.contains { $0.message.key == "Error resolved" })
        recorder.requests.removeAll()
        try FileManager.default.moveItem(at: fixture.common, to: offline)
        restarted.refresh()
        try await eventually { !restarted.isChecking }
        #expect(recorder.requests.count == (settings.notifications.failures ? 1 : 0))
        await restarted.shutdown()
    }

    @Test func globalSourceFailureRecoversAndANewFailureNotifies() async throws {
        let fixture = try ModelFixture()
        var settings = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: fixture.preferencesURL))
        settings.notifications.recoveries = true
        try JSONEncoder().encode(settings).write(to: fixture.preferencesURL)
        let recorder = NotificationRecorder()
        let model = AppModel(environment: fixture.environment(notifications: recorder.service()))
        try await eventually { !model.isChecking }
        let offline = fixture.root.appendingPathComponent("offline-source")
        try FileManager.default.moveItem(at: fixture.source, to: offline)
        model.refresh()
        try await eventually { !model.isChecking }
        #expect(recorder.requests.count == 1)
        #expect(recorder.requests[0].content.userInfo["databaseID"] == nil)
        model.refresh()
        try await eventually { !model.isChecking }
        #expect(recorder.requests.count == 1)
        await model.shutdown()
        let restarted = AppModel(environment: fixture.environment(notifications: recorder.service()))
        try await eventually { !restarted.isChecking }
        #expect(recorder.requests.count == 1)
        try FileManager.default.moveItem(at: offline, to: fixture.source)
        restarted.refresh()
        try await eventually { !restarted.isChecking }
        #expect(recorder.requests.count == 2)
        #expect(recorder.requests.last?.content.userInfo["kind"] as? String == "recoveries")
        #expect(restarted.preferences.history.contains { $0.message.key == "Read access is working again" })
        try FileManager.default.moveItem(at: fixture.common, to: fixture.root.appendingPathComponent("offline-target"))
        restarted.refresh()
        try await eventually { !restarted.isChecking }
        #expect(recorder.requests.count == 3)
        var changed = restarted.preferences
        changed.databases[fixture.first.id.uuidString]?.target = Data("invalid-grant".utf8)
        await restarted.shutdown()
        try JSONEncoder().encode(changed).write(to: fixture.preferencesURL)
        let changedFailure = AppModel(environment: fixture.environment(notifications: recorder.service()))
        try await eventually { !changedFailure.isChecking }
        #expect(recorder.requests.count == 4)
        await changedFailure.shutdown()
    }

    @Test(arguments: [UNAuthorizationStatus.denied, .notDetermined])
    func deniedEventsRemainInHistoryAndAreNotReplayed(authorization: UNAuthorizationStatus) async throws {
        let fixture = try ModelFixture()
        var settings = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: fixture.preferencesURL))
        settings.notifications = NotificationPreferences(failures: true, copies: true, recoveries: true)
        try JSONEncoder().encode(settings).write(to: fixture.preferencesURL)
        let recorder = NotificationRecorder()
        recorder.authorization = authorization
        let model = AppModel(environment: fixture.environment(notifications: recorder.service()))
        try await eventually { !model.isChecking }
        #expect(recorder.requests.isEmpty)
        #expect(model.preferences.history.filter { $0.message.key == "New copy created" }.count == 2)
        #expect(recorder.authorizationRequests == 0)
        recorder.authorization = .authorized
        await model.updateNotificationStatus()
        #expect(model.notificationStatus == L10n.text("Allowed"))
        model.refresh()
        try await eventually { !model.isChecking }
        #expect(recorder.requests.isEmpty)
        recorder.authorization = .denied
        let offline = fixture.root.appendingPathComponent("offline")
        try FileManager.default.moveItem(at: fixture.common, to: offline)
        model.refresh()
        try await eventually { !model.isChecking }
        #expect(recorder.requests.isEmpty)
        #expect(model.notificationStatus.contains("nicht erlaubt"))
        recorder.authorization = .provisional
        await model.updateNotificationStatus()
        model.refresh()
        try await eventually { !model.isChecking }
        #expect(recorder.requests.isEmpty)
        try FileManager.default.moveItem(at: offline, to: fixture.common)
        model.refresh()
        try await eventually { !model.isChecking }
        #expect(recorder.requests.count == 1)
        try fixture.backup(fixture.first, bytes: "changed notification fixture")
        model.refresh()
        try await eventually { !model.isChecking }
        #expect(recorder.requests.count == 2)
        await model.shutdown()
    }

    @Test func reEnablingDoesNotReviveAnInFlightEvent() async throws {
        let fixture = try ModelFixture()
        let recorder = NotificationRecorder()
        let model = AppModel(environment: fixture.environment(notifications: recorder.service()))
        try await eventually { !model.isChecking }
        let gate = NotificationGate()
        recorder.authorizationHook = { await gate.wait() }
        try FileManager.default.moveItem(at: fixture.common, to: fixture.root.appendingPathComponent("offline"))
        model.refresh()
        try await eventually { gate.entered }
        model.setNotification(\.failures, to: false)
        model.setNotification(\.failures, to: true)
        gate.release()
        try await eventually { !model.isChecking }
        #expect(recorder.requests.isEmpty)
        await model.shutdown()
    }

    @Test func switchingOffDuringSystemSubmissionRemovesThePendingRequest() async throws {
        let fixture = try ModelFixture()
        let recorder = NotificationRecorder()
        let model = AppModel(environment: fixture.environment(notifications: recorder.service()))
        try await eventually { !model.isChecking }
        let gate = NotificationGate()
        recorder.addHook = { await gate.wait() }
        try FileManager.default.moveItem(at: fixture.common, to: fixture.root.appendingPathComponent("offline"))
        model.refresh()
        try await eventually { gate.entered }
        let request = try #require(recorder.requests.first)
        let trigger = try #require(request.trigger as? UNTimeIntervalNotificationTrigger)
        #expect(trigger.timeInterval == 1)
        #expect(!trigger.repeats)
        model.setNotification(\.failures, to: false)
        // Cancellation must be issued before the system's add callback returns.
        #expect(recorder.removed.contains(request.identifier))
        gate.release()
        try await eventually { !model.isChecking }
        #expect(recorder.requests.count == 1)
        #expect(recorder.removed.contains(recorder.requests[0].identifier))
        await model.shutdown()
    }

    @Test func testActionAndRepeatedSelectionsUseTheNormalModel() async throws {
        let fixture = try ModelFixture()
        let recorder = NotificationRecorder()
        let service = recorder.service()
        let model = AppModel(environment: fixture.environment(notifications: service))
        try await eventually { !model.isChecking }
        #expect(model.preferences.notifications.failures)
        #expect(!model.preferences.notifications.copies)
        #expect(!model.preferences.notifications.recoveries)
        model.testNotification()
        try await eventually { recorder.requests.count == 1 }
        #expect(recorder.authorizationRequests == 1)
        #expect(recorder.requests[0].content.userInfo["databaseID"] == nil)
        var windowsOpened = 0
        model.onOpenSettings = { windowsOpened += 1 }
        model.page = .history
        service.selectDatabase(fixture.first.id.uuidString)
        #expect(windowsOpened == 1)
        #expect(model.page == .databases)
        #expect(model.expandedDatabases.contains(fixture.first.id))
        model.expandedDatabases.remove(fixture.first.id)
        service.selectDatabase(fixture.first.id.uuidString)
        #expect(windowsOpened == 2)
        #expect(model.expandedDatabases.contains(fixture.first.id))
        service.selectDatabase("invalid")
        #expect(windowsOpened == 2)
        recorder.authorization = .denied
        model.testNotification()
        try await eventually { recorder.authorizationRequests == 2 && model.problem != nil }
        #expect(recorder.requests.count == 1)
        recorder.authorization = .authorized
        await model.updateNotificationStatus()
        #expect(model.notificationStatus == L10n.text("Allowed"))
        #expect(model.problem == nil)
        await model.shutdown()
    }

}
