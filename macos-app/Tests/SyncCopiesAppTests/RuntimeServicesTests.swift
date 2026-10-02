import AppKit
import Darwin
import Foundation
import Testing
@testable import SyncCopies

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !condition() && Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor
@Test func schedulerRespondsToTimerAndWakeAndStopsQueuedCallbacks() async throws {
    let center = NotificationCenter()
    let scheduler = AppScheduler(interval: 0.03, wakeCenter: center)
    var count = 0
    scheduler.start { count += 1 }
    try await waitUntil { count > 0 }
    scheduler.stop()
    let stoppedCount = count
    center.post(name: NSWorkspace.didWakeNotification, object: nil)
    try await Task.sleep(for: .milliseconds(100))
    #expect(count == stoppedCount)

    scheduler.start { count += 1 }
    center.post(name: NSWorkspace.didWakeNotification, object: nil)
    scheduler.stop()
    try await Task.sleep(for: .milliseconds(100))
    #expect(count == stoppedCount)

    let wakeOnlyScheduler = AppScheduler(interval: 60, wakeCenter: center)
    wakeOnlyScheduler.start { count += 1 }
    center.post(name: NSWorkspace.didWakeNotification, object: nil)
    try await waitUntil { count == stoppedCount + 1 }
    wakeOnlyScheduler.stop()
}

@MainActor
@Test func schedulerReleasesResourcesWhenOwnerDisappears() async throws {
    let center = NotificationCenter()
    var scheduler: AppScheduler? = AppScheduler(interval: 0.03, wakeCenter: center)
    weak var released = scheduler
    var count = 0
    scheduler?.start { count += 1 }
    scheduler = nil
    #expect(released == nil)
    center.post(name: NSWorkspace.didWakeNotification, object: nil)
    try await Task.sleep(for: .milliseconds(100))
    #expect(count == 0)
}

@MainActor
@Test func fileMonitorHandlesReplacementAndSuppressesStoppedAndOldWatches() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("first")
    let second = root.appendingPathComponent("second")
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    var count = 0
    let monitor = FileMonitor { count += 1 }
    try monitor.watch([first, first])
    try Data("initial".utf8).write(to: first.appendingPathComponent("backup"), options: .atomic)
    try await waitUntil { count > 0 }

    try monitor.watch([second])
    let replacedCount = count
    try FileManager.default.removeItem(at: first)
    try await Task.sleep(for: .milliseconds(100))
    #expect(count == replacedCount)
    try Data("new".utf8).write(to: second.appendingPathComponent("backup"), options: .atomic)
    try await waitUntil { count > replacedCount }

    try FileManager.default.moveItem(at: second, to: root.appendingPathComponent("renamed"))
    let beforeRename = count
    try await waitUntil { count > beforeRename }
    monitor.stop()
    let stoppedCount = count
    try Data("later".utf8).write(to: root.appendingPathComponent("renamed/later"))
    try await Task.sleep(for: .milliseconds(100))
    #expect(count == stoppedCount)
}

@MainActor
@Test func failedMonitorReplacementPreservesExistingWatch() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var count = 0
    let monitor = FileMonitor { count += 1 }
    try monitor.watch([root])
    #expect(throws: (any Error).self) { try monitor.watch([root.appendingPathComponent("missing")]) }
    try Data("data".utf8).write(to: root.appendingPathComponent("backup"))
    try await waitUntil { count > 0 }
    monitor.stop()
}

@Test func instanceLockExcludesAnotherInstanceAndReleasesWithoutRemovingFile() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("instance.lock")
    var first: InstanceLock? = try InstanceLock(url: file)
    #expect(first != nil)
    #expect(throws: InstanceLockError.alreadyRunning) { _ = try InstanceLock(url: file) }
    first = nil
    #expect(FileManager.default.fileExists(atPath: file.path))
    let next = try InstanceLock(url: file)
    _ = withExtendedLifetime(next) {
        #expect(throws: InstanceLockError.alreadyRunning) { _ = try InstanceLock(url: file) }
    }
}

@Test func instanceLockRejectsSymlinksAndHardlinks() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("original")
    try Data().write(to: file)
    let symlink = root.appendingPathComponent("symlink")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
    #expect(throws: (any Error).self) { _ = try InstanceLock(url: symlink) }
    let hardlink = root.appendingPathComponent("hardlink")
    try FileManager.default.linkItem(at: file, to: hardlink)
    #expect(throws: InstanceLockError.unsafeLockFile) { _ = try InstanceLock(url: file) }
}
