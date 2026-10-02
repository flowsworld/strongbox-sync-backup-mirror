import Testing
import Foundation
import Darwin
@testable import SyncCopiesCore

struct DestinationLockTests {
    private func fixture(_ body: (URL, Descriptor) throws -> Void) throws {
        let candidate = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        defer { try! FileManager.default.removeItem(at: candidate) }
        guard let resolved = realpath(candidate.path, nil) else { throw MirrorError.unsafeFile }
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        try body(root, openDirectory(root))
    }

    private func probeLockFromAnotherProcess(_ path: String) throws -> Int32 {
        // Perl's flock uses the same kernel operation as the Swift guard. A fresh
        // process has neither its descriptor nor its in-process reservation.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", """
            use Fcntl qw(O_RDWR LOCK_EX LOCK_NB);
            sysopen(my $file, $ARGV[0], O_RDWR) or exit 74;
            flock($file, LOCK_EX | LOCK_NB) or exit($!{EWOULDBLOCK} ? 73 : 74);
            exit 0;
            """, path]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test func fileFallbackRejectsSameProcessAndIndependentProcessUntilClose() throws {
        try fixture { root, directory in
            let path = root.appendingPathComponent(DestinationLock.filename).path
            var held: DestinationLock? = try DestinationLock.acquire(in: directory, forceFileLock: true)
            #expect(held != nil)
            #expect(throws: MirrorError.targetBusy) {
                try DestinationLock.acquire(in: openDirectory(root), forceFileLock: true)
            }
            #expect(try probeLockFromAnotherProcess(path) == 73)
            held = nil
            #expect(try probeLockFromAnotherProcess(path) == 0)
            let next = try DestinationLock.acquire(in: openDirectory(root), forceFileLock: true)
            try next.validate()
            withExtendedLifetime(next) {}
        }
    }

    @Test func fileFallbackRetainsItsInodeAndExistingContents() throws {
        try fixture { root, directory in
            let file = root.appendingPathComponent(DestinationLock.filename)
            let existing = Data("preserve existing lock contents".utf8)
            try existing.write(to: file)
            let before = try #require(try entryStamp(DestinationLock.filename, in: directory))
            for _ in 0..<2 {
                let held = try DestinationLock.acquire(in: directory, forceFileLock: true)
                try held.validate()
                withExtendedLifetime(held) {}
            }
            let after = try #require(try entryStamp(DestinationLock.filename, in: directory))
            #expect(after.sameIdentity(as: before))
            #expect(try Data(contentsOf: file) == existing)
        }
    }

    @Test func releasingFileLockAllowsAnotherProcessWhileAnUnrelatedReaderRemainsOpen() throws {
        try fixture { root, directory in
            var held: DestinationLock? = try DestinationLock.acquire(in: directory, forceFileLock: true)
            #expect(held != nil)
            let reader = try openFile(DestinationLock.filename, in: directory)
            let path = root.appendingPathComponent(DestinationLock.filename).path
            #expect(try probeLockFromAnotherProcess(path) == 73)
            held = nil
            #expect(try probeLockFromAnotherProcess(path) == 0)
            withExtendedLifetime(reader) {}
        }
    }

    @Test func fileFallbackRejectsSymlinkDirectoryAndFIFOAndReleasesReservation() throws {
        try fixture { root, directory in
            let file = root.appendingPathComponent(DestinationLock.filename)
            let outside = root.appendingPathComponent("outside")
            let contents = Data("keep outside".utf8)
            try contents.write(to: outside)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
            #expect(throws: MirrorError.unsafeFile) {
                try DestinationLock.acquire(in: directory, forceFileLock: true)
            }
            #expect(try Data(contentsOf: outside) == contents)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            #expect(throws: MirrorError.unsafeFile) {
                try DestinationLock.acquire(in: directory, forceFileLock: true)
            }
            try FileManager.default.removeItem(at: file)
            #expect(mkfifo(file.path, 0o600) == 0)
            #expect(throws: MirrorError.unsafeFile) {
                try DestinationLock.acquire(in: directory, forceFileLock: true)
            }
            try FileManager.default.removeItem(at: file)
            let held = try DestinationLock.acquire(in: directory, forceFileLock: true)
            try held.validate()
            withExtendedLifetime(held) {}
        }
    }

    @Test func fileFallbackRejectsHardLinksBeforeAndAfterAcquisition() throws {
        try fixture { root, directory in
            let file = root.appendingPathComponent(DestinationLock.filename)
            let alias = root.appendingPathComponent("alias")
            try Data("do not modify".utf8).write(to: file)
            #expect(Darwin.link(file.path, alias.path) == 0)
            #expect(throws: MirrorError.unsafeFile) {
                try DestinationLock.acquire(in: directory, forceFileLock: true)
            }
            try FileManager.default.removeItem(at: alias)
            let held = try DestinationLock.acquire(in: directory, forceFileLock: true)
            #expect(Darwin.link(file.path, alias.path) == 0)
            #expect(throws: MirrorError.unsafeFile) { try held.validate() }
            withExtendedLifetime(held) {}
            #expect(try Data(contentsOf: alias) == Data("do not modify".utf8))
        }
    }

    @Test func fileFallbackDetectsRemovedAndReplacedLockPaths() throws {
        try fixture { root, directory in
            let file = root.appendingPathComponent(DestinationLock.filename)
            let moved = root.appendingPathComponent("held-lock")
            var held: DestinationLock? = try DestinationLock.acquire(in: directory, forceFileLock: true)
            try FileManager.default.moveItem(at: file, to: moved)
            #expect(throws: MirrorError.changedFile) { try held!.validate() }
            try Data("replacement".utf8).write(to: file)
            #expect(throws: MirrorError.changedFile) { try held!.validate() }
            #expect(throws: MirrorError.targetBusy) {
                try DestinationLock.acquire(in: openDirectory(root), forceFileLock: true)
            }
            held = nil
            #expect(try Data(contentsOf: file) == Data("replacement".utf8))
            let next = try DestinationLock.acquire(in: directory, forceFileLock: true)
            try next.validate()
            withExtendedLifetime(next) {}
        }
    }

    @Test func failedKernelLockReleasesTheInProcessReservation() throws {
        try fixture { root, directory in
            let file = root.appendingPathComponent(DestinationLock.filename)
            try Data().write(to: file)
            var external: Descriptor? = try openFile(DestinationLock.filename, in: directory)
            #expect(flock(external!.value, LOCK_EX | LOCK_NB) == 0)
            #expect(throws: MirrorError.targetBusy) {
                try DestinationLock.acquire(in: directory, forceFileLock: true)
            }
            #expect(flock(external!.value, LOCK_UN) == 0)
            external = nil
            let held = try DestinationLock.acquire(in: directory, forceFileLock: true)
            try held.validate()
            withExtendedLifetime(held) {}
        }
    }

    @Test func reservedLockNameCannotBeAnOutputDestination() throws {
        try fixture { root, _ in
            let source = root.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let backupURL = source.appendingPathComponent("backup.bak")
            try Data("backup".utf8).write(to: backupURL)
            let stamp = try openFile(backupURL.lastPathComponent, in: openDirectory(source)).stamp()
            let backup = BackupInfo(url: backupURL, creationDate: stamp.creationDate, size: stamp.size)
            for filename in [DestinationLock.filename, ".SyncCopies.LOCK"] {
                #expect(throws: MirrorError.unsafeFilename) {
                    try DestinationPlanner.conflictingDatabaseIDs(
                        [CopyDestination(databaseID: UUID(), directory: root, filename: filename)], sourceRoot: source)
                }
                #expect(throws: MirrorError.unsafeFilename) {
                    try MirrorEngine.copy(backup: backup, to: root, filename: filename)
                }
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(DestinationLock.filename).path))
        }
    }
}
