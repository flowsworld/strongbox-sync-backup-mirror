import Foundation
import SyncCopiesCore
import XCTest
@testable import SyncCopies

@MainActor
final class GoogleDriveAccountsTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("drive-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func client() throws -> GoogleDriveOAuthClient {
        try GoogleDriveOAuthClient(clientID: "native-test.apps.googleusercontent.com", clientSecret: "public-client-secret")
    }

    private func tokens(refresh: String = "private-refresh", age: TimeInterval = 0) throws -> GoogleDriveOAuthTokens {
        let data = Data("{\"access_token\":\"private-access\",\"refresh_token\":\"\(refresh)\",\"expires_in\":3600,\"token_type\":\"Bearer\"}".utf8)
        return try GoogleDriveOAuthTokens.decodeResponse(data, receivedAt: age)
    }

    func testMultipleAccountsUsePermissionIDsAndPersistOnlyLabelsAndCredentialReferences() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = directory.appendingPathComponent("accounts.json")
        let keychain = DriveCredentialFixture()
        let http = DriveHTTPFixture(outcomes: [])
        let accounts = GoogleDriveAccounts(registryURL: registry, client: try client(), credentials: keychain.store, transport: http.transport, clock: { 0 })
        let first = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111", emailAddress: "same@example.invalid"), tokens: tokens())
        let second = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "222", emailAddress: "same@example.invalid"), tokens: tokens(refresh: "second-refresh"))
        XCTAssertNotEqual(first.account.id, second.account.id)
        XCTAssertEqual(first.account.id, "google-drive:111")
        let reloaded = GoogleDriveAccounts(registryURL: registry, client: try client(), credentials: keychain.store, transport: http.transport, clock: { 0 })
        let list = try await reloaded.list()
        XCTAssertEqual(Set(list.map(\.id)), ["google-drive:111", "google-drive:222"])
        let json = try String(contentsOf: registry, encoding: .utf8)
        for secret in ["private-refresh", "second-refresh", "private-access", "public-client-secret"] { XCTAssertFalse(json.contains(secret)) }
        let permissions = try FileManager.default.attributesOfItem(atPath: registry.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let secrets = await keychain.snapshot()
        XCTAssertEqual(secrets.count, 2)
    }

    func testReconnectKeepsStableIDAndDeferredCleanupCanBeRetried() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = directory.appendingPathComponent("accounts.json")
        let keychain = DriveCredentialFixture()
        let accounts = GoogleDriveAccounts(registryURL: registry, client: try client(), credentials: keychain.store,
                                          transport: DriveHTTPFixture(outcomes: []).transport, clock: { 0 })
        let old = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111", displayName: "Old label"), tokens: tokens())
        await keychain.failRemoval(true)
        let new = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111", displayName: "New label"), tokens: tokens(refresh: "new-refresh"))
        XCTAssertEqual(new.account.id, old.account.id)
        XCTAssertNotEqual(new.account.credentialID, old.account.credentialID)
        XCTAssertEqual(new.account.label, "New label")
        XCTAssertTrue(new.cleanupPending)
        let persisted = try String(contentsOf: registry, encoding: .utf8)
        XCTAssertTrue(persisted.contains(old.account.credentialID.uuidString))
        await keychain.failRemoval(false)
        let pending = try await accounts.retryCleanup()
        XCTAssertFalse(pending)
        let credentials = await keychain.snapshot()
        XCTAssertNil(credentials[old.account.credentialID])
        XCTAssertNotNil(credentials[new.account.credentialID])
        XCTAssertFalse(try String(contentsOf: registry, encoding: .utf8).contains(old.account.credentialID.uuidString))
    }

    func testRefreshUsesKeychainAndPersistsRotationWithoutPersistingAccessToken() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = directory.appendingPathComponent("accounts.json")
        let keychain = DriveCredentialFixture()
        let http = DriveHTTPFixture(outcomes: [.reply(200, #"{"access_token":"renewed-access","refresh_token":"rotated-refresh","expires_in":3600,"token_type":"Bearer"}"#)])
        let accounts = GoogleDriveAccounts(registryURL: registry, client: try client(), credentials: keychain.store, transport: http.transport, clock: { 3600 })
        let saved = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens())
        let first = try await accounts.accessToken(accountID: saved.account.id)
        let second = try await accounts.accessToken(accountID: saved.account.id)
        XCTAssertEqual(first, "renewed-access")
        XCTAssertEqual(second, "renewed-access")
        let snapshot = await http.snapshot()
        XCTAssertEqual(snapshot.requests.count, 1)
        let body = try XCTUnwrap(snapshot.requests.first?.httpBody)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("refresh_token=private-refresh"))
        let credentials = await keychain.snapshot()
        let secret = String(decoding: try XCTUnwrap(credentials[saved.account.credentialID]), as: UTF8.self)
        XCTAssertTrue(secret.contains("rotated-refresh"))
        XCTAssertFalse(secret.contains("renewed-access"))
        let settings = try String(contentsOf: registry, encoding: .utf8)
        XCTAssertFalse(settings.contains("rotated-refresh"))
        XCTAssertFalse(settings.contains("renewed-access"))
    }

    func testListingRetriesDeferredReconnectAndDisconnectCleanupWithoutDeletingActiveCredentials() async throws {
        for disconnect in [false, true] {
            let directory = try directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let registry = directory.appendingPathComponent("accounts.json")
            let keychain = DriveCredentialFixture()
            let transport = DriveHTTPFixture(outcomes: []).transport
            let accounts = GoogleDriveAccounts(registryURL: registry, client: try client(), credentials: keychain.store,
                                              transport: transport, clock: { 0 })
            let previous = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens())
            let other = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "222"), tokens: tokens(refresh: "other-refresh"))
            await keychain.failRemoval(true)
            var active = [other.account]
            if disconnect {
                let result = try await accounts.disconnect(accountID: previous.account.id)
                XCTAssertTrue(result.cleanupPending)
            } else {
                let replacement = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens(refresh: "replacement-refresh"))
                XCTAssertTrue(replacement.cleanupPending)
                active.append(replacement.account)
            }
            let lockedList = try await accounts.list()
            XCTAssertEqual(lockedList.sorted { $0.id < $1.id }, active.sorted { $0.id < $1.id })
            let pendingWhileLocked = try await accounts.hasPendingCleanup()
            XCTAssertTrue(pendingWhileLocked)
            let lockedCredentials = await keychain.snapshot()
            XCTAssertNotNil(lockedCredentials[previous.account.credentialID])
            await keychain.failRemoval(false)
            let reopened = GoogleDriveAccounts(registryURL: registry, client: try client(), credentials: keychain.store,
                                              transport: transport, clock: { 0 })
            let cleanedList = try await reopened.list()
            XCTAssertEqual(cleanedList.sorted { $0.id < $1.id }, active.sorted { $0.id < $1.id })
            let remaining = await keychain.snapshot()
            XCTAssertNil(remaining[previous.account.credentialID])
            XCTAssertEqual(Set(remaining.keys), Set(active.map(\.credentialID)))
            let pendingAfterCleanup = try await reopened.hasPendingCleanup()
            XCTAssertFalse(pendingAfterCleanup)
        }
    }

    func testListingOwnsCleanupWhileCredentialRemovalIsSuspended() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = DriveCredentialFixture()
        let accounts = GoogleDriveAccounts(registryURL: directory.appendingPathComponent("accounts.json"), client: try client(),
                                          credentials: keychain.store, transport: DriveHTTPFixture(outcomes: []).transport)
        let previous = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens())
        await keychain.failRemoval(true)
        let active = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens(refresh: "replacement"))
        await keychain.failRemoval(false)
        await keychain.suspendNextRemoval()
        let listing = Task { try await accounts.list() }
        let deadline = Date().addingTimeInterval(2)
        while !(await keychain.isRemovalSuspended), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let suspended = await keychain.isRemovalSuspended
        XCTAssertTrue(suspended)
        do {
            _ = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "222"), tokens: tokens())
            XCTFail("Credential cleanup allowed a concurrent registry mutation")
        } catch { XCTAssertEqual(error as? GoogleDriveAccountFailure, .busy) }
        let concurrentList = try await accounts.list()
        XCTAssertEqual(concurrentList, [active.account])
        let stillPending = try await accounts.hasPendingCleanup()
        XCTAssertTrue(stillPending)
        await keychain.releaseRemoval()
        let list = try await listing.value
        XCTAssertEqual(list, [active.account])
        let remaining = await keychain.snapshot()
        XCTAssertNil(remaining[previous.account.credentialID])
        XCTAssertEqual(Set(remaining.keys), [active.account.credentialID])
        let pending = try await accounts.hasPendingCleanup()
        XCTAssertFalse(pending)
    }

    func testLocalDisconnectWorksOfflineAndFailedRevocationStillDisconnects() async throws {
        for revoke in [false, true] {
            let directory = try directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let keychain = DriveCredentialFixture()
            let http = DriveHTTPFixture(outcomes: [.reply(403, "refused")])
            let accounts = GoogleDriveAccounts(registryURL: directory.appendingPathComponent("accounts.json"), client: try client(),
                                              credentials: keychain.store, transport: http.transport, clock: { 0 })
            let saved = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens())
            let result = try await accounts.disconnect(accountID: saved.account.id, revokeGoogleGrant: revoke)
            let list = try await accounts.list()
            XCTAssertTrue(list.isEmpty)
            XCTAssertFalse(result.cleanupPending)
            switch result.revocation {
            case .notRequested: XCTAssertFalse(revoke)
            case .failed: XCTAssertTrue(revoke)
            case .confirmed: XCTFail("Unexpected online revocation success")
            }
            let snapshot = await http.snapshot()
            XCTAssertEqual(snapshot.requests.count, revoke ? 1 : 0)
            let secrets = await keychain.snapshot()
            XCTAssertTrue(secrets.isEmpty)
        }
    }

    func testCorruptRegistryNeverOverwritesOrCreatesCredentials() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = directory.appendingPathComponent("accounts.json")
        let bad = Data(#"{"accounts":[{"drivePermissionID":"../bad","credentialID":"a"}],"pendingRemovals":[]}"#.utf8)
        try bad.write(to: registry)
        let keychain = DriveCredentialFixture()
        let accounts = GoogleDriveAccounts(registryURL: registry, client: try client(), credentials: keychain.store,
                                          transport: DriveHTTPFixture(outcomes: []).transport)
        do { _ = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens()); XCTFail("Expected invalid registry") }
        catch { XCTAssertEqual(error as? GoogleDriveAccountFailure, .invalidRegistry) }
        XCTAssertEqual(try Data(contentsOf: registry), bad)
        let secrets = await keychain.snapshot()
        XCTAssertTrue(secrets.isEmpty)
    }

    func testCredentialFailureBeforeCommitRollsBackStagedSecret() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = DriveCredentialFixture()
        await keychain.failAddAfterWrite(true)
        let registry = directory.appendingPathComponent("accounts.json")
        let accounts = GoogleDriveAccounts(registryURL: registry, client: try client(), credentials: keychain.store,
                                          transport: DriveHTTPFixture(outcomes: []).transport)
        do { _ = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens()); XCTFail("Expected credential error") }
        catch { XCTAssertEqual(error as? GoogleDriveAccountFailure, .credentialsUnavailable) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: registry.path))
        let secrets = await keychain.snapshot()
        XCTAssertTrue(secrets.isEmpty)
    }

    func testCancelledReconnectPreservesPreviousAccountAndRemovesStagedCredential() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = DriveCredentialFixture()
        let registry = directory.appendingPathComponent("accounts.json")
        let accounts = GoogleDriveAccounts(registryURL: registry, client: try client(), credentials: keychain.store,
                                          transport: DriveHTTPFixture(outcomes: []).transport)
        let previous = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens())
        let savedRegistry = try Data(contentsOf: registry)
        await keychain.suspendNextAdd()
        let reconnect = Task { try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens(refresh: "replacement")) }
        let deadline = Date().addingTimeInterval(2)
        while !(await keychain.isAddSuspended), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let suspended = await keychain.isAddSuspended
        XCTAssertTrue(suspended)
        reconnect.cancel()
        await keychain.releaseAdd()
        do { _ = try await reconnect.value; XCTFail("Cancelled reconnect committed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: registry), savedRegistry)
        let credentials = await keychain.snapshot()
        XCTAssertEqual(Set(credentials.keys), [previous.account.credentialID])
    }

    func testEveryRemoteLookupResolvesFolderAndSearchesByNameAgain() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = #"{"id":"folder","name":"Sync","mimeType":"application/vnd.google-apps.folder","trashed":false}"#
        let http = DriveHTTPFixture(outcomes: [.reply(200, folder), .reply(200, #"{"files":[],"incompleteSearch":false}"#),
                                              .reply(200, folder), .reply(200, #"{"files":[{"id":"new-id","name":"vault.kdbx","parents":["folder"],"size":"3","md5Checksum":"900150983cd24fb0d6963f7d28e17f72","trashed":false}],"incompleteSearch":false}"#)])
        let accounts = GoogleDriveAccounts(registryURL: directory.appendingPathComponent("accounts.json"), client: try client(),
                                          credentials: DriveCredentialFixture().store, transport: http.transport, clock: { 0 })
        let saved = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens())
        let absent = try await accounts.remoteFile(accountID: saved.account.id, folderID: "folder", filename: "vault.kdbx")
        XCTAssertNil(absent)
        let recreated = try await accounts.remoteFile(accountID: saved.account.id, folderID: "folder", filename: "vault.kdbx")
        XCTAssertEqual(recreated?.id, "new-id")
        let snapshot = await http.snapshot()
        XCTAssertEqual(snapshot.requests.count, 4)
        XCTAssertEqual(snapshot.requests[0].url, snapshot.requests[2].url)
        XCTAssertEqual(snapshot.requests[1].url, snapshot.requests[3].url)
        XCTAssertFalse(snapshot.requests.contains { $0.url?.path.contains("new-id") == true })
    }

    func testConcurrentRefreshesShareOneRequestAndDisconnectCancelsInFlightRefresh() async throws {
        for disconnect in [false, true] {
            let directory = try directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let http = DriveSuspendedHTTPFixture()
            let accounts = GoogleDriveAccounts(registryURL: directory.appendingPathComponent("accounts.json"), client: try client(),
                                              credentials: DriveCredentialFixture().store, transport: http.transport, clock: { 3600 })
            let saved = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens())
            let first = Task { try await accounts.accessToken(accountID: saved.account.id) }
            let second = Task { try await accounts.accessToken(accountID: saved.account.id) }
            let deadline = Date().addingTimeInterval(2)
            while await http.count == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
            let count = await http.count
            XCTAssertEqual(count, 1)
            if disconnect {
                _ = try await accounts.disconnect(accountID: saved.account.id)
                for task in [first, second] {
                    do { _ = try await task.value; XCTFail("Disconnected account returned an access token") }
                    catch { XCTAssertTrue(error is CancellationError || error as? GoogleDriveAccountFailure == .accountChanged) }
                }
            } else {
                await http.release()
                let values = try await [first.value, second.value]
                XCTAssertEqual(values, ["renewed-access", "renewed-access"])
            }
            let finalCount = await http.count
            XCTAssertEqual(finalCount, 1)
        }
    }
}

private actor DriveSuspendedHTTPFixture {
    private var released = false
    private(set) var count = 0
    nonisolated var transport: GoogleDriveTransport {
        GoogleDriveTransport(send: { _ in try await self.send() }, ready: { _ in }, sleep: { _ in })
    }
    func release() { released = true }
    private func send() async throws -> GoogleDriveHTTPReply {
        count += 1
        while !released { try await Task.sleep(for: .milliseconds(1)) }
        try Task.checkCancellation()
        return GoogleDriveHTTPReply(statusCode: 200, body: Data(#"{"access_token":"renewed-access","expires_in":3600,"token_type":"Bearer"}"#.utf8))
    }
}

actor DriveCredentialFixture {
    private var values: [UUID: Data] = [:]
    private var removalFails = false
    private var addAfterWriteFails = false
    private var shouldSuspendAdd = false
    private var addContinuation: CheckedContinuation<Void, Never>?
    var isAddSuspended: Bool { addContinuation != nil }
    private var shouldSuspendRemoval = false
    private var removalContinuation: CheckedContinuation<Void, Never>?
    var isRemovalSuspended: Bool { removalContinuation != nil }
    nonisolated var store: GoogleDriveCredentialStore {
        GoogleDriveCredentialStore(read: { try await self.read($0) }, add: { try await self.add($0, data: $1) },
                                   update: { try await self.update($0, data: $1) }, remove: { try await self.remove($0) })
    }
    func read(_ id: UUID) throws -> Data {
        guard let data = values[id] else { throw GoogleDriveAccountFailure.credentialsMissing }
        return data
    }
    func add(_ id: UUID, data: Data) async throws {
        values[id] = data
        if shouldSuspendAdd {
            shouldSuspendAdd = false
            await withCheckedContinuation { addContinuation = $0 }
        }
        if addAfterWriteFails { throw GoogleDriveAccountFailure.credentialsUnavailable }
    }
    func update(_ id: UUID, data: Data) throws {
        guard values[id] != nil else { throw GoogleDriveAccountFailure.credentialsMissing }
        values[id] = data
    }
    func remove(_ id: UUID) async throws {
        if shouldSuspendRemoval {
            shouldSuspendRemoval = false
            await withCheckedContinuation { removalContinuation = $0 }
        }
        if removalFails { throw GoogleDriveAccountFailure.credentialsUnavailable }
        values.removeValue(forKey: id)
    }
    func failRemoval(_ fail: Bool) { removalFails = fail }
    func failAddAfterWrite(_ fail: Bool) { addAfterWriteFails = fail }
    func suspendNextAdd() { shouldSuspendAdd = true }
    func releaseAdd() { addContinuation?.resume(); addContinuation = nil }
    func suspendNextRemoval() { shouldSuspendRemoval = true }
    func releaseRemoval() { removalContinuation?.resume(); removalContinuation = nil }
    func snapshot() -> [UUID: Data] { values }
}
