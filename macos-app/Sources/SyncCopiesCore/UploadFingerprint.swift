import CryptoKit
import Darwin
import Foundation

/// Immutable read-only descriptors retain file identity across a remote check.
/// Concurrent validation uses pread and independent buffers, never shared offsets.
public final class UploadLocalSnapshot: @unchecked Sendable {
    public let fingerprint: UploadLocalFingerprint
    private let directory: Descriptor
    private let file: Descriptor
    private let stamp: FileStamp
    private let directoryStamp: FileStamp
    private let directoryURL: URL
    private let filename: String

    fileprivate init(directory: Descriptor, file: Descriptor, stamp: FileStamp, directoryStamp: FileStamp,
                     directoryURL: URL, filename: String, fingerprint: UploadLocalFingerprint) {
        self.directory = directory
        self.file = file
        self.stamp = stamp
        self.directoryStamp = directoryStamp
        self.directoryURL = directoryURL
        self.filename = filename
        self.fingerprint = fingerprint
    }

    public func validate() throws {
        let current = try file.stamp()
        guard current.regular, current.linkCount == 1, current.sameIdentity(as: stamp), current.size == stamp.size,
              current.modifiedSeconds == stamp.modifiedSeconds, current.modifiedNanos == stamp.modifiedNanos else {
            throw MirrorError.changedFile
        }
        // The helper permits ctime-only metadata changes after proving unchanged bytes.
        if current != stamp {
            guard try UploadFingerprint.hash(file: file, stamp: current) == fingerprint else { throw MirrorError.changedFile }
        }
        guard try file.stamp() == current, try entryStamp(filename, in: directory) == current,
              try openDirectory(directoryURL).stamp().sameIdentity(as: directoryStamp) else { throw MirrorError.changedFile }
    }
}

public enum UploadFingerprint {
    public static func read(directory: URL, filename: String) throws -> UploadLocalFingerprint {
        try snapshot(directory: directory, filename: filename).fingerprint
    }

    /// Hash a stable local copy without following links. Keep the result alive
    /// through the provider response, then validate before publishing confirmation.
    public static func snapshot(directory url: URL, filename: String) throws -> UploadLocalSnapshot {
        guard validDestinationFilename(filename) else { throw MirrorError.unsafeFilename }
        let directory = try openDirectory(url)
        let directoryStamp = try directory.stamp()
        if let entry = try entryStamp(filename, in: directory) {
            guard entry.regular, entry.linkCount == 1 else { throw MirrorError.unsafeFile }
        }
        let file = try openFile(filename, in: directory)
        let stamp = try file.stamp()
        guard stamp.regular, stamp.linkCount == 1, stamp.size >= 0 else { throw MirrorError.unsafeFile }
        guard stamp.size > 0 else { throw MirrorError.emptyBackup }
        let fingerprint = try hash(file: file, stamp: stamp)
        let result = UploadLocalSnapshot(directory: directory, file: file, stamp: stamp, directoryStamp: directoryStamp,
                                         directoryURL: url, filename: filename, fingerprint: fingerprint)
        try result.validate()
        return result
    }

    fileprivate static func hash(file: Descriptor, stamp: FileStamp) throws -> UploadLocalFingerprint {
        var sha256 = SHA256()
        var md5 = Insecure.MD5()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        var offset: off_t = 0
        while offset < stamp.size {
            let request = Int(min(off_t(buffer.count), stamp.size - offset))
            let count = buffer.withUnsafeMutableBytes { bytes in
                pread(file.value, bytes.baseAddress, request, offset)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw fileOperationError() }
            guard count > 0 else { throw MirrorError.changedFile }
            let chunk = Data(buffer.prefix(count))
            sha256.update(data: chunk)
            md5.update(data: chunk)
            offset += off_t(count)
        }
        guard try file.stamp() == stamp else { throw MirrorError.changedFile }
        return try UploadLocalFingerprint(size: Int64(stamp.size),
                                          sha256: sha256.finalize().map { String(format: "%02x", $0) }.joined(),
                                          md5: md5.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
