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
            #expect(try MirrorEngine.copy(backup: backup, to: target, filename: file.lastPathComponent) == .copied)
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: target.path)) == Set([file.lastPathComponent, activeTemporary.lastPathComponent]))
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
            #expect(try MirrorEngine.copy(backup: backup, to: target, filename: existing.lastPathComponent) == .copied)
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: target.path)) == Set([stale, unrelated, publicFile, unmarked, link, hardLink, lowercase, existing.lastPathComponent]))
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

    @Test func sourceChangedAfterTemporaryCreationPreservesTargetAndRetainsEncryptedPartial() throws {
        try fixture { root, target, _ in
            let source = root.appendingPathComponent("backup.bak")
            try Data(repeating: 0x7B, count: 32 * 1024 * 1024).write(to: source)
            let sourceFile = try openFile(source.lastPathComponent, in: openDirectory(root))
            let stamp = try sourceFile.stamp()
            let backup = BackupInfo(url: source, creationDate: stamp.creationDate, size: stamp.size)
            let destination = target.appendingPathComponent("database.kdbx")
            let previous = Data("previous encrypted backup".utf8)
            try previous.write(to: destination)
            let changed = DispatchSemaphore(value: 0)
            let writer = Thread {
                defer { changed.signal() }
                for _ in 0..<5_000 {
                    if let names = try? FileManager.default.contentsOfDirectory(atPath: target.path),
                       names.contains(where: { $0.hasPrefix(".synccopies-") }) {
                        let descriptor = Darwin.open(source.path, O_WRONLY | O_APPEND | O_CLOEXEC)
                        guard descriptor >= 0 else { return }
                        defer { Darwin.close(descriptor) }
                        var byte: UInt8 = 0x7B
                        _ = Darwin.write(descriptor, &byte, 1)
                        return
                    }
                    usleep(1_000)
                }
            }
            writer.start()
            #expect(throws: MirrorError.changedFile) {
                try MirrorEngine.copy(backup: backup, to: target, filename: destination.lastPathComponent)
            }
            #expect(changed.wait(timeout: .now() + 6) == .success)
            #expect(try Data(contentsOf: destination) == previous)
            #expect(try sourceFile.stamp().size == stamp.size + 1)
            let names = try FileManager.default.contentsOfDirectory(atPath: target.path)
            let partials = names.filter { $0.hasPrefix(".synccopies-") }
            #expect(partials.count == 1)
            if let name = partials.first {
                let partial = try openFile(name, in: openDirectory(target))
                #expect(try partial.stamp().mode & 0o777 == 0o600)
                #expect(try readStable(partial).0 == Data(repeating: 0x7B, count: 32 * 1024 * 1024))
            }
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
