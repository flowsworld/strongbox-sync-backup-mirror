import Foundation
import Darwin

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
        guard listingDescriptor >= 0 else { throw MirrorError.unsafeFile }
        guard let stream = fdopendir(listingDescriptor) else {
            Darwin.close(listingDescriptor)
            throw MirrorError.unsafeFile
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
        guard errno == 0 else { throw MirrorError.fileOperation(String(cString: strerror(errno))) }
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
        guard validFilename(filename) else { throw MirrorError.unsafeFilename }
        let sourceDirectory = try openDirectory(backup.url.deletingLastPathComponent())
        let sourceName = backup.url.lastPathComponent
        let source = try openFile(sourceName, in: sourceDirectory)
        let (contents, sourceStamp) = try readStable(source)
        guard !contents.isEmpty else { throw MirrorError.emptyBackup }
        guard sourceStamp.size == backup.size, sourceStamp.creationDate == backup.creationDate else { throw MirrorError.changedFile }
        let destination = try openDirectory(targetDirectory)
        // Independent directory descriptors coordinate copies across processes
        // without leaving a lock file in the user's destination.
        try lockDestination(destination)
        defer { flock(destination.value, LOCK_UN) }
        let original = try entryStamp(filename, in: destination)
        if let original {
            guard original.regular else { throw MirrorError.unsafeFile }
            guard !original.sameIdentity(as: sourceStamp) else { throw MirrorError.sameFile }
            let target = try openFile(filename, in: destination)
            let (existing, targetStamp) = try readStable(target)
            guard targetStamp == original else { throw MirrorError.changedFile }
            if existing == contents {
                try verifySource(source, stamp: sourceStamp, contents: contents, name: sourceName, directory: sourceDirectory)
                guard try entryStamp(filename, in: destination) == original else { throw MirrorError.changedFile }
                try verifyDirectories(sourceDirectory, sourceURL: backup.url.deletingLastPathComponent(), destination: destination, destinationURL: targetDirectory)
                return .unchanged
            }
        }
        let temporaryName = ".synccopies-\(UUID().uuidString).tmp"
        let temporary = try Descriptor(openat(destination.value, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
        // Retain temporary files after any failure. A sync client can replace
        // their paths independently of our advisory lock, so deleting by name
        // could remove someone else's file. Successful rename consumes ours.
        try contents.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(temporary.value, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw MirrorError.fileOperation(String(cString: strerror(errno))) }
                written += count
            }
        }
        guard fsync(temporary.value) == 0 else { throw MirrorError.fileOperation(String(cString: strerror(errno))) }
        try verifySource(source, stamp: sourceStamp, contents: contents, name: sourceName, directory: sourceDirectory)
        guard try entryStamp(filename, in: destination) == original else { throw MirrorError.changedFile }
        try verifyDirectories(sourceDirectory, sourceURL: backup.url.deletingLastPathComponent(), destination: destination, destinationURL: targetDirectory)
        guard renameat(destination.value, temporaryName, destination.value, filename) == 0 else {
            throw MirrorError.fileOperation(String(cString: strerror(errno)))
        }
        return .copied
    }

    private static func lockDestination(_ directory: Descriptor) throws {
        while flock(directory.value, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            if errno == EWOULDBLOCK { throw MirrorError.targetBusy }
            throw MirrorError.fileOperation(String(cString: strerror(errno)))
        }
    }

    private static func verifyDirectories(_ source: Descriptor, sourceURL: URL, destination: Descriptor, destinationURL: URL) throws {
        let currentSource = try openDirectory(sourceURL)
        let currentDestination = try openDirectory(destinationURL)
        guard try currentSource.stamp().sameIdentity(as: source.stamp()),
              try currentDestination.stamp().sameIdentity(as: destination.stamp()) else { throw MirrorError.changedFile }
    }

    private static func verifySource(_ source: Descriptor, stamp: FileStamp, contents: Data, name: String, directory: Descriptor) throws {
        let (after, afterStamp) = try readStable(source)
        guard afterStamp == stamp, after == contents, try entryStamp(name, in: directory) == stamp else {
            throw MirrorError.changedFile
        }
    }
}
