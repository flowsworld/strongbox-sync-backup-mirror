import Foundation
import Darwin

/// Keep the lock for the whole copy, including validation and the final rename.
final class DestinationLock {
    static let filename = ".synccopies.lock"

    private let directory: Descriptor
    private var file: Descriptor?
    private var fileLocked = false
    private let reservation: DirectoryIdentity?

    private init(directory: Descriptor, file: Descriptor?, reservation: DirectoryIdentity?) {
        self.directory = directory
        self.file = file
        self.reservation = reservation
    }

    /// `forceFileLock` lets local tests exercise the SMB fallback without a share.
    static func acquire(in directory: Descriptor, forceFileLock: Bool = false) throws -> DestinationLock {
        if !forceFileLock {
            while flock(directory.value, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                if code == EINTR { continue }
                if code == EWOULDBLOCK { throw MirrorError.targetBusy }
                if code == EISDIR || code == ENOTSUP {
                    return try acquireFileLock(in: directory)
                }
                throw fileOperationError(code)
            }
            return DestinationLock(directory: directory, file: nil, reservation: nil)
        }
        return try acquireFileLock(in: directory)
    }

    private static func acquireFileLock(in directory: Descriptor) throws -> DestinationLock {
        let identity = DirectoryIdentity(try directory.stamp())
        // SMB can let separate descriptors in one process acquire the same flock.
        // Reserve before opening, since closing another descriptor can also affect
        // process-scoped server locks.
        try reservations.insert(identity)
        let lock = DestinationLock(directory: directory, file: nil, reservation: identity)
        let original = try entryStamp(filename, in: directory)
        if let original { try validateLockFile(original) }
        lock.file = try Descriptor(openat(directory.value, filename,
                                          O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600))
        let opened = try lock.file!.stamp()
        try validateLockFile(opened)
        if let original, !opened.sameIdentity(as: original) { throw MirrorError.changedFile }
        // The guard closes the descriptor and releases the reservation on every
        // failure. Never truncate or unlink a shared lock file.
        try lock.validate()
        while flock(lock.file!.value, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            if code == EWOULDBLOCK { throw MirrorError.targetBusy }
            throw fileOperationError(code)
        }
        lock.fileLocked = true
        try lock.validate()
        return lock
    }

    func validate() throws {
        guard let file else { return }
        let held = try file.stamp()
        try Self.validateLockFile(held)
        guard let current = try entryStamp(Self.filename, in: directory) else { throw MirrorError.changedFile }
        try Self.validateLockFile(current)
        guard current.sameIdentity(as: held) else { throw MirrorError.changedFile }
    }

    private static func validateLockFile(_ stamp: FileStamp) throws {
        guard stamp.regular, stamp.linkCount == 1 else { throw MirrorError.unsafeFile }
    }

    deinit {
        if let reservation {
            // SMB can retain a process's lock until its last descriptor closes.
            // Explicitly unlock ours even when an unrelated reader remains open.
            // A failed acquisition must never unlock another owner's server lock.
            if fileLocked, let file { flock(file.value, LOCK_UN) }
            // Close before another in-process copy can acquire this destination.
            file = nil
            Self.reservations.remove(reservation)
        } else {
            flock(directory.value, LOCK_UN)
        }
    }

    private struct DirectoryIdentity: Hashable {
        let device: dev_t
        let inode: ino_t

        init(_ stamp: FileStamp) {
            device = stamp.device
            inode = stamp.inode
        }
    }

    /// All access to `active` is protected by `mutex`.
    private final class Reservations: @unchecked Sendable {
        private let mutex = NSLock()
        private var active: Set<DirectoryIdentity> = []

        func insert(_ identity: DirectoryIdentity) throws {
            mutex.lock()
            defer { mutex.unlock() }
            guard active.insert(identity).inserted else { throw MirrorError.targetBusy }
        }

        func remove(_ identity: DirectoryIdentity) {
            mutex.lock()
            defer { mutex.unlock() }
            active.remove(identity)
        }
    }

    private static let reservations = Reservations()
}
