import Foundation

public enum GoogleDriveMetadataError: Error, Equatable, Sendable {
    case invalidFolderID, invalidFolderURL, invalidFilename, malformedResponse
    case unexpectedFolder, unexpectedFile, incompleteSearch, ambiguousFile, ambiguousFolder
    case invalidPageToken, paginationCycle, paginationLimit, searchFinished, responseTooLarge
}

/// Requests have no credentials and can only describe metadata GET operations.
public struct GoogleDriveMetadataRequest: Equatable, Sendable {
    public let url: URL
    public let method: String

    fileprivate init(url: URL) {
        self.url = url
        method = "GET"
    }
}

public struct GoogleDriveFolder: Equatable, Sendable {
    public let id: String
    public let name: String

    fileprivate init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum GoogleDriveMetadata {
    /// Accept a folder ID or a recognized Drive folder/My Drive link. Never fetch the supplied URL.
    public static func folderID(from input: String) throws -> String {
        if validDriveID(input) { return input }
        guard input.unicodeScalars.count <= 16_384, input.hasPrefix("https://drive.google.com/"),
              let components = URLComponents(string: input), components.scheme == "https",
              components.host == "drive.google.com", components.user == nil,
              components.password == nil, components.port == nil else {
            throw GoogleDriveMetadataError.invalidFolderURL
        }
        var parts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        if parts.last == "" { parts.removeLast() }
        guard parts.count >= 3, parts[0] == "", parts[1] == "drive" else {
            throw GoogleDriveMetadataError.invalidFolderURL
        }
        parts.removeFirst(2)
        if parts.first == "u" {
            guard parts.count >= 3, !parts[1].isEmpty,
                  parts[1].utf8.allSatisfy({ (48...57).contains($0) }) else {
                throw GoogleDriveMetadataError.invalidFolderURL
            }
            parts.removeFirst(2)
        }
        if parts == ["my-drive"] { return "root" }
        guard parts.count == 2, parts[0] == "folders", validDriveID(String(parts[1])) else {
            throw GoogleDriveMetadataError.invalidFolderURL
        }
        return String(parts[1])
    }

    public static func folderRequest(id: String) throws -> GoogleDriveMetadataRequest {
        guard validDriveID(id) else { throw GoogleDriveMetadataError.invalidFolderID }
        return try driveRequest(path: "/drive/v3/files/\(id)", parameters: [
            ("fields", "id,name,mimeType,trashed"), ("supportsAllDrives", "true")
        ])
    }

    /// Only My Drive's root alias may resolve to a different returned folder ID.
    public static func resolveFolder(_ data: Data, requestedID: String) throws -> GoogleDriveFolder {
        guard validDriveID(requestedID) else { throw GoogleDriveMetadataError.invalidFolderID }
        let response = try driveResponse(FolderResponse.self, data: data)
        guard validDriveID(response.id), validDriveString(response.name) else {
            throw GoogleDriveMetadataError.malformedResponse
        }
        guard (requestedID == "root" || response.id == requestedID), !response.trashed,
              response.mimeType == "application/vnd.google-apps.folder" else {
            throw GoogleDriveMetadataError.unexpectedFolder
        }
        return GoogleDriveFolder(id: response.id, name: response.name)
    }
}

public enum GoogleDriveSearchStep: Equatable, Sendable {
    case nextPage(GoogleDriveMetadataRequest)
    case complete(UploadRemoteFile?)
}

/// One fresh folder/name search. A file is publishable only after the last valid page.
public struct GoogleDriveFileSearch: Sendable {
    public private(set) var request: GoogleDriveMetadataRequest?
    private let folderID: String
    private let filename: String
    private var match: UploadRemoteFile?
    private var pagination = DrivePagination()

    public init(folder: GoogleDriveFolder, filename: String) throws {
        guard !filename.isEmpty, filename.unicodeScalars.count <= 1024 else {
            throw GoogleDriveMetadataError.invalidFilename
        }
        folderID = folder.id
        self.filename = filename
        request = try fileSearchRequest(folderID: folder.id, filename: filename, pageToken: nil)
    }

    /// A failed page ends this search. Start a new search rather than reuse a partial match.
    public mutating func consume(_ data: Data) throws -> GoogleDriveSearchStep {
        guard request != nil else { throw GoogleDriveMetadataError.searchFinished }
        request = nil
        let page = try driveResponse(DrivePage<FileResponse>.self, data: data)
        try pagination.begin(incomplete: page.incompleteSearch)
        var candidate = match
        for response in page.files {
            guard response.name == filename, !response.trashed, response.parents.contains(folderID) else {
                throw GoogleDriveMetadataError.unexpectedFile
            }
            let file = try response.remoteFile()
            guard candidate == nil else { throw GoogleDriveMetadataError.ambiguousFile }
            candidate = file
        }
        guard let token = try pagination.continuation(page.nextPageToken) else {
            return .complete(candidate)
        }
        let next = try fileSearchRequest(folderID: folderID, filename: filename, pageToken: token)
        match = candidate
        request = next
        return .nextPage(next)
    }
}

public enum GoogleDriveFolderSearchStep: Equatable, Sendable {
    case nextPage(GoogleDriveMetadataRequest)
    case complete(GoogleDriveFolder?)
}

/// Resolve exactly one named child of an already verified folder, including all search pages.
public struct GoogleDriveFolderSearch: Sendable {
    public private(set) var request: GoogleDriveMetadataRequest?
    private let folderID: String
    private let name: String
    private var match: GoogleDriveFolder?
    private var pagination = DrivePagination()

    public init(folder: GoogleDriveFolder, name: String) throws {
        guard !name.isEmpty, name.unicodeScalars.count <= 1024 else { throw GoogleDriveMetadataError.invalidFilename }
        folderID = folder.id
        self.name = name
        request = try folderSearchRequest(folderID: folder.id, name: name, pageToken: nil)
    }

    public mutating func consume(_ data: Data) throws -> GoogleDriveFolderSearchStep {
        guard request != nil else { throw GoogleDriveMetadataError.searchFinished }
        request = nil
        let page = try driveResponse(DrivePage<ChildFolderResponse>.self, data: data)
        try pagination.begin(incomplete: page.incompleteSearch)
        var candidate = match
        for response in page.files {
            guard validDriveID(response.id), response.parents.allSatisfy(validDriveID) else {
                throw GoogleDriveMetadataError.malformedResponse
            }
            guard response.name == name, !response.trashed, response.parents.contains(folderID),
                  response.mimeType == "application/vnd.google-apps.folder" else {
                throw GoogleDriveMetadataError.unexpectedFolder
            }
            guard candidate == nil else { throw GoogleDriveMetadataError.ambiguousFolder }
            candidate = GoogleDriveFolder(id: response.id, name: response.name)
        }
        guard let token = try pagination.continuation(page.nextPageToken) else { return .complete(candidate) }
        let next = try folderSearchRequest(folderID: folderID, name: name, pageToken: token)
        match = candidate
        request = next
        return .nextPage(next)
    }
}

public enum GoogleDriveOtherCopiesSearchStep: Equatable, Sendable {
    case nextPage(GoogleDriveMetadataRequest)
    case complete(Int)
}

/// Informational only: count same-named, checksum-identical copies outside the selected folder.
/// An unavailable or incomplete search must never invalidate the primary folder's verification.
public struct GoogleDriveOtherCopiesSearch: Sendable {
    public private(set) var request: GoogleDriveMetadataRequest?
    private let filename: String
    private let excludingFolderID: String
    private let local: UploadLocalFingerprint
    private var count = 0
    private var seenIDs = Set<String>()
    private var pagination = DrivePagination()

    public init(filename: String, excludingFolderID: String, local: UploadLocalFingerprint) throws {
        guard !filename.isEmpty, filename.unicodeScalars.count <= 1024 else { throw GoogleDriveMetadataError.invalidFilename }
        guard validDriveID(excludingFolderID) else { throw GoogleDriveMetadataError.invalidFolderID }
        self.filename = filename
        self.excludingFolderID = excludingFolderID
        self.local = local
        request = try otherCopiesRequest(filename: filename, excludingFolderID: excludingFolderID, pageToken: nil)
    }

    public mutating func consume(_ data: Data) throws -> GoogleDriveOtherCopiesSearchStep {
        guard request != nil else { throw GoogleDriveMetadataError.searchFinished }
        request = nil
        let page = try driveResponse(DrivePage<FileResponse>.self, data: data)
        try pagination.begin(incomplete: page.incompleteSearch)
        var candidateCount = count
        for response in page.files {
            guard response.name == filename, !response.trashed, !response.parents.isEmpty,
                  !response.parents.contains(excludingFolderID) else { throw GoogleDriveMetadataError.unexpectedFile }
            guard response.parents.allSatisfy(validDriveID) else { throw GoogleDriveMetadataError.malformedResponse }
            let file = try response.remoteFile()
            guard seenIDs.insert(file.id).inserted else { throw GoogleDriveMetadataError.malformedResponse }
            let digestMatches = file.sha256.map { $0 == local.sha256 } ?? file.md5.map { $0 == local.md5 } ?? false
            if file.size == local.size && digestMatches { candidateCount += 1 }
        }
        guard let token = try pagination.continuation(page.nextPageToken) else { return .complete(candidateCount) }
        let next = try otherCopiesRequest(filename: filename, excludingFolderID: excludingFolderID, pageToken: token)
        count = candidateCount
        request = next
        return .nextPage(next)
    }
}

private struct DrivePagination: Sendable {
    private var pages = 0
    private var seenTokens = Set<String>()

    mutating func begin(incomplete: Bool) throws {
        pages += 1
        guard !incomplete else { throw GoogleDriveMetadataError.incompleteSearch }
    }

    mutating func continuation(_ token: String?) throws -> String? {
        guard let token else { return nil }
        guard validDriveString(token) else { throw GoogleDriveMetadataError.invalidPageToken }
        guard seenTokens.insert(token).inserted else { throw GoogleDriveMetadataError.paginationCycle }
        guard pages < 100 else { throw GoogleDriveMetadataError.paginationLimit }
        return token
    }
}

private struct ChildFolderResponse: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let parents: [String]
    let trashed: Bool
}

private func folderSearchRequest(folderID: String, name: String, pageToken: String?) throws -> GoogleDriveMetadataRequest {
    try searchRequest(query: "'\(folderID)' in parents and name = '\(queryString(name))' and mimeType = 'application/vnd.google-apps.folder' and trashed = false",
                      fields: "id,name,mimeType,parents,trashed", pageToken: pageToken)
}

private func otherCopiesRequest(filename: String, excludingFolderID: String, pageToken: String?) throws -> GoogleDriveMetadataRequest {
    try searchRequest(query: "name = '\(queryString(filename))' and not '\(excludingFolderID)' in parents and mimeType != 'application/vnd.google-apps.folder' and trashed = false",
                      fields: "id,name,parents,trashed,size,md5Checksum,sha256Checksum", pageToken: pageToken)
}

private struct FolderResponse: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let trashed: Bool
}

private struct FileResponse: Decodable {
    let id: String
    let name: String
    let parents: [String]
    let trashed: Bool
    let size: String
    let sha256Checksum: String?
    let md5Checksum: String?

    func remoteFile() throws -> UploadRemoteFile {
        guard validDriveID(id), !size.isEmpty, size.utf8.count <= 20,
              size.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int64(size) else {
            throw GoogleDriveMetadataError.malformedResponse
        }
        do { return try UploadRemoteFile(id: id, size: value, sha256: sha256Checksum, md5: md5Checksum) }
        catch { throw GoogleDriveMetadataError.malformedResponse }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, parents, trashed, size, sha256Checksum, md5Checksum
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        parents = try values.decode([String].self, forKey: .parents)
        trashed = try values.decode(Bool.self, forKey: .trashed)
        size = try values.decode(String.self, forKey: .size)
        // Present null digests are malformed, rather than an omitted algorithm.
        sha256Checksum = values.contains(.sha256Checksum) ? try values.decode(String.self, forKey: .sha256Checksum) : nil
        md5Checksum = values.contains(.md5Checksum) ? try values.decode(String.self, forKey: .md5Checksum) : nil
    }
}

private struct DrivePage<Response: Decodable>: Decodable {
    let files: [Response]
    let incompleteSearch: Bool
    let nextPageToken: String?

    private enum CodingKeys: String, CodingKey { case files, incompleteSearch, nextPageToken }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        files = try values.decode([Response].self, forKey: .files)
        incompleteSearch = values.contains(.incompleteSearch) ? try values.decode(Bool.self, forKey: .incompleteSearch) : false
        nextPageToken = try values.decodeIfPresent(String.self, forKey: .nextPageToken)
    }
}

private func driveResponse<Value: Decodable>(_ type: Value.Type, data: Data) throws -> Value {
    guard data.count <= 1_048_576 else { throw GoogleDriveMetadataError.responseTooLarge }
    do { return try JSONDecoder().decode(type, from: data) }
    catch { throw GoogleDriveMetadataError.malformedResponse }
}

private func validDriveID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
    }
}

private func validDriveString(_ value: String) -> Bool {
    !value.isEmpty && value.unicodeScalars.count <= 16_384
}

private func fileSearchRequest(folderID: String, filename: String, pageToken: String?) throws -> GoogleDriveMetadataRequest {
    try searchRequest(query: "'\(folderID)' in parents and name = '\(queryString(filename))' and trashed = false",
                      fields: "id,name,parents,trashed,size,md5Checksum,sha256Checksum", pageToken: pageToken)
}

private func queryString(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
}

private func searchRequest(query: String, fields: String, pageToken: String?) throws -> GoogleDriveMetadataRequest {
    var parameters = [
        ("q", query), ("fields", "nextPageToken,incompleteSearch,files(\(fields))"),
        ("spaces", "drive"), ("pageSize", "100"),
        ("supportsAllDrives", "true"), ("includeItemsFromAllDrives", "true")
    ]
    if let pageToken { parameters.append(("pageToken", pageToken)) }
    return try driveRequest(path: "/drive/v3/files", parameters: parameters)
}

private func driveRequest(path: String, parameters: [(String, String)]) throws -> GoogleDriveMetadataRequest {
    let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    let query = try parameters.map { key, value in
        guard let escaped = value.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw GoogleDriveMetadataError.malformedResponse
        }
        return key + "=" + escaped
    }.joined(separator: "&")
    var components = URLComponents()
    components.scheme = "https"
    components.host = "www.googleapis.com"
    components.path = path
    components.percentEncodedQuery = query
    guard let url = components.url else { throw GoogleDriveMetadataError.malformedResponse }
    return GoogleDriveMetadataRequest(url: url)
}
