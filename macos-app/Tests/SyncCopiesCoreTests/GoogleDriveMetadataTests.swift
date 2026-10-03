import Foundation
import Testing
import SyncCopiesCore

private let driveSHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
private let driveMD5 = "900150983cd24fb0d6963f7d28e17f72"
private let folderJSON = #"{"id":"folder-1","name":"Test folder","mimeType":"application/vnd.google-apps.folder","trashed":false}"#
private let fileJSON = #"{"id":"file-1","name":"database.kdbx","parents":["folder-1"],"trashed":false,"size":"3","md5Checksum":"900150983cd24fb0d6963f7d28e17f72","sha256Checksum":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}"#

private func filePage(_ files: String = "", token: String? = nil) throws -> Data {
    let continuation: String
    if let token {
        continuation = ",\"nextPageToken\":" + String(decoding: try JSONEncoder().encode(token), as: UTF8.self)
    } else { continuation = "" }
    return Data("{\"files\":[\(files)],\"incompleteSearch\":false\(continuation)}".utf8)
}

private func query(_ request: GoogleDriveMetadataRequest) throws -> [String: String] {
    let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
    return try Dictionary(uniqueKeysWithValues: #require(components.queryItems).map {
        ($0.name, try #require($0.value))
    })
}

struct GoogleDriveMetadataTests {
    private let folder: GoogleDriveFolder

    init() throws {
        folder = try GoogleDriveMetadata.resolveFolder(Data(folderJSON.utf8), requestedID: "folder-1")
    }

    @Test func acceptsOnlyRecognizedFolderAndMyDriveSelections() throws {
        for link in ["folder-1", "https://drive.google.com/drive/folders/folder-1",
                     "https://drive.google.com/drive/u/12/folders/folder-1/?usp=sharing#ignored"] {
            #expect(try GoogleDriveMetadata.folderID(from: link) == "folder-1")
        }
        for link in ["root", "https://drive.google.com/drive/my-drive", "https://drive.google.com/drive/u/0/my-drive/"] {
            #expect(try GoogleDriveMetadata.folderID(from: link) == "root")
        }
        for input in ["", "../folder", "https://example.com/drive/folders/folder-1",
                      "http://drive.google.com/drive/folders/folder-1", "https://drive.google.com:443/drive/folders/folder-1",
                      "https://drive.google.com:/drive/folders/folder-1", "https://user@drive.google.com/drive/folders/folder-1",
                      "https://drive.google.com.evil/drive/folders/folder-1", "https://drive.google.com/drive/folders/%66older-1",
                      "https://drive.google.com/drive/folders/folder-1/child", "https://drive.google.com/drive/u/-1/my-drive",
                      "https://drive.google.com//drive/folders/folder-1", "https://drive.google.com/drive/folders/folder-1//",
                      "https://drive.google.com/drive/u/٠/my-drive", String(repeating: "a", count: 257)] {
            #expect(throws: GoogleDriveMetadataError.invalidFolderURL) { try GoogleDriveMetadata.folderID(from: input) }
        }
    }

    @Test func folderRequestsAreFixedMetadataGETs() throws {
        let request = try GoogleDriveMetadata.folderRequest(id: "folder-1")
        #expect(request.method == "GET")
        #expect(request.url.scheme == "https")
        #expect(request.url.host == "www.googleapis.com")
        #expect(request.url.path == "/drive/v3/files/folder-1")
        #expect(try query(request) == ["fields": "id,name,mimeType,trashed", "supportsAllDrives": "true"])
        for id in ["", "../media", "folder?alt=media", "folder/name", "folder%2fname"] {
            #expect(throws: GoogleDriveMetadataError.invalidFolderID) { try GoogleDriveMetadata.folderRequest(id: id) }
        }
    }

    @Test func rootResolvesButExplicitFolderIdentityMustMatch() throws {
        let resolved = try GoogleDriveMetadata.resolveFolder(Data(folderJSON.utf8), requestedID: "root")
        #expect(resolved.id == "folder-1")
        #expect(resolved.name == "Test folder")
        #expect(throws: GoogleDriveMetadataError.unexpectedFolder) {
            try GoogleDriveMetadata.resolveFolder(Data(folderJSON.utf8), requestedID: "another-folder")
        }
        for changed in [folderJSON.replacingOccurrences(of: "false", with: "true"),
                        folderJSON.replacingOccurrences(of: "application/vnd.google-apps.folder", with: "application/octet-stream")] {
            #expect(throws: GoogleDriveMetadataError.unexpectedFolder) {
                try GoogleDriveMetadata.resolveFolder(Data(changed.utf8), requestedID: "folder-1")
            }
        }
        for changed in [folderJSON.replacingOccurrences(of: "false", with: "0"),
                        folderJSON.replacingOccurrences(of: "false", with: "null"),
                        folderJSON.replacingOccurrences(of: "folder-1", with: "folder/name"),
                        folderJSON.replacingOccurrences(of: "Test folder", with: ""), "[]"] {
            #expect(throws: GoogleDriveMetadataError.malformedResponse) {
                try GoogleDriveMetadata.resolveFolder(Data(changed.utf8), requestedID: "folder-1")
            }
        }
    }

    @Test func queryEscapingAndPercentEncodingAreSeparate() throws {
        let search = try GoogleDriveFileSearch(folder: folder, filename: "O'Brien\\copy+ &é.kdbx")
        let request = try #require(search.request)
        #expect(request.method == "GET")
        #expect(request.url.host == "www.googleapis.com")
        #expect(request.url.path == "/drive/v3/files")
        let parameters = try query(request)
        #expect(parameters == [
            "q": "'folder-1' in parents and name = 'O\\'Brien\\\\copy+ &é.kdbx' and trashed = false",
            "fields": "nextPageToken,incompleteSearch,files(id,name,parents,trashed,size,md5Checksum,sha256Checksum)",
            "spaces": "drive", "pageSize": "100", "supportsAllDrives": "true", "includeItemsFromAllDrives": "true"
        ])
        let encoded = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        #expect(encoded.contains("%2B%20%26%C3%A9"))
        #expect(encoded.contains("%5C%27"))
        #expect(!encoded.contains("+"))
        #expect(!request.url.absoluteString.contains("alt=media"))
    }

    @Test func decodesValidatedBinaryMetadataAndNormalizesDigests() throws {
        var search = try GoogleDriveFileSearch(folder: folder, filename: "database.kdbx")
        let uppercase = fileJSON.replacingOccurrences(of: driveSHA256, with: driveSHA256.uppercased())
            .replacingOccurrences(of: driveMD5, with: driveMD5.uppercased())
        let result = try search.consume(filePage(uppercase))
        guard case .complete(let match) = result else { Issue.record("One final page must finish the search"); return }
        let file = try #require(match)
        #expect(file.id == "file-1")
        #expect(file.size == 3)
        #expect(file.sha256 == driveSHA256)
        #expect(file.md5 == driveMD5)
        #expect(search.request == nil)
        #expect(throws: GoogleDriveMetadataError.searchFinished) { try search.consume(filePage()) }
    }

    @Test func permitsMD5FallbackAndMissingDigestsWithoutInventingConfirmation() throws {
        var fallback = try GoogleDriveFileSearch(folder: folder, filename: "database.kdbx")
        let md5Only = fileJSON.replacingOccurrences(of: ",\"sha256Checksum\":\"\(driveSHA256)\"", with: "")
        let result = try fallback.consume(filePage(md5Only))
        guard case .complete(let match) = result else { Issue.record("Expected final page"); return }
        #expect(match?.sha256 == nil)
        #expect(match?.md5 == driveMD5)

        var noDigest = try GoogleDriveFileSearch(folder: folder, filename: "database.kdbx")
        let metadataOnly = md5Only.replacingOccurrences(of: ",\"md5Checksum\":\"\(driveMD5)\"", with: "")
        let noDigestResult = try noDigest.consume(filePage(metadataOnly))
        guard case .complete(let noDigestMatch) = noDigestResult else { Issue.record("Expected final page"); return }
        let file = try #require(noDigestMatch)
        let context = try UploadVerificationContext(providerID: "google-drive", accountID: "test", folderID: folder.id,
                                                    filename: "database.kdbx", destinationID: "test-target")
        let local = try UploadLocalFingerprint(size: 3, sha256: driveSHA256, md5: driveMD5)
        #expect(UploadVerification.evaluate(context: context, local: local, outcome: .file(file), now: 100).status == .error(.unsupportedChecksum))
    }

    @Test func sizeMustBeADecimalStringWithinTheNativeFileSizeRange() throws {
        for invalid in ["3", "true", "null", "\"-1\"", "\"3.0\"", "\"3e0\"", "\"٣\"", "\"\"",
                        "\"9223372036854775808\"", "\"100000000000000000000\"", "\" 3\""] {
            var search = try GoogleDriveFileSearch(folder: folder, filename: "database.kdbx")
            let changed = fileJSON.replacingOccurrences(of: "\"size\":\"3\"", with: "\"size\":\(invalid)")
            #expect(throws: GoogleDriveMetadataError.malformedResponse) { try search.consume(filePage(changed)) }
            #expect(search.request == nil)
        }
        var search = try GoogleDriveFileSearch(folder: folder, filename: "database.kdbx")
        let result = try search.consume(filePage(fileJSON.replacingOccurrences(of: "\"size\":\"3\"", with: "\"size\":\"0003\"")))
        guard case .complete(let match) = result else { Issue.record("Expected final page"); return }
        #expect(match?.size == 3)
    }

    @Test func fileMustMatchTheExactNameAndParentAndBeUntrashed() throws {
        let unexpected = [fileJSON.replacingOccurrences(of: "database.kdbx", with: "Database.kdbx"),
                          fileJSON.replacingOccurrences(of: "folder-1", with: "folder-other"),
                          fileJSON.replacingOccurrences(of: "false", with: "true")]
        for changed in unexpected {
            var search = try GoogleDriveFileSearch(folder: folder, filename: "database.kdbx")
            #expect(throws: GoogleDriveMetadataError.unexpectedFile) { try search.consume(filePage(changed)) }
        }
        let malformed = [fileJSON.replacingOccurrences(of: "false", with: "0"),
                         fileJSON.replacingOccurrences(of: "[\"folder-1\"]", with: "[\"folder-1\",true]"),
                         fileJSON.replacingOccurrences(of: "\"file-1\"", with: "\"../file\""),
                         fileJSON.replacingOccurrences(of: "\"name\":\"database.kdbx\",", with: "")]
        for changed in malformed {
            var search = try GoogleDriveFileSearch(folder: folder, filename: "database.kdbx")
            #expect(throws: GoogleDriveMetadataError.malformedResponse) { try search.consume(filePage(changed)) }
        }
    }

    @Test func malformedWeakDigestStillFailsWhenSHA256IsValid() throws {
        for invalid in ["null", "true", "\"bad\"", "\"\(String(repeating: "g", count: 32))\""] {
            var search = try GoogleDriveFileSearch(folder: folder, filename: "database.kdbx")
            let changed = fileJSON.replacingOccurrences(of: "\"md5Checksum\":\"\(driveMD5)\"", with: "\"md5Checksum\":\(invalid)")
            #expect(throws: GoogleDriveMetadataError.malformedResponse) { try search.consume(filePage(changed)) }
        }
        var search = try GoogleDriveFileSearch(folder: folder, filename: "database.kdbx")
        let nullSHA = fileJSON.replacingOccurrences(of: "\"sha256Checksum\":\"\(driveSHA256)\"", with: "\"sha256Checksum\":null")
        #expect(throws: GoogleDriveMetadataError.malformedResponse) { try search.consume(filePage(nullSHA)) }
    }

    @Test func duplicateMatchesFailEvenOnSeparatePagesAndEndTheSearch() throws {
        var samePage = try GoogleDriveFileSearch(folder: folder, filename: "database.kdbx")
        #expect(throws: GoogleDriveMetadataError.ambiguousFile) { try samePage.consume(filePage(fileJSON + "," + fileJSON)) }
        var search = try GoogleDriveFileSearch(folder: folder, filename: "database.kdbx")
        let first = try search.consume(filePage(fileJSON, token: "next"))
        guard case .nextPage = first else { Issue.record("A partial match must not finish a search"); return }
        let second = fileJSON.replacingOccurrences(of: "file-1", with: "file-2")
        #expect(throws: GoogleDriveMetadataError.ambiguousFile) { try search.consume(filePage(second)) }
        #expect(search.request == nil)
        #expect(throws: GoogleDriveMetadataError.searchFinished) { try search.consume(filePage()) }
    }

    @Test func emptyContinuedPagesAndPageTokenEscapingPreserveTheSearch() throws {
        var search = try GoogleDriveFileSearch(folder: folder, filename: "database.kdbx")
        let first = try search.consume(filePage(token: "next +&/"))
        guard case .nextPage(let next) = first else { Issue.record("Empty page with continuation must continue"); return }
        #expect(try query(next)["pageToken"] == "next +&/")
        #expect(next.url.absoluteString.contains("pageToken=next%20%2B%26%2F"))
        let found = try search.consume(filePage(fileJSON, token: "final"))
        guard case .nextPage = found else { Issue.record("A found file still needs the remaining pages"); return }
        let last = try search.consume(filePage())
        guard case .complete(let match) = last else { Issue.record("Expected final page"); return }
        #expect(match?.id == "file-1")
    }

    @Test func incompleteOrMalformedPagesCannotBecomeMissingFileResults() throws {
        for response in [#"{"files":[],"incompleteSearch":true}"#,
                         #"{"files":[],"incompleteSearch":null}"#,
                         #"{"files":[],"incompleteSearch":0}"#, #"{"incompleteSearch":false}"#,
                         #"{"files":null}"#, #"{"files":{}}"#, #"{"files":[null]}"#, "[]", "{bad}"] {
            var search = try GoogleDriveFileSearch(folder: folder, filename: "database.kdbx")
            #expect(throws: (any Error).self) { try search.consume(Data(response.utf8)) }
            #expect(search.request == nil)
        }
        for response in [#"{"files":[]}"#, #"{"files":[],"nextPageToken":null}"#] {
            var search = try GoogleDriveFileSearch(folder: folder, filename: "database.kdbx")
            #expect(try search.consume(Data(response.utf8)) == .complete(nil))
        }
    }

    @Test func invalidOrRepeatedPageTokensFailClosed() throws {
        for token in ["", String(repeating: "t", count: 16_385)] {
            var search = try GoogleDriveFileSearch(folder: folder, filename: "database.kdbx")
            #expect(throws: GoogleDriveMetadataError.invalidPageToken) { try search.consume(filePage(token: token)) }
        }
        var malformed = try GoogleDriveFileSearch(folder: folder, filename: "database.kdbx")
        #expect(throws: GoogleDriveMetadataError.malformedResponse) {
            try malformed.consume(Data(#"{"files":[],"nextPageToken":123}"#.utf8))
        }
        var search = try GoogleDriveFileSearch(folder: folder, filename: "database.kdbx")
        _ = try search.consume(filePage(token: "first"))
        _ = try search.consume(filePage(token: "second"))
        #expect(throws: GoogleDriveMetadataError.paginationCycle) { try search.consume(filePage(token: "first")) }
        #expect(search.request == nil)
    }

    @Test func hundredPageLimitAllowsACompleteHundredthPage() throws {
        var complete = try GoogleDriveFileSearch(folder: folder, filename: "database.kdbx")
        var incomplete = try GoogleDriveFileSearch(folder: folder, filename: "database.kdbx")
        for index in 1..<100 {
            _ = try complete.consume(filePage(token: "page-\(index)"))
            _ = try incomplete.consume(filePage(token: "page-\(index)"))
        }
        #expect(try complete.consume(filePage()) == .complete(nil))
        #expect(throws: GoogleDriveMetadataError.paginationLimit) { try incomplete.consume(filePage(token: "page-100")) }
        #expect(incomplete.request == nil)
    }

    @Test func eachFreshSearchCanDiscoverARecreatedFileID() throws {
        for id in ["file-1", "file-recreated"] {
            var search = try GoogleDriveFileSearch(folder: folder, filename: "database.kdbx")
            #expect(try query(#require(search.request))["q"] == "'folder-1' in parents and name = 'database.kdbx' and trashed = false")
            let result = try search.consume(filePage(fileJSON.replacingOccurrences(of: "file-1", with: id)))
            guard case .complete(let match) = result else { Issue.record("Expected final page"); return }
            #expect(match?.id == id)
        }
    }

    @Test func boundsResponsesAndFilenameInput() throws {
        let excessive = Data(repeating: 32, count: 1_048_577)
        #expect(throws: GoogleDriveMetadataError.responseTooLarge) {
            try GoogleDriveMetadata.resolveFolder(excessive, requestedID: "folder-1")
        }
        var search = try GoogleDriveFileSearch(folder: folder, filename: "database.kdbx")
        #expect(throws: GoogleDriveMetadataError.responseTooLarge) { try search.consume(excessive) }
        #expect(search.request == nil)
        for name in ["", String(repeating: "a", count: 1025)] {
            #expect(throws: GoogleDriveMetadataError.invalidFilename) { try GoogleDriveFileSearch(folder: folder, filename: name) }
        }
    }
}
