import Foundation
import Darwin
import CryptoKit

public struct BackupInfo: Sendable {
    public let url: URL
    public let creationDate: Date
    public let size: Int64
    public init(url: URL, creationDate: Date, size: Int64) {
        self.url = url; self.creationDate = creationDate; self.size = size
    }
}

public enum StrongboxBackups {
    public static func newest(for database: Database, groupContainer: URL) throws -> BackupInfo {
        let folder = groupContainer.appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent(database.id.uuidString, isDirectory: true)
        let directory = try openDirectory(folder)
        // Listing via the descriptor keeps discovery anchored even if the path is replaced.
        let listingDescriptor = dup(directory.value)
        guard listingDescriptor >= 0 else { throw fileOperationError() }
        guard let stream = fdopendir(listingDescriptor) else {
            let error = fileOperationError()
            Darwin.close(listingDescriptor)
            throw error
        }
        defer { closedir(stream) }
        var newest: (String, FileStamp)?
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name.hasSuffix(".bak") else { continue }
            guard let stamp = try entryStamp(name, in: directory), stamp.regular,
                  stamp.birthSeconds > 0 else { throw MirrorError.unsafeFile }
            if newest == nil || (stamp.creationDate, name) > (newest!.1.creationDate, newest!.0) {
                newest = (name, stamp)
            }
            errno = 0
        }
        guard errno == 0 else { throw fileOperationError() }
        guard let (name, stamp) = newest else { throw MirrorError.missingBackup }
        guard stamp.size > 0 else { throw MirrorError.emptyBackup }
        let file = try openFile(name, in: directory)
        guard try file.stamp() == stamp else { throw MirrorError.changedFile }
        return BackupInfo(url: folder.appendingPathComponent(name), creationDate: stamp.creationDate, size: stamp.size)
    }
}

public enum CopyResult: Sendable, Equatable { case copied, unchanged }

public enum MirrorEngine {
    public static func copy(backup: BackupInfo, to targetDirectory: URL, filename: String) throws -> CopyResult {
        try copy(backup: backup, to: targetDirectory, filename: filename, publish: { fromFD, from, toFD, to, flags in
            renameatx_np(fromFD, from, toFD, to, flags)
        })
    }

    // The publication syscall boundary permits deterministic external-writer fixtures.
    static func copy(backup: BackupInfo, to targetDirectory: URL, filename: String,
                     publish: (Int32, String, Int32, String, UInt32) throws -> Int32) throws -> CopyResult {
        guard validDestinationFilename(filename) else { throw MirrorError.unsafeFilename }
        let sourceDirectory = try openDirectory(backup.url.deletingLastPathComponent(), accessRole: .source)
        let sourceName = backup.url.lastPathComponent
        let source = try openFile(sourceName, in: sourceDirectory)
        let sourceStamp = try source.stamp()
        guard sourceStamp.size > 0 else { throw MirrorError.emptyBackup }
        guard sourceStamp.size == backup.size, sourceStamp.creationDate == backup.creationDate else { throw MirrorError.changedFile }
        let destination = try openDirectory(targetDirectory)
        let destinationLock = try DestinationLock.acquire(in: destination)
        defer { withExtendedLifetime(destinationLock) {} }
        let original = try entryStamp(filename, in: destination)
        var originalDigest: SHA256.Digest?
        if let original {
            guard original.regular else { throw MirrorError.unsafeFile }
            guard !original.sameIdentity(as: sourceStamp) else { throw MirrorError.sameFile }
            let target = try openFile(filename, in: destination)
            if try sameContents(source, stamp: sourceStamp, target, stamp: original) {
                try verifySource(source, stamp: sourceStamp, snapshot: target, snapshotStamp: original, name: sourceName, directory: sourceDirectory)
                guard try entryStamp(filename, in: destination) == original else { throw MirrorError.changedFile }
                try verifyDirectories(sourceDirectory, sourceURL: backup.url.deletingLastPathComponent(), destination: destination, destinationURL: targetDirectory)
                try destinationLock.validate()
                return .unchanged
            }
            originalDigest = try digest(target, stamp: original)
        }
        let temporaryName = ".synccopies-\(UUID().uuidString).tmp"
        var writer: Descriptor? = try Descriptor(openat(destination.value, temporaryName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
        // An exchange retains the displaced entry here, including a concurrent
        // sync client's newer inode. Even successful copies keep the predecessor:
        // a separate identity check and unlink could delete a replacement instead.
        try copyStable(source, stamp: sourceStamp, to: writer!)
        guard fsync(writer!.value) == 0 else { throw fileOperationError() }
        let temporary = try finishCopiedFile(&writer, name: temporaryName, in: destination)
        let temporaryStamp = try temporary.stamp()
        try verifySource(source, stamp: sourceStamp, snapshot: temporary, snapshotStamp: temporaryStamp, name: sourceName, directory: sourceDirectory)
        guard try entryStamp(temporaryName, in: destination) == temporaryStamp,
              try entryStamp(filename, in: destination) == original else { throw MirrorError.changedFile }
        try verifyDirectories(sourceDirectory, sourceURL: backup.url.deletingLastPathComponent(), destination: destination, destinationURL: targetDirectory)
        try destinationLock.validate()
        let flags = UInt32(original == nil ? RENAME_EXCL : RENAME_SWAP)
        guard try publish(destination.value, temporaryName, destination.value, filename, flags) == 0 else {
            let failure = errno
            if failure == EEXIST || failure == ENOENT { throw MirrorError.changedFile }
            // Unsupported atomic operations must not fall back to a replacing rename.
            throw fileOperationError(failure)
        }
        let published = try temporary.stamp()
        guard unchangedByRename(published, temporaryStamp),
              try entryStamp(filename, in: destination) == published else { throw MirrorError.changedFile }
        var displaced: FileStamp?
        if let original {
            guard let stamp = try entryStamp(temporaryName, in: destination), unchangedByRename(stamp, original) else {
                throw MirrorError.changedFile
            }
            let previous = try openFile(temporaryName, in: destination)
            guard try digest(previous, stamp: stamp) == originalDigest else { throw MirrorError.changedFile }
            displaced = stamp
        }
        try verifySource(source, stamp: sourceStamp, snapshot: temporary, snapshotStamp: published, name: sourceName, directory: sourceDirectory)
        try verifyDirectories(sourceDirectory, sourceURL: backup.url.deletingLastPathComponent(), destination: destination, destinationURL: targetDirectory)
        try destinationLock.validate()
        guard try entryStamp(filename, in: destination) == published else { throw MirrorError.changedFile }
        if let displaced {
            guard try entryStamp(temporaryName, in: destination) == displaced else { throw MirrorError.changedFile }
        }
        return .copied
    }

    /// An exchange updates ctime on both inodes. Content is checked separately
    /// so an in-place write with a restored mtime cannot hide behind that update.
    private static func unchangedByRename(_ current: FileStamp, _ expected: FileStamp) -> Bool {
        current.sameIdentity(as: expected) && current.size == expected.size && current.mode == expected.mode &&
        current.linkCount == expected.linkCount && current.birthSeconds == expected.birthSeconds &&
        current.birthNanos == expected.birthNanos && current.modifiedSeconds == expected.modifiedSeconds &&
        current.modifiedNanos == expected.modifiedNanos
    }

    private static func digest(_ file: Descriptor, stamp: FileStamp) throws -> SHA256.Digest {
        guard stamp.regular, stamp.size >= 0 else { throw MirrorError.unsafeFile }
        guard try file.stamp() == stamp else { throw MirrorError.changedFile }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        var offset: off_t = 0
        while offset < stamp.size {
            let count = pread(file.value, &buffer, Int(min(off_t(buffer.count), stamp.size - offset)), offset)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw fileOperationError() }
            guard count > 0 else { throw MirrorError.changedFile }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            offset += off_t(count)
        }
        guard try file.stamp() == stamp else { throw MirrorError.changedFile }
        return hasher.finalize()
    }

    private static func verifyDirectories(_ source: Descriptor, sourceURL: URL, destination: Descriptor, destinationURL: URL) throws {
        let currentSource = try openDirectory(sourceURL, accessRole: .source)
        let currentDestination = try openDirectory(destinationURL)
        guard try currentSource.stamp().sameIdentity(as: source.stamp()),
              try currentDestination.stamp().sameIdentity(as: destination.stamp()) else { throw MirrorError.changedFile }
    }

    private static func verifySource(_ source: Descriptor, stamp: FileStamp, snapshot: Descriptor, snapshotStamp: FileStamp, name: String, directory: Descriptor) throws {
        guard try sameContents(source, stamp: stamp, snapshot, stamp: snapshotStamp),
              try entryStamp(name, in: directory) == stamp else {
            throw MirrorError.changedFile
        }
    }
}
