import Testing
import Foundation
import Darwin
@testable import SyncCopiesCore

@objc(SyncCopiesTestMetadataFixture)
private final class MetadataFixture: NSObject, NSCoding {
    let id: UUID
    let filename: String
    let nickname: String?
    let provider: Int
    let urlID: UUID
    init(id: UUID = UUID(), filename: String, nickname: String? = nil, provider: Int = 10, urlID: UUID? = nil) {
        self.id = id; self.filename = filename; self.nickname = nickname; self.provider = provider; self.urlID = urlID ?? id
    }
    required init?(coder: NSCoder) { fatalError("Fixtures must never be decoded") }
    func encode(with coder: NSCoder) {
        coder.encode(provider, forKey: "storageProvider")
        coder.encode(id.uuidString as NSString, forKey: "uuid")
        coder.encode(nickname as NSString?, forKey: "nickName")
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        coder.encode(URL(string: "strongbox-cloud:/\(encoded)?uuid=\(urlID.uuidString)")! as NSURL, forKey: "fileUrl")
    }
}

struct CoreTests {
    private let root: URL
    init() throws {
        // /var is a macOS symlink. Resolve only the test-created fixture root.
        let candidate = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        guard let resolved = realpath(candidate.path, nil) else { throw MirrorError.unsafeFile }
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private func directory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func catalog(_ entries: [MetadataFixture], className: String = "DatabaseMetadata") throws -> [Database] {
        let archive = NSKeyedArchiver(requiringSecureCoding: false)
        archive.setClassName(className, for: MetadataFixture.self)
        archive.encode(entries as NSArray, forKey: NSKeyedArchiveRootObjectKey)
        archive.finishEncoding()
        let preferences = try directory("Library/Preferences").appendingPathComponent("group.strongbox.mac.mcguill.plist")
        try PropertyListSerialization.data(fromPropertyList: ["databases": archive.encodedData], format: .binary, options: 0).write(to: preferences)
        return try StrongboxCatalog.read(groupContainer: root)
    }
    private func source(_ bytes: String, name: String = "backup.bak") throws -> BackupInfo {
        let file = try directory("source").appendingPathComponent(name)
        try Data(bytes.utf8).write(to: file)
        let descriptor = try openFile(name, in: openDirectory(file.deletingLastPathComponent()))
        let stamp = try descriptor.stamp()
        return BackupInfo(url: file, creationDate: stamp.creationDate, size: stamp.size)
    }

    @Test func testDestinationNamesDetectUnicodeCaseCollisions() throws {
        defer { try! FileManager.default.removeItem(at: root) }
        let pairs = [("Σ.kdbx", "ς.kdbx"), ("Straße.kdbx", "STRASSE.kdbx"), ("ﬀ.kdbx", "FF.kdbx"), ("é.kdbx", "e\u{301}.kdbx")]
        for (first, second) in pairs {
            #expect(normalizedDestinationName(first) == normalizedDestinationName(second))
        }
        #expect(normalizedDestinationName("a.kdbx") != normalizedDestinationName("b.kdbx"))
    }

    @Test func testCatalogResolvesMultipleNamesAndExcludesOtherProviders() throws {
        defer { try! FileManager.default.removeItem(at: root) }
        let first = MetadataFixture(filename: "private.kdbx", nickname: "Privat")
        let second = MetadataFixture(filename: "work.kdbx")
        let result = try catalog([first, second, MetadataFixture(filename: "other.kdbx", provider: 1)])
        #expect(Set(result.map(\.id)) == Set([first.id, second.id]))
        #expect(result.first(where: { $0.id == first.id })?.displayName == "Privat")
        #expect(result.first(where: { $0.id == second.id })?.displayName == "work.kdbx")
        #expect(result.first(where: { $0.id == first.id })?.filename == "private.kdbx")
    }
    @Test func testCatalogFailsClosedForUnknownClassAndInconsistentIdentity() throws {
        defer { try! FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) { try catalog([MetadataFixture(filename: "a.kdbx")], className: "UnexpectedMetadata") }
        #expect(throws: (any Error).self) { try catalog([MetadataFixture(filename: "a.kdbx", urlID: UUID())]) }
        let duplicate = MetadataFixture(filename: "a.kdbx")
        #expect(throws: (any Error).self) { try catalog([duplicate, duplicate]) }
    }
    @Test func testNewestUsesBirthTimeAndNeverFallsBackFromEmptyNewest() throws {
        defer { try! FileManager.default.removeItem(at: root) }
        let database = Database(id: UUID(), filename: "a.kdbx", displayName: "A")
        let folder = try directory("backups/\(database.id.uuidString)")
        let old = folder.appendingPathComponent("old.bak")
        let new = folder.appendingPathComponent("new.bak")
        try Data("old".utf8).write(to: old)
        // Birth-time spacing is intentional: metadata ordering, not wall-clock assumptions.
        usleep(20_000)
        try Data("new".utf8).write(to: new)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(1000)], ofItemAtPath: old.path)
        #expect(try StrongboxBackups.newest(for: database, groupContainer: root).url == new)
        let empty = folder.appendingPathComponent("empty.bak")
        usleep(20_000)
        try Data().write(to: empty)
        #expect(throws: MirrorError.emptyBackup) { try StrongboxBackups.newest(for: database, groupContainer: root) }
    }
    @Test func testCopyIsRestrictiveAndUnchangedFileKeepsItsIdentity() throws {
        defer { try! FileManager.default.removeItem(at: root) }
        let backup = try source("encrypted contents")
        let target = try directory("target")
        let file = target.appendingPathComponent("a.kdbx")
        #expect(try MirrorEngine.copy(backup: backup, to: target, filename: "a.kdbx") == .copied)
        let before = try openFile("a.kdbx", in: openDirectory(target)).stamp()
        #expect(before.mode & 0o777 == 0o600)
        #expect(try MirrorEngine.copy(backup: backup, to: target, filename: "a.kdbx") == .unchanged)
        #expect(try openFile("a.kdbx", in: openDirectory(target)).stamp() == before)
        #expect(try Data(contentsOf: file) == Data("encrypted contents".utf8))
    }
    @Test func testChangedCopyRetainsPreviousInodeAndErrorsPreserveCurrentCopy() throws {
        defer { try! FileManager.default.removeItem(at: root) }
        let target = try directory("target")
        let file = target.appendingPathComponent("a.kdbx")
        try Data("previous".utf8).write(to: file)
        let old = try openFile("a.kdbx", in: openDirectory(target))
        let backup = try source("replacement")
        #expect(try MirrorEngine.copy(backup: backup, to: target, filename: "a.kdbx") == .copied)
        #expect(try readStable(old).0 == Data("previous".utf8))
        #expect(try Data(contentsOf: file) == Data("replacement".utf8))
        let empty = try source("", name: "empty.bak")
        #expect(throws: (any Error).self) { try MirrorEngine.copy(backup: empty, to: target, filename: "a.kdbx") }
        #expect(throws: (any Error).self) { try MirrorEngine.copy(backup: backup, to: target, filename: "../escape") }
        let stale = BackupInfo(url: backup.url, creationDate: backup.creationDate, size: 1)
        #expect(throws: (any Error).self) { try MirrorEngine.copy(backup: stale, to: target, filename: "a.kdbx") }
        #expect(try Data(contentsOf: file) == Data("replacement".utf8))
        let directory = try openDirectory(target)
        let original = try old.stamp()
        let retained = try FileManager.default.contentsOfDirectory(atPath: target.path).filter {
            try entryStamp($0, in: directory)?.sameIdentity(as: original) == true
        }
        #expect(retained.count == 1)
        if let name = retained.first {
            #expect(try Data(contentsOf: target.appendingPathComponent(name)) == Data("previous".utf8))
        }
    }
    @Test func testRejectsLinksAndSourceAsTarget() throws {
        defer { try! FileManager.default.removeItem(at: root) }
        let backup = try source("encrypted contents")
        let target = try directory("target")
        let linkedSource = backup.url.deletingLastPathComponent().appendingPathComponent("link.bak")
        try FileManager.default.createSymbolicLink(at: linkedSource, withDestinationURL: backup.url)
        #expect(throws: (any Error).self) { try MirrorEngine.copy(backup: BackupInfo(url: linkedSource, creationDate: backup.creationDate, size: backup.size), to: target, filename: "a.kdbx") }
        let linkedDirectory = root.appendingPathComponent("linked-target")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: target)
        #expect(throws: (any Error).self) { try MirrorEngine.copy(backup: backup, to: linkedDirectory, filename: "a.kdbx") }
        let linkedTarget = target.appendingPathComponent("a.kdbx")
        try FileManager.default.createSymbolicLink(at: linkedTarget, withDestinationURL: backup.url)
        #expect(throws: (any Error).self) { try MirrorEngine.copy(backup: backup, to: target, filename: "a.kdbx") }
        #expect(throws: (any Error).self) { try MirrorEngine.copy(backup: backup, to: backup.url.deletingLastPathComponent(), filename: backup.url.lastPathComponent) }
        #expect(try Data(contentsOf: backup.url) == Data("encrypted contents".utf8))
    }
}
