import Darwin
import Foundation
import Testing
@testable import SyncCopiesCore

struct UploadFingerprintTests {
    private func withDirectory(_ test: (URL) throws -> Void) throws {
        let candidate = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        guard let resolved = realpath(candidate.path, nil) else { throw CocoaError(.fileReadUnknown) }
        defer { free(resolved) }
        let directory = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try test(directory)
    }

    @Test func hashesKnownLocalBytesWithoutChangingThem() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("example.kdbx")
            try Data("abc".utf8).write(to: file)
            let fingerprint = try UploadFingerprint.read(directory: directory, filename: "example.kdbx")
            #expect(fingerprint.size == 3)
            #expect(fingerprint.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
            #expect(fingerprint.md5 == "900150983cd24fb0d6963f7d28e17f72")
            #expect(try Data(contentsOf: file) == Data("abc".utf8))
        }
    }

    @Test func rejectsPathReplacementEvenWithIdenticalBytes() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("example.kdbx")
            try Data("abc".utf8).write(to: file)
            let snapshot = try UploadFingerprint.snapshot(directory: directory, filename: "example.kdbx")
            try FileManager.default.moveItem(at: file, to: directory.appendingPathComponent("old.kdbx"))
            try Data("abc".utf8).write(to: file)
            #expect(throws: MirrorError.changedFile) { try snapshot.validate() }
        }
    }

    @Test func permitsMetadataOnlyChangesButRejectsChangedContent() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("example.kdbx")
            try Data("abc".utf8).write(to: file)
            let snapshot = try UploadFingerprint.snapshot(directory: directory, filename: "example.kdbx")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try snapshot.validate()
            try Data("xyz".utf8).write(to: file)
            #expect(throws: MirrorError.changedFile) { try snapshot.validate() }
        }
    }

    @Test func rejectsEmptyFilesLinksAndUnsafeNames() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("example.kdbx")
            try Data().write(to: file)
            #expect(throws: MirrorError.emptyBackup) { try UploadFingerprint.read(directory: directory, filename: "example.kdbx") }
            try Data("abc".utf8).write(to: file)
            let alias = directory.appendingPathComponent("alias.kdbx")
            #expect(Darwin.link(file.path, alias.path) == 0)
            #expect(throws: MirrorError.unsafeFile) { try UploadFingerprint.read(directory: directory, filename: "example.kdbx") }
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
            #expect(throws: MirrorError.unsafeFile) { try UploadFingerprint.read(directory: directory, filename: "alias.kdbx") }
            for name in ["../example.kdbx", "/example.kdbx", ".synccopies.lock", ""] {
                #expect(throws: MirrorError.unsafeFilename) { try UploadFingerprint.read(directory: directory, filename: name) }
            }
        }
    }
}
