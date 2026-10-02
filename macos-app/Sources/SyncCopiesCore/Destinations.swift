import Foundation
import Darwin

public struct CopyDestination: Sendable {
    public let databaseID: UUID
    public let directory: URL
    public let filename: String

    public init(databaseID: UUID, directory: URL, filename: String) {
        self.databaseID = databaseID
        self.directory = directory
        self.filename = filename
    }
}

public enum DestinationError: Error, LocalizedError, LocalizedMessageError, Equatable {
    case insideSource

    public var errorDescription: String? { message.rendered() }

    public var message: LocalizedMessage {
        LocalizedMessage(key: "The destination folder must be outside the Strongbox folder.")
    }
}

public enum DestinationPlanner {
    /// Validate every selected destination before copying any database.
    /// Invalid destinations may be reported individually so unrelated copies continue.
    /// Directory identity catches different path spellings that refer to the same folder.
    public static func conflictingDatabaseIDs(
        _ destinations: [CopyDestination], sourceRoot: URL,
        onInvalidDestination: ((CopyDestination, any Error) -> Void)? = nil
    ) throws -> Set<UUID> {
        let source = try openDirectory(sourceRoot, accessRole: .source)
        let sourceStamp = try source.stamp()
        let sourcePath = normalizedDestinationName(sourceRoot.resolvingSymlinksInPath().standardizedFileURL.path)
        var groups: [DestinationIdentity: [UUID]] = [:]
        for destination in destinations {
            do {
                guard validDestinationFilename(destination.filename) else { throw MirrorError.unsafeFilename }
                let directory = try openDirectory(destination.directory)
                let stamp = try directory.stamp()
                let path = normalizedDestinationName(destination.directory.resolvingSymlinksInPath().standardizedFileURL.path)
                let sourcePrefix = sourcePath == "/" ? "/" : sourcePath + "/"
                guard !stamp.sameIdentity(as: sourceStamp), path != sourcePath,
                      !path.hasPrefix(sourcePrefix) else { throw DestinationError.insideSource }
                let identity = DestinationIdentity(device: stamp.device, inode: stamp.inode,
                                                   filename: normalizedDestinationName(destination.filename))
                groups[identity, default: []].append(destination.databaseID)
            } catch {
                guard let onInvalidDestination else { throw error }
                onInvalidDestination(destination, error)
            }
        }
        return Set(groups.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    private struct DestinationIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
        let filename: String
    }
}
