import Darwin
import Foundation
import Testing
import SyncCopiesCore
@testable import SyncCopies

private actor ReplacingDriveProvider {
    let account: GoogleDriveAccount
    private let localFile: URL
    private let remote: UploadRemoteFile
    private var replaceOnAccountLookup = false
    private(set) var replaced = false

    init(localFile: URL, fingerprint: UploadLocalFingerprint) throws {
        self.localFile = localFile
        account = GoogleDriveAccount(identity: try GoogleDriveIdentity(drivePermissionID: "synthetic-account"),
                                     credentialID: UUID())
        remote = try UploadRemoteFile(id: "synthetic-file", size: fingerprint.size, sha256: fingerprint.sha256)
    }

    func accounts() throws -> [GoogleDriveAccount] {
        if replaceOnAccountLookup {
            try Data("xyz".utf8).write(to: localFile, options: .atomic)
            replaceOnAccountLookup = false
            replaced = true
        }
        return [account]
    }

    func matchingFile() -> UploadRemoteFile {
        replaceOnAccountLookup = true
        return remote
    }
}

@MainActor
struct DriveResultFreshnessTests {
    @Test func localReplacementDuringFinalAccountLookupCannotConfirmOldBytes() async throws {
        let candidate = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        let resolved = try #require(realpath(candidate.path, nil))
        defer { free(resolved) }
        let directory = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let filename = "fixture.kdbx"
        let localFile = directory.appendingPathComponent(filename)
        try Data("abc".utf8).write(to: localFile)
        let fingerprint = try UploadFingerprint.read(directory: directory, filename: filename)
        let provider = try ReplacingDriveProvider(localFile: localFile, fingerprint: fingerprint)
        let account = provider.account
        let databaseID = UUID()
        var delivered: [DriveVerificationEvent] = []
        let environment = DriveVerificationEnvironment(
            listAccounts: { try await provider.accounts() }, connect: { account }, cancelConnect: {},
            disconnect: { _ in }, resolveFolder: { _, folderID in
                try GoogleDriveMetadata.resolveFolder(
                    Data(#"{"id":"synthetic-folder","name":"Fixture folder","mimeType":"application/vnd.google-apps.folder","trashed":false}"#.utf8),
                    requestedID: folderID)
            }, remoteFile: { _, _, _ in await provider.matchingFile() }, localInputs: {
                [DriveLocalInput(id: databaseID, name: "Fixture database", filename: filename,
                                destinationID: "synthetic-destination", makeSnapshot: {
                    let snapshot = try UploadFingerprint.snapshot(directory: directory, filename: filename)
                    return DriveLocalSnapshot(fingerprint: snapshot.fingerprint, validate: { try snapshot.validate() })
                })]
            }, deliver: { event in delivered.append(event); return .delivered },
            cancelNotification: { _ in }, history: { _ in }, clock: { 100 })
        let controller = DriveVerificationController(settingsURL: directory.appendingPathComponent("settings.json"),
                                                     environment: environment)
        await controller.start()
        var preferences = DriveNotificationPreferences()
        preferences.confirmed = true
        try controller.setPreferences(preferences)
        try await controller.selectFolder(databaseID: databaseID, accountID: account.id, input: "synthetic-folder")
        for _ in 0..<10_000 {
            if await provider.replaced, !controller.isChecking { break }
            await Task.yield()
        }
        try #require(await provider.replaced)
        #expect(!controller.isChecking)
        #expect(try Data(contentsOf: localFile) == Data("xyz".utf8))
        #expect(controller.results[databaseID]?.status == .error(.localFileChanged))
        #expect(!delivered.contains { $0.kind == .confirmed })
    }
}
