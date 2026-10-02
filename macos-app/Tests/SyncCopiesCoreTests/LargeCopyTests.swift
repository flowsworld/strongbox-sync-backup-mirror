import Testing
import Foundation
import Darwin
@testable import SyncCopiesCore

struct LargeCopyTests {
    @Test func writesBufferLargerThanDarwinsSingleWriteLimit() throws {
        // Anonymous memory and /dev/null reproduce the syscall limit without
        // allocating physical gigabytes or writing a large fixture to disk.
        let length = Int(Int32.max) + 1
        let mapping = mmap(nil, length, PROT_READ, MAP_PRIVATE | MAP_ANON, -1, 0)
        let address = try #require(mapping != MAP_FAILED ? mapping : nil)
        defer { munmap(address, length) }
        let sink = try Descriptor(Darwin.open("/dev/null", O_WRONLY | O_CLOEXEC))
        try writeAll(UnsafeRawBufferPointer(start: address, count: length), to: sink)
    }

    @Test func copiesMultipleChunksAndUnevenTailThenKeepsUnchangedIdentity() throws {
        try fixture { root in
            let target = root.appendingPathComponent("target", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("backup.bak")
            var contents = Data(repeating: 0xA5, count: 3 * 1024 * 1024 + 137)
            contents[1024 * 1024] = 0x37
            contents[contents.count - 1] = 0xF1
            try contents.write(to: source)
            let sourceStamp = try openFile(source.lastPathComponent, in: openDirectory(root)).stamp()
            let backup = BackupInfo(url: source, creationDate: sourceStamp.creationDate, size: sourceStamp.size)
            let filename = "database.kdbx"
            let destination = target.appendingPathComponent(filename)
            #expect(try MirrorEngine.copy(backup: backup, to: target, filename: filename) == .copied)
            #expect(try Data(contentsOf: destination) == contents)
            let before = try openFile(filename, in: openDirectory(target)).stamp()
            #expect(try MirrorEngine.copy(backup: backup, to: target, filename: filename) == .unchanged)
            #expect(try openFile(filename, in: openDirectory(target)).stamp() == before)
            #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == [filename])
            // A difference in the final partial chunk must also replace the target.
            var different = contents
            different[different.count - 1] = 0x7B
            try different.write(to: destination)
            #expect(try MirrorEngine.copy(backup: backup, to: target, filename: filename) == .copied)
            #expect(try Data(contentsOf: destination) == contents)
        }
    }

    @Test func streamingValidationChecksBytesAndRejectsAChangedSource() throws {
        try fixture { root in
            let sourceURL = root.appendingPathComponent("backup.bak")
            try Data(repeating: 0x51, count: 1024 * 1024 + 13).write(to: sourceURL)
            let source = try openFile(sourceURL.lastPathComponent, in: openDirectory(root))
            let sourceStamp = try source.stamp()
            let snapshot = try Descriptor(Darwin.open(root.appendingPathComponent("snapshot").path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600))
            try copyStable(source, stamp: sourceStamp, to: snapshot)
            #expect(try sameContents(source, stamp: sourceStamp, snapshot, stamp: snapshot.stamp()))
            var changedByte: UInt8 = 0x73
            #expect(pwrite(snapshot.value, &changedByte, 1, sourceStamp.size - 1) == 1)
            #expect(try !sameContents(source, stamp: sourceStamp, snapshot, stamp: snapshot.stamp()))
            let writer = try Descriptor(Darwin.open(sourceURL.path, O_WRONLY | O_CLOEXEC))
            #expect(pwrite(writer.value, &changedByte, 1, sourceStamp.size) == 1)
            #expect(throws: MirrorError.changedFile) {
                try copyStable(source, stamp: sourceStamp, to: snapshot)
            }
            #expect(throws: MirrorError.changedFile) {
                try sameContents(source, stamp: sourceStamp, snapshot, stamp: snapshot.stamp())
            }
        }
    }

    private func fixture(_ body: (URL) throws -> Void) throws {
        let candidate = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        defer { try! FileManager.default.removeItem(at: candidate) }
        guard let resolved = realpath(candidate.path, nil) else { throw MirrorError.unsafeFile }
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        try body(root)
    }

}
