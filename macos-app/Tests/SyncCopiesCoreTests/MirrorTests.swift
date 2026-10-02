import Darwin
import Foundation
import Testing
@testable import SyncCopiesCore

struct MirrorTests {
    @Test func concurrentReplacementIsReportedAndTheDisplacedNewerFileSurvives() throws {
        try fixture { root, target, backup in
            let filename = "database.kdbx"
            let destination = target.appendingPathComponent(filename)
            try Data("previous copy".utf8).write(to: destination)
            let incoming = root.appendingPathComponent("incoming")
            try Data("newer external copy".utf8).write(to: incoming)
            let incomingIdentity = try openFile("incoming", in: openDirectory(root)).stamp()
            #expect(throws: MirrorError.changedFile) {
                try MirrorEngine.copy(backup: backup, to: target, filename: filename, publish: { fromFD, from, toFD, to, flags in
                    #expect(Darwin.rename(incoming.path, destination.path) == 0)
                    return renameatx_np(fromFD, from, toFD, to, flags)
                })
            }
            let directory = try openDirectory(target)
            let preserved = try FileManager.default.contentsOfDirectory(atPath: target.path).filter {
                try entryStamp($0, in: directory)?.sameIdentity(as: incomingIdentity) == true
            }
            #expect(preserved.count == 1)
            if let name = preserved.first {
                #expect(try Data(contentsOf: target.appendingPathComponent(name)) == Data("newer external copy".utf8))
            }
        }
    }

    @Test func concurrentlyCreatedDestinationIsNeverReplaced() throws {
        try fixture { _, target, backup in
            let filename = "database.kdbx"
            let destination = target.appendingPathComponent(filename)
            #expect(throws: MirrorError.changedFile) {
                try MirrorEngine.copy(backup: backup, to: target, filename: filename, publish: { fromFD, from, toFD, to, flags in
                    try Data("new external destination".utf8).write(to: destination)
                    return renameatx_np(fromFD, from, toFD, to, flags)
                })
            }
            #expect(try Data(contentsOf: destination) == Data("new external destination".utf8))
            let residues = try FileManager.default.contentsOfDirectory(atPath: target.path).filter { $0 != filename }
            #expect(residues.count == 1)
            if let name = residues.first {
                #expect(try Data(contentsOf: target.appendingPathComponent(name)) == Data("local encrypted backup".utf8))
            }
        }
    }

    @Test func concurrentInPlaceWriteWithRestoredMtimeIsRetained() throws {
        try fixture { _, target, backup in
            let filename = "database.kdbx"
            let destination = target.appendingPathComponent(filename)
            try Data("previous copy".utf8).write(to: destination)
            let descriptor = try openFile(filename, in: openDirectory(target))
            let original = try descriptor.stamp()
            #expect(throws: MirrorError.changedFile) {
                try MirrorEngine.copy(backup: backup, to: target, filename: filename, publish: { fromFD, from, toFD, to, flags in
                    // Change bytes without replacing the inode, size or advertised mtime.
                    let writer = try Descriptor(open(destination.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC))
                    try Data("modified copy".utf8).withUnsafeBytes { try writeAll($0, to: writer) }
                    var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                                 timespec(tv_sec: original.modifiedSeconds, tv_nsec: original.modifiedNanos)]
                    #expect(futimens(writer.value, &times) == 0)
                    return renameatx_np(fromFD, from, toFD, to, flags)
                })
            }
            let directory = try openDirectory(target)
            let preserved = try FileManager.default.contentsOfDirectory(atPath: target.path).filter {
                try entryStamp($0, in: directory)?.sameIdentity(as: original) == true
            }
            #expect(preserved.count == 1)
            if let name = preserved.first {
                #expect(try Data(contentsOf: target.appendingPathComponent(name)) == Data("modified copy".utf8))
            }
        }
    }

    @Test func concurrentRemovalAndUnsupportedAtomicRenameLeaveCopiesIntact() throws {
        for unsupported in [false, true] {
            try fixture { _, target, backup in
                let filename = "database.kdbx"
                let destination = target.appendingPathComponent(filename)
                try Data("previous copy".utf8).write(to: destination)
                do {
                    _ = try MirrorEngine.copy(backup: backup, to: target, filename: filename, publish: { fromFD, from, toFD, to, flags in
                        if unsupported { errno = ENOTSUP; return -1 }
                        try FileManager.default.removeItem(at: destination)
                        return renameatx_np(fromFD, from, toFD, to, flags)
                    })
                    Issue.record("A conflicted or unsupported publication reported success")
                } catch {
                    #expect(error as? MirrorError == (unsupported ? fileOperationError(ENOTSUP) : .changedFile))
                }
                if unsupported { #expect(try Data(contentsOf: destination) == Data("previous copy".utf8)) }
                else { #expect(!FileManager.default.fileExists(atPath: destination.path)) }
                let residues = try FileManager.default.contentsOfDirectory(atPath: target.path).filter { $0 != filename }
                #expect(residues.count == 1)
                if let name = residues.first {
                    #expect(try Data(contentsOf: target.appendingPathComponent(name)) == Data("local encrypted backup".utf8))
                }
            }
        }
    }

    @Test func anotherWriterAfterExchangeKeepsItsDestinationAndTheDisplacedOriginal() throws {
        try fixture { root, target, backup in
            let filename = "database.kdbx"
            let destination = target.appendingPathComponent(filename)
            try Data("previous copy".utf8).write(to: destination)
            let original = try openFile(filename, in: openDirectory(target)).stamp()
            let incoming = root.appendingPathComponent("incoming")
            try Data("latest external copy".utf8).write(to: incoming)
            #expect(throws: MirrorError.changedFile) {
                try MirrorEngine.copy(backup: backup, to: target, filename: filename, publish: { fromFD, from, toFD, to, flags in
                    let result = renameatx_np(fromFD, from, toFD, to, flags)
                    #expect(result == 0)
                    #expect(Darwin.rename(incoming.path, destination.path) == 0)
                    return result
                })
            }
            #expect(try Data(contentsOf: destination) == Data("latest external copy".utf8))
            let directory = try openDirectory(target)
            let retained = try FileManager.default.contentsOfDirectory(atPath: target.path).filter {
                try entryStamp($0, in: directory)?.sameIdentity(as: original) == true
            }
            #expect(retained.count == 1)
            if let name = retained.first {
                #expect(try Data(contentsOf: target.appendingPathComponent(name)) == Data("previous copy".utf8))
            }
        }
    }

    private func fixture(_ body: (URL, URL, BackupInfo) throws -> Void) throws {
        let candidate = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        defer { try! FileManager.default.removeItem(at: candidate) }
        guard let resolved = realpath(candidate.path, nil) else { throw MirrorError.unsafeFile }
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("backup.bak")
        try Data("local encrypted backup".utf8).write(to: source)
        let stamp = try openFile("backup.bak", in: openDirectory(root)).stamp()
        try body(root, target, BackupInfo(url: source, creationDate: stamp.creationDate, size: stamp.size))
    }
}
