import Foundation
import CryptoKit

// Throwaway feasibility code. Parses plist values without instantiating archived classes.
struct Database: Encodable {
    let identifier: String
    let name: String
    let displayName: String
}

enum ProbeError: String, Error {
    case invalidMetadata, invalidDatabase, inconsistentIdentifier
    case missingBackup, unsafeBackup, emptyBackup, changedBackup
    case missingBookmark, inactiveBookmark, staleBookmark, selectionCancelled
}

func dictionary(_ data: Data) throws -> [String: Any] {
    guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        throw ProbeError.invalidMetadata
    }
    return result
}

func catalog(_ preferences: URL) throws -> [Database] {
    let preferences = try dictionary(Data(contentsOf: preferences))
    guard let archive = preferences["databases"] as? Data else { throw ProbeError.invalidMetadata }
    let binary = try PropertyListSerialization.propertyList(from: archive, format: nil)
    // XML exposes UIDs, but Foundation turns CF$UID dictionaries back into opaque UIDs.
    // Rename that generated XML key before parsing, without private UID APIs or unarchiving classes.
    let xml = try PropertyListSerialization.data(fromPropertyList: binary, format: .xml, options: 0)
    let readableXML = String(decoding: xml, as: UTF8.self)
        .replacingOccurrences(of: "<key>CF$UID</key>", with: "<key>probeUID</key>")
    let archiveValues = try dictionary(Data(readableXML.utf8))
    guard archiveValues["$archiver"] as? String == "NSKeyedArchiver",
          archiveValues["$version"] as? Int == 100000,
          let objects = archiveValues["$objects"] as? [Any], !objects.isEmpty else {
        throw ProbeError.invalidMetadata
    }
    func resolve(_ value: Any?) throws -> Any {
        guard let uid = value as? [String: Any], let index = uid["probeUID"] as? Int,
              objects.indices.contains(index) else { throw ProbeError.invalidMetadata }
        return objects[index]
    }
    func string(_ value: Any?) throws -> String {
        let object = try resolve(value)
        if let value = object as? String { return value }
        if let value = (object as? [String: Any])?["NS.string"] as? String { return value }
        throw ProbeError.invalidMetadata
    }
    func className(_ object: [String: Any]) throws -> String {
        guard let type = try resolve(object["$class"]) as? [String: Any],
              let name = type["$classname"] as? String else { throw ProbeError.invalidMetadata }
        return name
    }
    guard let top = archiveValues["$top"] as? [String: Any],
          let root = try resolve(top["root"]) as? [String: Any],
          try className(root) == "NSArray",
          let entries = root["NS.objects"] as? [Any] else { throw ProbeError.invalidMetadata }
    var databases: [String: Database] = [:]
    for reference in entries {
        guard let entry = try resolve(reference) as? [String: Any],
              try className(entry) == "DatabaseMetadata",
              let provider = entry["storageProvider"] as? Int else { throw ProbeError.invalidMetadata }
        guard provider == 10 else { continue } // kCloudKit in the inspected Strongbox revision.
        guard let urlObject = try resolve(entry["fileUrl"]) as? [String: Any],
              try className(urlObject) == "NSURL" else {
            throw ProbeError.invalidMetadata
        }
        let rawURL = try string(urlObject["NS.relative"])
        guard rawURL.hasPrefix("strongbox-cloud:/") else { throw ProbeError.invalidDatabase }
        let path = String(rawURL.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        var encodedName = String(path.dropFirst("strongbox-cloud:/".count))
        if encodedName.hasPrefix("//") { encodedName.removeFirst(2) }
        guard let name = encodedName.removingPercentEncoding, !name.isEmpty,
              !name.contains("/"), !name.contains("\0"), name != ".", name != "..",
              let uuid = UUID(uuidString: try string(entry["uuid"])) else {
            throw ProbeError.invalidDatabase
        }
        let identifier = uuid.uuidString
        guard let components = URLComponents(string: rawURL),
              let queries = components.queryItems else { throw ProbeError.invalidDatabase }
        let identifiers = queries.filter { $0.name == "uuid" }
        guard identifiers.count == 1, let queryValue = identifiers[0].value,
              UUID(uuidString: queryValue) == uuid else { throw ProbeError.inconsistentIdentifier }
        guard databases[identifier] == nil else { throw ProbeError.inconsistentIdentifier }
        let nicknameReference = entry["nickName"] as? [String: Any]
        let displayName = nicknameReference?["probeUID"] as? Int == 0 ? name : try string(entry["nickName"])
        databases[identifier] = Database(identifier: identifier, name: name, displayName: displayName)
    }
    return databases.values.sorted { ($0.name, $0.identifier) < ($1.name, $1.identifier) }
}

struct BackupSample {
    let size: Int
    let creationDate: Date
}

func sampleNewestBackup(_ root: URL, database: Database) throws -> BackupSample {
    let folder = root.appendingPathComponent(database.identifier, isDirectory: true)
    let folderValues = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard folderValues.isDirectory == true, folderValues.isSymbolicLink != true else {
        throw ProbeError.unsafeBackup
    }
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .fileSizeKey, .contentModificationDateKey]
    var candidates: [(URL, URLResourceValues)] = []
    for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) where file.pathExtension == "bak" {
        let values = try file.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true else { throw ProbeError.unsafeBackup }
        guard values.isRegularFile == true else { continue }
        guard values.creationDate != nil else { throw ProbeError.unsafeBackup }
        candidates.append((file, values))
    }
    guard let newest = candidates.max(by: {
        ($0.1.creationDate!, $0.0.lastPathComponent) < ($1.1.creationDate!, $1.0.lastPathComponent)
    }) else { throw ProbeError.missingBackup }
    guard let expectedSize = newest.1.fileSize, expectedSize > 0 else { throw ProbeError.emptyBackup }
    let handle = try FileHandle(forReadingFrom: newest.0)
    var digest = SHA256()
    var bytes = 0
    do {
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            digest.update(data: chunk)
            bytes += chunk.count
        }
    } catch {
        try handle.close()
        throw error
    }
    try handle.close()
    _ = digest.finalize() // Exercise reading encrypted bytes; never publish their checksum or content.
    var refreshed = newest.0
    refreshed.removeAllCachedResourceValues()
    let after = try refreshed.resourceValues(forKeys: keys)
    guard bytes == expectedSize, after.fileSize == newest.1.fileSize,
          after.contentModificationDate == newest.1.contentModificationDate else {
        throw ProbeError.changedBackup
    }
    return BackupSample(size: bytes, creationDate: newest.1.creationDate!)
}
