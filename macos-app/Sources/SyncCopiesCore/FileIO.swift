import Foundation
import Darwin

public enum MirrorError: Error, LocalizedError, LocalizedMessageError, Equatable {
    case invalidMetadata, invalidDatabase, inconsistentIdentifier
    case missingBackup, unsafeFile, emptyBackup, changedFile, unsafeFilename, sameFile
    case targetBusy, permissionDenied, sourcePermissionDenied
    case fileOperation(String)

    public var errorDescription: String? { message.rendered() }

    public var message: LocalizedMessage {
        switch self {
        case .invalidMetadata: return LocalizedMessage(key: "The Strongbox metadata has an unknown or invalid format.")
        case .invalidDatabase: return LocalizedMessage(key: "The Strongbox Sync database cannot be uniquely identified.")
        case .inconsistentIdentifier: return LocalizedMessage(key: "The Strongbox database identifiers do not match.")
        case .missingBackup: return LocalizedMessage(key: "No local backup was found for this database.")
        case .unsafeFile: return LocalizedMessage(key: "A file path is unsafe or contains a symbolic link.")
        case .emptyBackup: return LocalizedMessage(key: "The latest backup is empty. The existing copy is preserved.")
        case .changedFile: return LocalizedMessage(key: "A file changed during copying. Please try again.")
        case .unsafeFilename: return LocalizedMessage(key: "The filename is invalid.")
        case .sameFile: return LocalizedMessage(key: "Source and destination must not be the same file.")
        case .permissionDenied: return LocalizedMessage(key: "File access was denied.")
        case .sourcePermissionDenied: return LocalizedMessage(key: "Read access to the Strongbox backup was denied.")
        case .targetBusy: return LocalizedMessage(key: "A copy is already running in this destination folder. Please try again.")
        case .fileOperation(let reason):
            if let code = (1...ELAST).first(where: { String(cString: strerror($0)) == reason }) {
                let knownReasons: Set<String> = [
                    "No such file or directory", "Permission denied", "Operation not permitted",
                    "No route to host", "Network is down", "Network is unreachable", "Input/output error",
                    "No space left on device", "Read-only file system", "Operation timed out",
                    "Device not configured", "Resource busy", "Invalid argument", "Connection refused",
                    "Socket is not connected", "Operation not supported", "File name too long",
                    "Too many open files", "Interrupted system call", "Is a directory", "Not a directory",
                ]
                let detail = knownReasons.contains(reason)
                    ? LocalizedMessage(key: reason)
                    : LocalizedMessage(key: "File operation failed (code %@).", arguments: [String(code)])
                return LocalizedMessage(key: "The file could not be processed: %@", causes: [detail])
            }
            return LocalizedMessage(key: "The file could not be processed. Technical detail (original language): %@", arguments: [reason])
        }
    }
}

/// Conservative identity for a destination name, including Unicode case equivalents
/// that collide on the usual case-insensitive macOS volumes.
public func normalizedDestinationName(_ filename: String) -> String {
    filename.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .precomposedStringWithCanonicalMapping
}

func validFilename(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
}

func validDestinationFilename(_ name: String) -> Bool {
    validFilename(name) && normalizedDestinationName(name) != DestinationLock.filename
}

enum FileAccessRole {
    case unspecified, source
}

func fileOperationError(_ code: Int32 = errno, role: FileAccessRole = .unspecified) -> MirrorError {
    if code == EACCES || code == EPERM {
        return role == .source ? .sourcePermissionDenied : .permissionDenied
    }
    return .fileOperation(String(cString: strerror(code)))
}

final class Descriptor {
    let value: Int32
    let accessRole: FileAccessRole
    init(_ value: Int32, accessRole: FileAccessRole = .unspecified) throws {
        guard value >= 0 else { throw fileOperationError(role: accessRole) }
        self.value = value
        self.accessRole = accessRole
    }
    deinit { Darwin.close(value) }
    func stamp() throws -> FileStamp {
        var info = stat()
        guard fstat(value, &info) == 0 else { throw fileOperationError(role: accessRole) }
        return FileStamp(info)
    }
}

struct FileStamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let mode: mode_t
    let linkCount: nlink_t
    let birthSeconds: Int
    let birthNanos: Int
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    init(_ s: stat) {
        device = s.st_dev; inode = s.st_ino; size = s.st_size; mode = s.st_mode
        linkCount = s.st_nlink
        birthSeconds = s.st_birthtimespec.tv_sec; birthNanos = s.st_birthtimespec.tv_nsec
        modifiedSeconds = s.st_mtimespec.tv_sec; modifiedNanos = s.st_mtimespec.tv_nsec
        changedSeconds = s.st_ctimespec.tv_sec; changedNanos = s.st_ctimespec.tv_nsec
    }
    var regular: Bool { mode & S_IFMT == S_IFREG }
    var creationDate: Date { Date(timeIntervalSince1970: Double(birthSeconds) + Double(birthNanos) / 1_000_000_000) }
    func sameIdentity(as other: FileStamp) -> Bool { device == other.device && inode == other.inode }
}

func openDirectory(_ url: URL, accessRole: FileAccessRole = .unspecified) throws -> Descriptor {
    guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else { throw MirrorError.unsafeFile }
    // Ancestors need search access only. A scoped folder grant does not allow
    // reading its parents. Open the final directory for listing after traversal.
    var current = try Descriptor(Darwin.open("/", O_SEARCH | O_DIRECTORY | O_CLOEXEC), accessRole: accessRole)
    for component in url.path.split(separator: "/") {
        guard component != ".", component != ".." else { throw MirrorError.unsafeFile }
        current = try Descriptor(openat(current.value, String(component), O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), accessRole: accessRole)
    }
    return try Descriptor(openat(current.value, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), accessRole: accessRole)
}

func openFile(_ name: String, in directory: Descriptor) throws -> Descriptor {
    guard validFilename(name) else { throw MirrorError.unsafeFilename }
    let file = try Descriptor(openat(directory.value, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC), accessRole: directory.accessRole)
    guard try file.stamp().regular else { throw MirrorError.unsafeFile }
    return file
}

func readStable(_ file: Descriptor, maximumBytes: Int? = nil) throws -> (Data, FileStamp) {
    let before = try file.stamp()
    guard before.regular, before.size >= 0 else { throw MirrorError.unsafeFile }
    if let maximumBytes, before.size > maximumBytes { throw MirrorError.invalidMetadata }
    guard lseek(file.value, 0, SEEK_SET) >= 0 else { throw fileOperationError(role: file.accessRole) }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = Darwin.read(file.value, &buffer, buffer.count)
        if count < 0 {
            if errno == EINTR { continue }
            throw fileOperationError(role: file.accessRole)
        }
        if count == 0 { break }
        data.append(contentsOf: buffer.prefix(count))
        if let maximumBytes, data.count > maximumBytes { throw MirrorError.invalidMetadata }
    }
    guard try file.stamp() == before, Int64(data.count) == before.size else { throw MirrorError.changedFile }
    return (data, before)
}

func entryStamp(_ name: String, in directory: Descriptor) throws -> FileStamp? {
    var info = stat()
    if fstatat(directory.value, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return FileStamp(info) }
    if errno == ENOENT { return nil }
    throw fileOperationError(role: directory.accessRole)
}

/// Consume the sole writable descriptor after fsync. SMB may publish final
/// timestamps only when its writer closes, so validate through a fresh reader.
func finishCopiedFile(_ writer: inout Descriptor?, name: String, in directory: Descriptor) throws -> Descriptor {
    guard writer != nil else { throw MirrorError.unsafeFile }
    let written = try writer!.stamp()
    guard written.regular, written.linkCount == 1 else { throw MirrorError.unsafeFile }
    writer = nil
    // Refresh the anchored entry after SMB publishes the writer's close, and
    // reject a removed or replaced path before opening the read-only snapshot.
    guard let published = try entryStamp(name, in: directory) else { throw MirrorError.changedFile }
    guard published.regular, published.linkCount == 1 else { throw MirrorError.unsafeFile }
    guard published.sameIdentity(as: written), published.size == written.size else { throw MirrorError.changedFile }
    let reader = try openFile(name, in: directory)
    let reopened = try reader.stamp()
    guard reopened.regular, reopened.linkCount == 1 else { throw MirrorError.unsafeFile }
    guard reopened.sameIdentity(as: written), reopened.size == written.size else { throw MirrorError.changedFile }
    return reader
}

// Both backup copying and byte validation use fixed-size buffers. Backup size
// must never determine memory allocation or a single Darwin write request.
private let fileIOChunkSize = 1024 * 1024

func writeAll(_ bytes: UnsafeRawBufferPointer, to file: Descriptor) throws {
    var written = 0
    while written < bytes.count {
        let request = min(fileIOChunkSize, bytes.count - written)
        let count = Darwin.write(file.value, bytes.baseAddress!.advanced(by: written), request)
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else { throw fileOperationError(role: file.accessRole) }
        guard count > 0 else { throw MirrorError.fileOperation(String(cString: strerror(EIO))) }
        written += count
    }
}

private func readChunk(_ file: Descriptor, into bytes: UnsafeMutableRawBufferPointer, at offset: off_t) throws {
    var received = 0
    while received < bytes.count {
        let count = pread(file.value, bytes.baseAddress!.advanced(by: received), bytes.count - received, offset + off_t(received))
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else { throw fileOperationError(role: file.accessRole) }
        guard count > 0 else { throw MirrorError.changedFile }
        received += count
    }
}

func copyStable(_ source: Descriptor, stamp: FileStamp, to target: Descriptor) throws {
    guard stamp.regular, stamp.size >= 0 else { throw MirrorError.unsafeFile }
    guard try source.stamp() == stamp else { throw MirrorError.changedFile }
    var buffer = [UInt8](repeating: 0, count: fileIOChunkSize)
    var offset: off_t = 0
    while offset < stamp.size {
        let count = Int(min(off_t(buffer.count), stamp.size - offset))
        try buffer.withUnsafeMutableBytes { buffer in
            let chunk = UnsafeMutableRawBufferPointer(rebasing: buffer[..<count])
            try readChunk(source, into: chunk, at: offset)
            try writeAll(UnsafeRawBufferPointer(chunk), to: target)
        }
        offset += off_t(count)
    }
    guard try source.stamp() == stamp else { throw MirrorError.changedFile }
}

func sameContents(_ first: Descriptor, stamp firstStamp: FileStamp, _ second: Descriptor, stamp secondStamp: FileStamp) throws -> Bool {
    guard firstStamp.regular, secondStamp.regular, firstStamp.size >= 0, secondStamp.size >= 0 else { throw MirrorError.unsafeFile }
    guard try first.stamp() == firstStamp, try second.stamp() == secondStamp else { throw MirrorError.changedFile }
    guard firstStamp.size == secondStamp.size else { return false }
    var firstBuffer = [UInt8](repeating: 0, count: fileIOChunkSize)
    var secondBuffer = [UInt8](repeating: 0, count: fileIOChunkSize)
    var offset: off_t = 0
    var equal = true
    while offset < firstStamp.size {
        let count = Int(min(off_t(firstBuffer.count), firstStamp.size - offset))
        let chunksEqual = try firstBuffer.withUnsafeMutableBytes { firstBytes in
            try secondBuffer.withUnsafeMutableBytes { secondBytes in
                try readChunk(first, into: UnsafeMutableRawBufferPointer(rebasing: firstBytes[..<count]), at: offset)
                try readChunk(second, into: UnsafeMutableRawBufferPointer(rebasing: secondBytes[..<count]), at: offset)
                return memcmp(firstBytes.baseAddress!, secondBytes.baseAddress!, count) == 0
            }
        }
        if !chunksEqual {
            equal = false
            break
        }
        offset += off_t(count)
    }
    guard try first.stamp() == firstStamp, try second.stamp() == secondStamp else { throw MirrorError.changedFile }
    return equal
}
