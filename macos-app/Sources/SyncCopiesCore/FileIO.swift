import Foundation
import Darwin

public enum MirrorError: Error, LocalizedError, Equatable {
    case invalidMetadata, invalidDatabase, inconsistentIdentifier
    case missingBackup, unsafeFile, emptyBackup, changedFile, unsafeFilename, sameFile
    case fileOperation(String)

    public var errorDescription: String? {
        switch self {
        case .invalidMetadata: "Die Strongbox-Metadaten haben ein unbekanntes oder ungültiges Format."
        case .invalidDatabase: "Die Strongbox-Sync-Datenbank ist nicht eindeutig zugeordnet."
        case .inconsistentIdentifier: "Die Kennungen der Strongbox-Datenbank stimmen nicht überein."
        case .missingBackup: "Für diese Datenbank wurde kein lokales Backup gefunden."
        case .unsafeFile: "Ein Dateipfad ist unsicher oder enthält eine Verknüpfung."
        case .emptyBackup: "Das neueste Backup ist leer. Die bestehende Kopie bleibt erhalten."
        case .changedFile: "Eine Datei wurde während des Kopierens verändert. Bitte erneut versuchen."
        case .unsafeFilename: "Der Dateiname ist ungültig."
        case .sameFile: "Quelle und Ziel dürfen nicht dieselbe Datei sein."
        case .fileOperation(let reason): "Die Datei konnte nicht verarbeitet werden: \(reason)"
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

final class Descriptor {
    let value: Int32
    init(_ value: Int32) throws {
        guard value >= 0 else { throw MirrorError.fileOperation(String(cString: strerror(errno))) }
        self.value = value
    }
    deinit { Darwin.close(value) }
    func stamp() throws -> FileStamp {
        var info = stat()
        guard fstat(value, &info) == 0 else { throw MirrorError.fileOperation(String(cString: strerror(errno))) }
        return FileStamp(info)
    }
}

struct FileStamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let mode: mode_t
    let birthSeconds: Int
    let birthNanos: Int
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    init(_ s: stat) {
        device = s.st_dev; inode = s.st_ino; size = s.st_size; mode = s.st_mode
        birthSeconds = s.st_birthtimespec.tv_sec; birthNanos = s.st_birthtimespec.tv_nsec
        modifiedSeconds = s.st_mtimespec.tv_sec; modifiedNanos = s.st_mtimespec.tv_nsec
        changedSeconds = s.st_ctimespec.tv_sec; changedNanos = s.st_ctimespec.tv_nsec
    }
    var regular: Bool { mode & S_IFMT == S_IFREG }
    var creationDate: Date { Date(timeIntervalSince1970: Double(birthSeconds) + Double(birthNanos) / 1_000_000_000) }
    func sameIdentity(as other: FileStamp) -> Bool { device == other.device && inode == other.inode }
}

func openDirectory(_ url: URL) throws -> Descriptor {
    guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else { throw MirrorError.unsafeFile }
    // Ancestors need search access only. A scoped folder grant does not allow
    // reading its parents. Open the final directory for listing after traversal.
    var current = try Descriptor(Darwin.open("/", O_SEARCH | O_DIRECTORY | O_CLOEXEC))
    for component in url.path.split(separator: "/") {
        guard component != ".", component != ".." else { throw MirrorError.unsafeFile }
        current = try Descriptor(openat(current.value, String(component), O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
    }
    return try Descriptor(openat(current.value, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
}

func openFile(_ name: String, in directory: Descriptor) throws -> Descriptor {
    guard validFilename(name) else { throw MirrorError.unsafeFilename }
    let file = try Descriptor(openat(directory.value, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
    guard try file.stamp().regular else { throw MirrorError.unsafeFile }
    return file
}

func readStable(_ file: Descriptor, maximumBytes: Int? = nil) throws -> (Data, FileStamp) {
    let before = try file.stamp()
    guard before.regular, before.size >= 0 else { throw MirrorError.unsafeFile }
    if let maximumBytes, before.size > maximumBytes { throw MirrorError.invalidMetadata }
    guard lseek(file.value, 0, SEEK_SET) >= 0 else { throw MirrorError.fileOperation(String(cString: strerror(errno))) }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = Darwin.read(file.value, &buffer, buffer.count)
        if count < 0 {
            if errno == EINTR { continue }
            throw MirrorError.fileOperation(String(cString: strerror(errno)))
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
    throw MirrorError.fileOperation(String(cString: strerror(errno)))
}
