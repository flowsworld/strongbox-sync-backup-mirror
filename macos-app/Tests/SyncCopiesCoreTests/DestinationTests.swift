import Testing
import Foundation
import Darwin
@testable import SyncCopiesCore

struct DestinationTests {
    private let root: URL

    init() throws {
        let candidate = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        guard let resolved = realpath(candidate.path, nil) else { throw MirrorError.unsafeFile }
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private func directory(_ name: String) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func detectsAllConflictingIDsBeforeCopying() throws {
        defer { try! FileManager.default.removeItem(at: root) }
        let source = try directory("source")
        let target = try directory("target")
        let pairs = [("A.kdbx", "a.kdbx"), ("Σ.kdbx", "ς.kdbx"), ("Straße.kdbx", "STRASSE.kdbx"), ("é.kdbx", "e\u{301}.kdbx"), ("database.kdbx", "data\u{200C}base.kdbx"), ("database.kdbx", "data\u{202E}base.kdbx"), ("database.kdbx", "data\u{FEFF}base.kdbx")]
        for (first, second) in pairs {
            let ids = [UUID(), UUID(), UUID()]
            let destinations = [CopyDestination(databaseID: ids[0], directory: target, filename: first),
                                CopyDestination(databaseID: ids[1], directory: target, filename: second),
                                CopyDestination(databaseID: ids[2], directory: target, filename: "unrelated.kdbx")]
            #expect(try DestinationPlanner.conflictingDatabaseIDs(destinations, sourceRoot: source) == Set(ids.prefix(2)))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func allowsTheSameNameInDifferentDirectories() throws {
        defer { try! FileManager.default.removeItem(at: root) }
        let source = try directory("source")
        let first = try directory("first")
        let second = try directory("second")
        let destinations = [CopyDestination(databaseID: UUID(), directory: first, filename: "a.kdbx"),
                            CopyDestination(databaseID: UUID(), directory: second, filename: "A.kdbx")]
        #expect(try DestinationPlanner.conflictingDatabaseIDs(destinations, sourceRoot: source).isEmpty)
    }

    @Test func detectsCaseAliasesOnCaseInsensitiveVolumes() throws {
        defer { try! FileManager.default.removeItem(at: root) }
        let source = try directory("source")
        let target = try directory("MiXeD-Target")
        let alias = root.appendingPathComponent("mixed-target", isDirectory: true)
        guard FileManager.default.fileExists(atPath: alias.path) else { return }
        let firstID = UUID(), secondID = UUID()
        let destinations = [CopyDestination(databaseID: firstID, directory: target, filename: "a.kdbx"),
                            CopyDestination(databaseID: secondID, directory: alias, filename: "a.kdbx")]
        #expect(try DestinationPlanner.conflictingDatabaseIDs(destinations, sourceRoot: source) == [firstID, secondID])
    }

    @Test func rejectsTheSourceRootAndItsDescendants() throws {
        defer { try! FileManager.default.removeItem(at: root) }
        let source = try directory("source")
        let child = try directory("source/backups")
        for target in [source, child] {
            let destinations = [CopyDestination(databaseID: UUID(), directory: target, filename: "a.kdbx")]
            #expect(throws: DestinationError.insideSource) {
                try DestinationPlanner.conflictingDatabaseIDs(destinations, sourceRoot: source)
            }
        }
        let sibling = try directory("source-other")
        #expect(try DestinationPlanner.conflictingDatabaseIDs([CopyDestination(databaseID: UUID(), directory: sibling, filename: "a.kdbx")], sourceRoot: source).isEmpty)
    }

    @Test func rejectsLinksAndInvalidNames() throws {
        defer { try! FileManager.default.removeItem(at: root) }
        let source = try directory("source")
        let target = try directory("target")
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: (any Error).self) {
            try DestinationPlanner.conflictingDatabaseIDs([CopyDestination(databaseID: UUID(), directory: link, filename: "a.kdbx")], sourceRoot: source)
        }
        let sourceLink = root.appendingPathComponent("source-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: source)
        #expect(throws: (any Error).self) {
            try DestinationPlanner.conflictingDatabaseIDs([], sourceRoot: sourceLink)
        }
        #expect(throws: MirrorError.unsafeFilename) {
            try DestinationPlanner.conflictingDatabaseIDs([CopyDestination(databaseID: UUID(), directory: target, filename: "../a.kdbx")], sourceRoot: source)
        }
    }
}
