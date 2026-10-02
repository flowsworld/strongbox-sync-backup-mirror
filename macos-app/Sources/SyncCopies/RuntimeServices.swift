import AppKit
import Darwin
import Foundation
import SyncCopiesCore

/// Owns nonisolated resources so cleanup does not depend on an actor-isolated deinitializer.
private final class SchedulerResources: @unchecked Sendable {
    let timer: any DispatchSourceTimer
    let center: NotificationCenter
    let observer: any NSObjectProtocol

    init(timer: any DispatchSourceTimer, center: NotificationCenter, observer: any NSObjectProtocol) {
        self.timer = timer
        self.center = center
        self.observer = observer
    }

    deinit {
        timer.cancel()
        center.removeObserver(observer)
    }
}

@MainActor
final class AppScheduler {
    private let interval: TimeInterval
    private let wakeCenter: NotificationCenter
    private var resources: SchedulerResources?
    private var generation = UUID()
    private var onTrigger: (@MainActor @Sendable () -> Void)?

    init(interval: TimeInterval = 15 * 60, wakeCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        precondition(interval > 0 && interval.isFinite)
        self.interval = interval
        self.wakeCenter = wakeCenter
    }

    func start(onTrigger: @escaping @MainActor @Sendable () -> Void) {
        stop()
        self.onTrigger = onTrigger
        let current = generation
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { @Sendable [weak self] in
            Task { @MainActor [weak self] in self?.trigger(generation: current) }
        }
        let observer = wakeCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.trigger(generation: current) }
        }
        resources = SchedulerResources(timer: timer, center: wakeCenter, observer: observer)
        timer.resume()
    }

    func stop() {
        generation = UUID()
        onTrigger = nil
        resources = nil
    }

    private func trigger(generation expected: UUID) {
        guard expected == generation else { return }
        onTrigger?()
    }
}

enum InstanceLockError: LocalizedError, LocalizedMessageError, Equatable {
    case alreadyRunning
    case unsafeLockFile

    var errorDescription: String? { message.rendered() }

    var message: LocalizedMessage {
        switch self {
        case .alreadyRunning: LocalizedMessage(key: "Another instance of the app is already running. Please close it.")
        case .unsafeLockFile: LocalizedMessage(key: "The app lock file cannot be accessed safely.")
        }
    }
}

/// A persistent inode coordinates processes. Removing it could let another process lock a different inode.
final class InstanceLock {
    private let descriptor: Int32

    init(url: URL) throws {
        guard url.isFileURL else { throw InstanceLockError.unsafeLockFile }
        let opened = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard opened >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        do {
            var metadata = stat()
            guard fstat(opened, &metadata) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(), metadata.st_nlink == 1 else {
                throw InstanceLockError.unsafeLockFile
            }
            guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                if code == EWOULDBLOCK || code == EAGAIN { throw InstanceLockError.alreadyRunning }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            guard fchmod(opened, S_IRUSR | S_IWUSR) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } catch {
            close(opened)
            throw error
        }
        descriptor = opened
    }

    deinit { close(descriptor) }
}
