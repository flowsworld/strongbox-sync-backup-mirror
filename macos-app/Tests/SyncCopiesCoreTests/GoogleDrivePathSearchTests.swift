import Foundation
import Testing
import SyncCopiesCore

private let pathSHA = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
private let pathMD5 = "900150983cd24fb0d6963f7d28e17f72"
private let childFolder = #"{"id":"child","name":"Backups","parents":["parent"],"mimeType":"application/vnd.google-apps.folder","trashed":false}"#
private let otherCopy = #"{"id":"other","name":"database.kdbx","parents":["elsewhere"],"trashed":false,"size":"3","md5Checksum":"900150983cd24fb0d6963f7d28e17f72","sha256Checksum":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}"#

private func pathPage(_ files: String = "", token: String? = nil, incomplete: Bool = false) throws -> Data {
    let next = try token.map { ",\"nextPageToken\":" + String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? ""
    return Data("{\"files\":[\(files)],\"incompleteSearch\":\(incomplete)\(next)}".utf8)
}

private func pathQuery(_ request: GoogleDriveMetadataRequest) throws -> [String: String] {
    let items = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
    return try Dictionary(uniqueKeysWithValues: items.map { ($0.name, try #require($0.value)) })
}

struct GoogleDrivePathSearchTests {
    private let folder: GoogleDriveFolder
    private let local: UploadLocalFingerprint

    init() throws {
        folder = try GoogleDriveMetadata.resolveFolder(
            Data(#"{"id":"parent","name":"My Drive","mimeType":"application/vnd.google-apps.folder","trashed":false}"#.utf8), requestedID: "root")
        local = try UploadLocalFingerprint(size: 3, sha256: pathSHA, md5: pathMD5)
    }

    @Test func folderSearchRequestsExactParentNameAndFolderMetadata() throws {
        let search = try GoogleDriveFolderSearch(folder: folder, name: "O'Brien\\Backups")
        let request = try #require(search.request)
        let parameters = try pathQuery(request)
        #expect(request.method == "GET")
        #expect(request.url.host == "www.googleapis.com")
        #expect(parameters["q"] == "'parent' in parents and name = 'O\\'Brien\\\\Backups' and mimeType = 'application/vnd.google-apps.folder' and trashed = false")
        #expect(parameters["fields"] == "nextPageToken,incompleteSearch,files(id,name,mimeType,parents,trashed)")
        #expect(!request.url.absoluteString.contains("alt=media"))
    }

    @Test func folderIsReturnedOnlyAfterTheLastPageAndMissingIsAllowed() throws {
        var search = try GoogleDriveFolderSearch(folder: folder, name: "Backups")
        guard case .nextPage(let next) = try search.consume(pathPage(childFolder, token: "more +&/")) else {
            Issue.record("A folder match must wait for all pages"); return
        }
        #expect(try pathQuery(next)["pageToken"] == "more +&/")
        guard case .complete(let match) = try search.consume(pathPage()) else { Issue.record("Expected completed path segment"); return }
        #expect(match?.id == "child")
        #expect(match?.name == "Backups")
        #expect(search.request == nil)
        #expect(throws: GoogleDriveMetadataError.searchFinished) { try search.consume(pathPage()) }
        var missing = try GoogleDriveFolderSearch(folder: folder, name: "Missing")
        #expect(try missing.consume(pathPage()) == .complete(nil))
    }

    @Test func duplicateFoldersIncludingSeparatePagesRequireManualSelection() throws {
        var samePage = try GoogleDriveFolderSearch(folder: folder, name: "Backups")
        #expect(throws: GoogleDriveMetadataError.ambiguousFolder) { try samePage.consume(pathPage(childFolder + "," + childFolder)) }
        var acrossPages = try GoogleDriveFolderSearch(folder: folder, name: "Backups")
        _ = try acrossPages.consume(pathPage(childFolder, token: "next"))
        #expect(throws: GoogleDriveMetadataError.ambiguousFolder) {
            try acrossPages.consume(pathPage(childFolder.replacingOccurrences(of: "child", with: "other-child")))
        }
        #expect(acrossPages.request == nil)
    }

    @Test func folderResponsesAreIndependentlyValidated() throws {
        for changed in [childFolder.replacingOccurrences(of: "Backups", with: "backups"),
                        childFolder.replacingOccurrences(of: "[\"parent\"]", with: "[\"wrong-parent\"]"),
                        childFolder.replacingOccurrences(of: "false", with: "true"),
                        childFolder.replacingOccurrences(of: "application/vnd.google-apps.folder", with: "application/octet-stream")] {
            var search = try GoogleDriveFolderSearch(folder: folder, name: "Backups")
            #expect(throws: GoogleDriveMetadataError.unexpectedFolder) { try search.consume(pathPage(changed)) }
            #expect(search.request == nil)
        }
        for changed in [childFolder.replacingOccurrences(of: "\"child\"", with: "\"../child\""),
                        childFolder.replacingOccurrences(of: "[\"parent\"]", with: "[\"parent\",\"bad/parent\"]"),
                        childFolder.replacingOccurrences(of: "false", with: "null")] {
            var search = try GoogleDriveFolderSearch(folder: folder, name: "Backups")
            #expect(throws: GoogleDriveMetadataError.malformedResponse) { try search.consume(pathPage(changed)) }
        }
    }

    @Test func bothNewSearchesRejectIncompleteAndCyclicPagination() throws {
        var folders = try GoogleDriveFolderSearch(folder: folder, name: "Backups")
        var copies = try GoogleDriveOtherCopiesSearch(filename: "database.kdbx", excludingFolderID: "parent", local: local)
        #expect(throws: GoogleDriveMetadataError.incompleteSearch) { try folders.consume(pathPage(childFolder, incomplete: true)) }
        #expect(throws: GoogleDriveMetadataError.incompleteSearch) { try copies.consume(pathPage(otherCopy, incomplete: true)) }
        #expect(folders.request == nil)
        #expect(copies.request == nil)
        folders = try GoogleDriveFolderSearch(folder: folder, name: "Backups")
        copies = try GoogleDriveOtherCopiesSearch(filename: "database.kdbx", excludingFolderID: "parent", local: local)
        _ = try folders.consume(pathPage(token: "same"))
        _ = try copies.consume(pathPage(token: "same"))
        #expect(throws: GoogleDriveMetadataError.paginationCycle) { try folders.consume(pathPage(token: "same")) }
        #expect(throws: GoogleDriveMetadataError.paginationCycle) { try copies.consume(pathPage(token: "same")) }
    }

    @Test func otherCopySearchUsesMetadataOnlyAndExcludesTheSelectedFolder() throws {
        let search = try GoogleDriveOtherCopiesSearch(filename: "O'Brien.kdbx", excludingFolderID: "parent", local: local)
        let request = try #require(search.request)
        #expect(request.method == "GET")
        #expect(try pathQuery(request)["q"] == "name = 'O\\'Brien.kdbx' and not 'parent' in parents and mimeType != 'application/vnd.google-apps.folder' and trashed = false")
        #expect(!request.url.absoluteString.contains("alt=media"))
        var invalidParent = try GoogleDriveOtherCopiesSearch(filename: "database.kdbx", excludingFolderID: "parent", local: local)
        #expect(throws: GoogleDriveMetadataError.unexpectedFile) {
            try invalidParent.consume(pathPage(otherCopy.replacingOccurrences(of: "elsewhere", with: "parent")))
        }
    }

    @Test func countsOnlySameSizeAndDigestWithSHA256PreferredOverMD5() throws {
        let md5Only = otherCopy.replacingOccurrences(of: ",\"sha256Checksum\":\"\(pathSHA)\"", with: "")
        let noDigest = md5Only.replacingOccurrences(of: ",\"md5Checksum\":\"\(pathMD5)\"", with: "")
        let cases: [(String, Int)] = [
            (otherCopy, 1), (md5Only, 1), (noDigest, 0),
            (otherCopy.replacingOccurrences(of: "\"size\":\"3\"", with: "\"size\":\"4\""), 0),
            (otherCopy.replacingOccurrences(of: pathSHA, with: String(repeating: "a", count: 64)), 0),
            (otherCopy.replacingOccurrences(of: pathMD5, with: String(repeating: "a", count: 32)), 1)
        ]
        for (file, count) in cases {
            var search = try GoogleDriveOtherCopiesSearch(filename: "database.kdbx", excludingFolderID: "parent", local: local)
            #expect(try search.consume(pathPage(file)) == .complete(count))
        }
    }

    @Test func identicalCopiesElsewhereAreCountedAcrossPagesWithoutAmbiguity() throws {
        var search = try GoogleDriveOtherCopiesSearch(filename: "database.kdbx", excludingFolderID: "parent", local: local)
        guard case .nextPage = try search.consume(pathPage(otherCopy, token: "more")) else { Issue.record("Expected continued copy count"); return }
        let second = otherCopy.replacingOccurrences(of: "\"other\"", with: "\"second\"")
        #expect(try search.consume(pathPage(second)) == .complete(2))
        #expect(search.request == nil)
        #expect(throws: GoogleDriveMetadataError.searchFinished) { try search.consume(pathPage()) }
    }

    @Test func malformedOrRepeatedCopyIDsCannotInflateTheWarningCount() throws {
        let malformed = [otherCopy.replacingOccurrences(of: "database.kdbx", with: "another.kdbx"),
                         otherCopy.replacingOccurrences(of: "false", with: "true"),
                         otherCopy.replacingOccurrences(of: "[\"elsewhere\"]", with: "[]"),
                         otherCopy.replacingOccurrences(of: "\"size\":\"3\"", with: "\"size\":\"-3\""),
                         otherCopy.replacingOccurrences(of: pathMD5, with: "bad"),
                         otherCopy + "," + otherCopy]
        for file in malformed {
            var search = try GoogleDriveOtherCopiesSearch(filename: "database.kdbx", excludingFolderID: "parent", local: local)
            #expect(throws: (any Error).self) { try search.consume(pathPage(file)) }
            #expect(search.request == nil)
        }
        var search = try GoogleDriveOtherCopiesSearch(filename: "database.kdbx", excludingFolderID: "parent", local: local)
        _ = try search.consume(pathPage(otherCopy, token: "more"))
        #expect(throws: GoogleDriveMetadataError.malformedResponse) { try search.consume(pathPage(otherCopy)) }
    }

    @Test func newSearchesKeepTheSamePageAndResponseBounds() throws {
        var folders = try GoogleDriveFolderSearch(folder: folder, name: "Backups")
        var copies = try GoogleDriveOtherCopiesSearch(filename: "database.kdbx", excludingFolderID: "parent", local: local)
        for index in 1..<100 {
            _ = try folders.consume(pathPage(token: "page-\(index)"))
            _ = try copies.consume(pathPage(token: "page-\(index)"))
        }
        #expect(try folders.consume(pathPage()) == .complete(nil))
        #expect(throws: GoogleDriveMetadataError.paginationLimit) { try copies.consume(pathPage(token: "page-100")) }
        var oversized = try GoogleDriveFolderSearch(folder: folder, name: "Backups")
        #expect(throws: GoogleDriveMetadataError.responseTooLarge) { try oversized.consume(Data(repeating: 32, count: 1_048_577)) }
    }
}
