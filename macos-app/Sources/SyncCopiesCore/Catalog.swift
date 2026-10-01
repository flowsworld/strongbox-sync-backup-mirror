import Foundation

public struct Database: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let filename: String
    public let displayName: String
    public init(id: UUID, filename: String, displayName: String) {
        self.id = id; self.filename = filename; self.displayName = displayName
    }
}

func dictionary(_ data: Data) throws -> [String: Any] {
    guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        throw MirrorError.invalidMetadata
    }
    return result
}

public enum StrongboxCatalog {
public static func read(groupContainer: URL) throws -> [Database] {
    do { return try parse(groupContainer: groupContainer) }
    catch let error as MirrorError { throw error }
    catch { throw MirrorError.invalidMetadata }
}

private static func parse(groupContainer: URL) throws -> [Database] {
    let directory = try openDirectory(groupContainer.appendingPathComponent("Library/Preferences", isDirectory: true))
    let file = try openFile("group.strongbox.mac.mcguill.plist", in: directory)
    let preferences = try dictionary(readStable(file, maximumBytes: 32 * 1024 * 1024).0)
    guard let archive = preferences["databases"] as? Data else { throw MirrorError.invalidMetadata }
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
        throw MirrorError.invalidMetadata
    }
    func resolve(_ value: Any?) throws -> Any {
        guard let uid = value as? [String: Any], let index = uid["probeUID"] as? Int,
              objects.indices.contains(index) else { throw MirrorError.invalidMetadata }
        return objects[index]
    }
    func string(_ value: Any?) throws -> String {
        let object = try resolve(value)
        if let value = object as? String { return value }
        if let value = (object as? [String: Any])?["NS.string"] as? String { return value }
        throw MirrorError.invalidMetadata
    }
    func className(_ object: [String: Any]) throws -> String {
        guard let type = try resolve(object["$class"]) as? [String: Any],
              let name = type["$classname"] as? String else { throw MirrorError.invalidMetadata }
        return name
    }
    guard let top = archiveValues["$top"] as? [String: Any],
          let root = try resolve(top["root"]) as? [String: Any],
          try className(root) == "NSArray",
          let entries = root["NS.objects"] as? [Any] else { throw MirrorError.invalidMetadata }
    var databases: [UUID: Database] = [:]
    for reference in entries {
        guard let entry = try resolve(reference) as? [String: Any],
              try className(entry) == "DatabaseMetadata",
              let provider = entry["storageProvider"] as? Int else { throw MirrorError.invalidMetadata }
        guard provider == 10 else { continue } // kCloudKit in the inspected Strongbox revision.
        guard let urlObject = try resolve(entry["fileUrl"]) as? [String: Any],
              try className(urlObject) == "NSURL" else {
            throw MirrorError.invalidMetadata
        }
        let rawURL = try string(urlObject["NS.relative"])
        guard rawURL.hasPrefix("strongbox-cloud:/") else { throw MirrorError.invalidDatabase }
        let path = String(rawURL.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        var encodedName = String(path.dropFirst("strongbox-cloud:/".count))
        if encodedName.hasPrefix("//") { encodedName.removeFirst(2) }
        guard let name = encodedName.removingPercentEncoding, validFilename(name),
              let uuid = UUID(uuidString: try string(entry["uuid"])) else {
            throw MirrorError.invalidDatabase
        }
        let identifier = uuid
        guard let components = URLComponents(string: rawURL),
              let queries = components.queryItems else { throw MirrorError.invalidDatabase }
        let identifiers = queries.filter { $0.name == "uuid" }
        guard identifiers.count == 1, let queryValue = identifiers[0].value,
              UUID(uuidString: queryValue) == uuid else { throw MirrorError.inconsistentIdentifier }
        guard databases[identifier] == nil else { throw MirrorError.inconsistentIdentifier }
        let nicknameReference = entry["nickName"] as? [String: Any]
        let nickname = nicknameReference?["probeUID"] as? Int == 0 ? name : try string(entry["nickName"])
        let displayName = nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? name : nickname
        databases[identifier] = Database(id: identifier, filename: name, displayName: displayName)
    }
    return databases.values.sorted { ($0.displayName, $0.id.uuidString) < ($1.displayName, $1.id.uuidString) }
}

}
