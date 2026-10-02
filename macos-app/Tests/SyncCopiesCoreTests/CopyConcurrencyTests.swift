import Testing
import Foundation
import Darwin
@testable import SyncCopiesCore

struct CopyConcurrencyTests {
    private func fixture(_ body: (URL, URL, BackupInfo) throws -> Void) throws {
        let candidate = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        defer { try! FileManager.default.removeItem(at: candidate) }
        guard let resolved = realpath(candidate.path, nil) else { throw MirrorError.unsafeFile }
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("backup.bak")
        try Data("new encrypted backup".utf8).write(to: source)
        let stamp = try openFile(source.lastPathComponent, in: openDirectory(root)).stamp()
        try body(root, target, BackupInfo(url: source, creationDate: stamp.creationDate, size: stamp.size))
    }

    @Test func directoryLockRejectsIndependentCopyAndReleasesOnClose() throws {
        try fixture { _, target, backup in
            let file = target.appendingPathComponent("database.kdbx")
            let previous = Data("previous encrypted backup".utf8)
            try previous.write(to: file)
            let activeTemporary = target.appendingPathComponent(".synccopies-\(UUID().uuidString).tmp")
            try Data("another writer's partial copy".utf8).write(to: activeTemporary)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: activeTemporary.path)
            var held: Descriptor? = try openDirectory(target)
            #expect(flock(held!.value, LOCK_EX | LOCK_NB) == 0)
            #expect(throws: MirrorError.targetBusy) {
                try MirrorEngine.copy(backup: backup, to: target, filename: file.lastPathComponent)
            }
            #expect(try Data(contentsOf: file) == previous)
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: target.path)) == Set([file.lastPathComponent, activeTemporary.lastPathComponent]))
            held = nil
            let directory = try openDirectory(target)
            let original = try openFile(file.lastPathComponent, in: directory).stamp()
            let foreign = try entryStamp(activeTemporary.lastPathComponent, in: directory)
            #expect(try MirrorEngine.copy(backup: backup, to: target, filename: file.lastPathComponent) == .copied)
            let names = try FileManager.default.contentsOfDirectory(atPath: target.path)
            let retained = try names.filter { try entryStamp($0, in: directory)?.sameIdentity(as: original) == true }
            #expect(retained.count == 1)
            #expect(Set(names) == Set([file.lastPathComponent, activeTemporary.lastPathComponent] + retained))
            #expect(try entryStamp(activeTemporary.lastPathComponent, in: directory) == foreign)
            #expect(try Data(contentsOf: activeTemporary) == Data("another writer's partial copy".utf8))
            if let name = retained.first { #expect(try Data(contentsOf: target.appendingPathComponent(name)) == previous) }
        }
    }

    @Test func temporaryFinalizationClosesWriterAndReopensTheSameFileReadOnly() throws {
        try fixture { _, target, backup in
            let directory = try openDirectory(target)
            let source = try openFile(backup.url.lastPathComponent, in: openDirectory(backup.url.deletingLastPathComponent()))
            let sourceStamp = try source.stamp()
            let name = ".synccopies-finalization.tmp"
            var writer: Descriptor? = try Descriptor(openat(directory.value, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
            try copyStable(source, stamp: sourceStamp, to: writer!)
            #expect(fsync(writer!.value) == 0)
            let written = try writer!.stamp()
            let reader = try finishCopiedFile(&writer, name: name, in: directory)
            #expect(writer == nil)
            #expect(fcntl(reader.value, F_GETFL) & O_ACCMODE == O_RDONLY)
            let readStamp = try reader.stamp()
            #expect(readStamp.sameIdentity(as: written))
            #expect(try sameContents(source, stamp: sourceStamp, reader, stamp: readStamp))
            #expect(try entryStamp(name, in: directory) == readStamp)
        }
    }

    @Test func temporaryFinalizationRejectsMissingAndReplacedPaths() throws {
        try fixture { _, target, _ in
            let directory = try openDirectory(target)
            let name = ".synccopies-finalization.tmp"
            let file = target.appendingPathComponent(name)
            var writer: Descriptor? = try Descriptor(openat(directory.value, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
            let bytes = Data("copied bytes".utf8)
            try bytes.withUnsafeBytes { try writeAll($0, to: writer!) }
            #expect(fsync(writer!.value) == 0)
            // Retain the original inode under another name, then replace its path
            // with identical bytes. Byte equality must not bypass identity checks.
            try FileManager.default.moveItem(at: file, to: target.appendingPathComponent("held-temporary"))
            #expect(throws: MirrorError.changedFile) {
                try finishCopiedFile(&writer, name: name, in: directory)
            }
            #expect(writer == nil)
            writer = try Descriptor(openat(directory.value, "held-temporary", O_RDWR | O_NOFOLLOW | O_CLOEXEC))
            try bytes.write(to: file)
            #expect(throws: MirrorError.changedFile) {
                try finishCopiedFile(&writer, name: name, in: directory)
            }
            #expect(writer == nil)
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test func interruptedCopiesAndUnrelatedFilesSurviveFailedAndSuccessfulCopies() throws {
        try fixture { root, target, backup in
            let stale = ".synccopies-\(UUID().uuidString).tmp"
            let unrelated = ".synccopies-not-a-uuid.tmp"
            let publicFile = ".synccopies-\(UUID().uuidString).tmp"
            let unmarked = ".synccopies-\(UUID().uuidString).tmp"
            let link = ".synccopies-\(UUID().uuidString).tmp"
            let hardLink = ".synccopies-\(UUID().uuidString).tmp"
            let lowercase = ".synccopies-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.tmp"
            let outside = root.appendingPathComponent("outside")
            try Data("keep outside".utf8).write(to: outside)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outside.path)
            for name in [stale, unrelated, publicFile, lowercase] {
                try Data("partial".utf8).write(to: target.appendingPathComponent(name))
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.appendingPathComponent(name).path)
            }
            try Data("unrelated private file".utf8).write(to: target.appendingPathComponent(unmarked))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.appendingPathComponent(unmarked).path)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.appendingPathComponent(publicFile).path)
            try FileManager.default.createSymbolicLink(at: target.appendingPathComponent(link), withDestinationURL: outside)
            #expect(Darwin.link(outside.path, target.appendingPathComponent(hardLink).path) == 0)
            let existing = target.appendingPathComponent("database.kdbx")
            try Data("previous".utf8).write(to: existing)
            // A failed attempt must preserve both the destination and orphaned files.
            let invalid = BackupInfo(url: backup.url, creationDate: backup.creationDate, size: backup.size + 1)
            #expect(throws: MirrorError.changedFile) { try MirrorEngine.copy(backup: invalid, to: target, filename: existing.lastPathComponent) }
            #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent(stale).path))
            #expect(try Data(contentsOf: existing) == Data("previous".utf8))
            let directory = try openDirectory(target)
            let original = try openFile(existing.lastPathComponent, in: directory).stamp()
            let foreignNames = [stale, unrelated, publicFile, unmarked, link, hardLink, lowercase]
            let foreign = try foreignNames.map { try entryStamp($0, in: directory) }
            #expect(try MirrorEngine.copy(backup: backup, to: target, filename: existing.lastPathComponent) == .copied)
            let names = try FileManager.default.contentsOfDirectory(atPath: target.path)
            let retained = try names.filter { try entryStamp($0, in: directory)?.sameIdentity(as: original) == true }
            #expect(retained.count == 1)
            #expect(Set(names) == Set(foreignNames + [existing.lastPathComponent] + retained))
            #expect(try foreignNames.map { try entryStamp($0, in: directory) } == foreign)
            if let name = retained.first { #expect(try Data(contentsOf: target.appendingPathComponent(name)) == Data("previous".utf8)) }
            #expect(try Data(contentsOf: outside) == Data("keep outside".utf8))
        }
    }

    @Test func temporaryLookingDestinationIsPreservedOnUnchangedCopy() throws {
        try fixture { _, target, backup in
            let filename = ".synccopies-\(UUID().uuidString).tmp"
            let file = target.appendingPathComponent(filename)
            try Data(contentsOf: backup.url).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let before = try openFile(filename, in: openDirectory(target)).stamp()
            #expect(try MirrorEngine.copy(backup: backup, to: target, filename: filename) == .unchanged)
            #expect(try openFile(filename, in: openDirectory(target)).stamp() == before)
        }
    }

    @Test func completedTemporaryLookingDestinationOfAnotherDatabaseSurvives() throws {
        try fixture { _, target, backup in
            let completedName = ".synccopies-\(UUID().uuidString).tmp"
            #expect(try MirrorEngine.copy(backup: backup, to: target, filename: completedName) == .copied)
            let completed = target.appendingPathComponent(completedName)
            let before = try openFile(completedName, in: openDirectory(target)).stamp()
            #expect(try MirrorEngine.copy(backup: backup, to: target, filename: "another-database.kdbx") == .copied)
            #expect(try openFile(completedName, in: openDirectory(target)).stamp() == before)
            #expect(try Data(contentsOf: completed) == Data(contentsOf: backup.url))

        }
    }
}
