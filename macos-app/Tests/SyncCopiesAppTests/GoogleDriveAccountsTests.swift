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

    func testCommittedRegistryMustBeDurableBeforeRemovingPreviousCredentials() async throws {
        for disconnect in [false, true] {
            let directory = try directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let registry = directory.appendingPathComponent("accounts.json")
            let keychain = DriveCredentialFixture()
            let sync = RegistryDirectorySyncFixture()
            let transport = DriveHTTPFixture(outcomes: []).transport
            let accounts = GoogleDriveAccounts(registryURL: registry, client: try client(), credentials: keychain.store,
                                              transport: transport, synchronizeDirectory: { try sync.synchronize($0) })
            let previous = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens())
            sync.failAfter(successes: disconnect ? 0 : 1)
            var active: [GoogleDriveAccount] = []
            if disconnect {
                let result = try await accounts.disconnect(accountID: previous.account.id)
                XCTAssertTrue(result.cleanupPending)
            } else {
                let result = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens(refresh: "new-refresh"))
                XCTAssertTrue(result.cleanupPending)
                active = [result.account]
            }
            let retained = await keychain.snapshot()
            XCTAssertNotNil(retained[previous.account.credentialID])
            for account in active { XCTAssertNotNil(retained[account.credentialID]) }
            let reopened = GoogleDriveAccounts(registryURL: registry, client: try client(), credentials: keychain.store,
                                              transport: transport, synchronizeDirectory: { try sync.synchronize($0) })
            let listed = try await reopened.list()
            XCTAssertEqual(listed, active)
            let stillRetained = await keychain.snapshot()
            XCTAssertNotNil(stillRetained[previous.account.credentialID])
            sync.allow()
            let cleaned = try await reopened.list()
            XCTAssertEqual(cleaned, active)
            let remaining = await keychain.snapshot()
            XCTAssertNil(remaining[previous.account.credentialID])
            XCTAssertEqual(Set(remaining.keys), Set(active.map(\.credentialID)))
        }
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
        let active = try await accounts.list()
        XCTAssertTrue(active.isEmpty)
        let pending = try await accounts.hasPendingCleanup()
        XCTAssertFalse(pending)
        let secrets = await keychain.snapshot()
        XCTAssertTrue(secrets.isEmpty)
    }

    func testFailedStagedCredentialRollbackRemainsTrackedForCleanupAfterRestart() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = DriveCredentialFixture()
        let registry = directory.appendingPathComponent("accounts.json")
        let transport = DriveHTTPFixture(outcomes: []).transport
        let accounts = GoogleDriveAccounts(registryURL: registry, client: try client(), credentials: keychain.store,
                                          transport: transport)
        let previous = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens())
        await keychain.failAddAfterWrite(true)
        await keychain.failRemoval(true)
        do {
            _ = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens(refresh: "replacement"))
            XCTFail("Expected failed rollback")
        } catch { XCTAssertEqual(error as? GoogleDriveAccountFailure, .rollbackFailed) }
        let failedCredentials = await keychain.snapshot()
        XCTAssertEqual(failedCredentials.count, 2)
        let pending = try await accounts.hasPendingCleanup()
        XCTAssertTrue(pending, "Failed staged credential removal must remain durably tracked")
        await keychain.failRemoval(false)
        let reopened = GoogleDriveAccounts(registryURL: registry, client: try client(), credentials: keychain.store,
                                          transport: transport)
        let active = try await reopened.list()
        XCTAssertEqual(active, [previous.account])
        let remaining = await keychain.snapshot()
        XCTAssertEqual(Set(remaining.keys), [previous.account.credentialID])
    }

    func testCancelledReconnectPreservesPreviousAccountAndRemovesStagedCredential() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = DriveCredentialFixture()
        let registry = directory.appendingPathComponent("accounts.json")
        let accounts = GoogleDriveAccounts(registryURL: registry, client: try client(), credentials: keychain.store,
                                          transport: DriveHTTPFixture(outcomes: []).transport)
        let previous = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens())
        await keychain.suspendNextAdd()
        let reconnect = Task { try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens(refresh: "replacement")) }
        let deadline = Date().addingTimeInterval(2)
        while !(await keychain.isAddSuspended), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let suspended = await keychain.isAddSuspended
        XCTAssertTrue(suspended)
        let journal = try String(contentsOf: registry, encoding: .utf8)
        let staged = Set((await keychain.snapshot()).keys).subtracting([previous.account.credentialID])
        XCTAssertEqual(staged.count, 1)
        XCTAssertTrue(journal.contains(try XCTUnwrap(staged.first).uuidString))
        let pendingDuringAdd = try await accounts.hasPendingCleanup()
        XCTAssertTrue(pendingDuringAdd)
        reconnect.cancel()
        await keychain.releaseAdd()
        do { _ = try await reconnect.value; XCTFail("Cancelled reconnect committed") }
        catch { XCTAssertTrue(error is CancellationError) }
        let active = try await accounts.list()
        XCTAssertEqual(active, [previous.account])
        let pendingAfterRollback = try await accounts.hasPendingCleanup()
        XCTAssertFalse(pendingAfterRollback)
        let credentials = await keychain.snapshot()
        XCTAssertEqual(Set(credentials.keys), [previous.account.credentialID])
    }

    func testCancellationDuringReconnectCleanupRestoresPreviousAccountAndCredential() async throws {
        for honorsCancellation in [false, true] {
            let directory = try directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let keychain = DriveCredentialFixture()
            let registry = directory.appendingPathComponent("accounts.json")
            let transport = DriveHTTPFixture(outcomes: []).transport
            let accounts = GoogleDriveAccounts(registryURL: registry, client: try client(), credentials: keychain.store,
                                              transport: transport, clock: { 0 })
            let previous = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111", displayName: "Previous"), tokens: tokens())
            let previousCredentials = await keychain.snapshot()
            await keychain.honorCancellation(honorsCancellation)
            await keychain.suspendNextRemoval()
            let reconnect = Task {
                try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111", displayName: "Replacement"), tokens: tokens(refresh: "replacement"))
            }
            let deadline = Date().addingTimeInterval(2)
            while !(await keychain.isRemovalSuspended), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
            let suspended = await keychain.isRemovalSuspended
            XCTAssertTrue(suspended)
            do {
                _ = try await accounts.disconnect(accountID: previous.account.id)
                XCTFail("Reconnect cleanup lost exclusive registry ownership")
            } catch { XCTAssertEqual(error as? GoogleDriveAccountFailure, .busy) }
            reconnect.cancel()
            await keychain.releaseRemoval()
            do { _ = try await reconnect.value; XCTFail("Cancelled reconnect committed") }
            catch { XCTAssertTrue(error is CancellationError) }
            let active = try await accounts.list()
            XCTAssertEqual(active, [previous.account])
            let credentials = await keychain.snapshot()
            XCTAssertEqual(credentials, previousCredentials)
            let pending = try await accounts.hasPendingCleanup()
            XCTAssertFalse(pending)
            let reopened = GoogleDriveAccounts(registryURL: registry, client: try client(), credentials: keychain.store,
                                               transport: transport, clock: { 0 })
            let persisted = try await reopened.list()
            XCTAssertEqual(persisted, [previous.account])
            let cachedToken = try await accounts.accessToken(accountID: previous.account.id)
            XCTAssertEqual(cachedToken, "private-access")
        }
    }

    func testCancelledReconnectRetainsReplacementUntilRollbackRegistryIsDurable() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = DriveCredentialFixture()
        let sync = RegistryDirectorySyncFixture()
        let registry = directory.appendingPathComponent("accounts.json")
        let transport = DriveHTTPFixture(outcomes: []).transport
        let accounts = GoogleDriveAccounts(registryURL: registry, client: try client(), credentials: keychain.store,
                                          transport: transport, synchronizeDirectory: { try sync.synchronize($0) })
        let previous = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens())
        let previousSnapshot = await keychain.snapshot()
        let previousCredential = try XCTUnwrap(previousSnapshot[previous.account.credentialID])
        // Staging, replacement commit, and the old credential's restoration
        // journal are durable. Syncing the restored account registry fails.
        sync.failAfter(successes: 3)
        await keychain.suspendNextRemoval()
        let reconnect = Task { try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens(refresh: "replacement")) }
        let deadline = Date().addingTimeInterval(2)
        while !(await keychain.isRemovalSuspended), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let suspended = await keychain.isRemovalSuspended
        XCTAssertTrue(suspended)
        reconnect.cancel()
        await keychain.releaseRemoval()
        do { _ = try await reconnect.value; XCTFail("Expected deferred rollback cleanup") }
        catch { XCTAssertEqual(error as? GoogleDriveAccountFailure, .rollbackFailed) }
        let retained = await keychain.snapshot()
        XCTAssertEqual(retained.count, 2)
        XCTAssertEqual(retained[previous.account.credentialID], previousCredential)
        let pending = try await accounts.hasPendingCleanup()
        XCTAssertTrue(pending)
        let reopened = GoogleDriveAccounts(registryURL: registry, client: try client(), credentials: keychain.store,
                                           transport: transport, synchronizeDirectory: { try sync.synchronize($0) })
        let active = try await reopened.list()
        XCTAssertEqual(active, [previous.account])
        let stillRetained = await keychain.snapshot()
        XCTAssertEqual(stillRetained, retained)
        sync.allow()
        let cleaned = try await reopened.list()
        XCTAssertEqual(cleaned, [previous.account])
        let remaining = await keychain.snapshot()
        XCTAssertEqual(remaining, [previous.account.credentialID: previousCredential])
    }

    func testFailedPreviousCredentialRestorationKeepsCommittedReplacementTracked() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = DriveCredentialFixture()
        let registry = directory.appendingPathComponent("accounts.json")
        let transport = DriveHTTPFixture(outcomes: []).transport
        let accounts = GoogleDriveAccounts(registryURL: registry, client: try client(), credentials: keychain.store,
                                          transport: transport)
        let previous = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens())
        await keychain.suspendNextRemoval()
        let reconnect = Task { try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens(refresh: "replacement")) }
        let deadline = Date().addingTimeInterval(2)
        while !(await keychain.isRemovalSuspended), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let suspended = await keychain.isRemovalSuspended
        XCTAssertTrue(suspended)
        await keychain.failAddAfterWrite(true)
        reconnect.cancel()
        await keychain.releaseRemoval()
        do { _ = try await reconnect.value; XCTFail("Expected failed credential restoration") }
        catch { XCTAssertEqual(error as? GoogleDriveAccountFailure, .rollbackFailed) }
        let retained = await keychain.snapshot()
        let replacementID = try XCTUnwrap(Set(retained.keys).subtracting([previous.account.credentialID]).first)
        XCTAssertNotNil(retained[previous.account.credentialID])
        let persisted = try String(contentsOf: registry, encoding: .utf8)
        XCTAssertTrue(persisted.contains(replacementID.uuidString))
        let pending = try await accounts.hasPendingCleanup()
        XCTAssertTrue(pending)
        await keychain.failAddAfterWrite(false)
        let reopened = GoogleDriveAccounts(registryURL: registry, client: try client(), credentials: keychain.store,
                                           transport: transport)
        let active = try await reopened.list()
        XCTAssertEqual(active.map(\.credentialID), [replacementID])
        let remaining = await keychain.snapshot()
        XCTAssertEqual(Set(remaining.keys), [replacementID])
    }

    func testReconnectRepairsAnAlreadyMissingCredential() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = DriveCredentialFixture()
        let accounts = GoogleDriveAccounts(registryURL: directory.appendingPathComponent("accounts.json"), client: try client(),
                                          credentials: keychain.store, transport: DriveHTTPFixture(outcomes: []).transport)
        let previous = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens())
        try await keychain.remove(previous.account.credentialID)
        let repaired = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens(refresh: "replacement"))
        XCTAssertEqual(repaired.account.id, previous.account.id)
        let active = try await accounts.list()
        XCTAssertEqual(active, [repaired.account])
        let remaining = await keychain.snapshot()
        XCTAssertEqual(Set(remaining.keys), [repaired.account.credentialID])
    }

    func testCancelledReconnectPreservesAnInFlightRefreshRotation() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = DriveCredentialFixture()
        let snapshotGate = DriveCredentialReadGate()
        let updateGate = DriveCredentialReadGate()
        let base = keychain.store
        let credentials = GoogleDriveCredentialStore(read: { id in
            await snapshotGate.capture(try await base.read(id))
        }, add: base.add, update: { id, data in
            let updated = await updateGate.capture(data)
            try await base.update(id, updated)
        }, remove: base.remove)
        let accounts = GoogleDriveAccounts(registryURL: directory.appendingPathComponent("accounts.json"), client: try client(), credentials: credentials,
                                          transport: DriveHTTPFixture(outcomes: [.reply(200, #"{"access_token":"rotated-access","refresh_token":"rotated-refresh","expires_in":3600,"token_type":"Bearer"}"#)]).transport,
                                          clock: { 3600 })
        let previous = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens())
        await updateGate.arm()
        let refresh = Task { try await accounts.accessToken(accountID: previous.account.id) }
        var deadline = Date().addingTimeInterval(2)
        while !(await updateGate.entered), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let updateEntered = await updateGate.entered
        XCTAssertTrue(updateEntered)
        await snapshotGate.arm()
        await keychain.suspendNextRemoval()
        let reconnect = Task { try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens(refresh: "replacement")) }
        // A broken save captures the old credential before this update returns.
        // A correct save waits for the worker, then captures the rotated value.
        deadline = Date().addingTimeInterval(0.1)
        while !(await snapshotGate.entered), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let beforeRotation = await keychain.snapshot()
        XCTAssertEqual(Set(beforeRotation.keys), [previous.account.credentialID], "Reconnect must not stage credentials while rotation is unfinished")
        await updateGate.release()
        let refreshed = try await refresh.value
        XCTAssertEqual(refreshed, "rotated-access")
        let rotated = await keychain.snapshot()
        let rotatedData = try XCTUnwrap(rotated[previous.account.credentialID])
        XCTAssertTrue(String(decoding: rotatedData, as: UTF8.self).contains("rotated-refresh"))
        deadline = Date().addingTimeInterval(2)
        while !(await snapshotGate.entered), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let snapshotEntered = await snapshotGate.entered
        XCTAssertTrue(snapshotEntered)
        await snapshotGate.release()
        deadline = Date().addingTimeInterval(2)
        while !(await keychain.isRemovalSuspended), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let removalEntered = await keychain.isRemovalSuspended
        XCTAssertTrue(removalEntered)
        reconnect.cancel()
        await keychain.releaseRemoval()
        do { _ = try await reconnect.value; XCTFail("Cancelled reconnect committed") }
        catch { XCTAssertTrue(error is CancellationError) }
        let restored = await keychain.snapshot()
        XCTAssertEqual(restored[previous.account.credentialID], rotatedData)
    }

    func testReconnectDrainsFailedRefreshAndStillRepairsAuthorization() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = DriveCredentialFixture()
        let http = DriveSuspendedHTTPFixture(reply: GoogleDriveHTTPReply(statusCode: 403, body: Data()))
        let accounts = GoogleDriveAccounts(registryURL: directory.appendingPathComponent("accounts.json"), client: try client(),
                                          credentials: keychain.store, transport: http.transport, clock: { 3600 })
        let previous = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens())
        let refresh = Task { try await accounts.accessToken(accountID: previous.account.id) }
        let deadline = Date().addingTimeInterval(2)
        while await http.count == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let count = await http.count
        XCTAssertEqual(count, 1)
        let reconnect = Task { try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111"), tokens: tokens(refresh: "replacement", age: 3600)) }
        for _ in 0..<100 { await Task.yield() }
        await http.release()
        do { _ = try await refresh.value; XCTFail("Expired authorization unexpectedly refreshed") }
        catch { XCTAssertEqual(error as? GoogleDriveTransportFailure, .accessDenied) }
        let repaired = try await reconnect.value
        XCTAssertEqual(repaired.account.id, previous.account.id)
        let active = try await accounts.list()
        XCTAssertEqual(active, [repaired.account])
        let remaining = await keychain.snapshot()
        XCTAssertEqual(Set(remaining.keys), [repaired.account.credentialID])
    }

    func testLocalDrivePathTraversesVerifiedParentsThroughTheRealRequestPolicy() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = #"{"id":"root-id","name":"My Drive","mimeType":"application/vnd.google-apps.folder","trashed":false}"#
        let child = #"{"files":[{"id":"backup-id","name":"Backups","mimeType":"application/vnd.google-apps.folder","parents":["root-id"],"trashed":false}],"incompleteSearch":false}"#
        let nested = #"{"files":[{"id":"vault-id","name":"Vaults","mimeType":"application/vnd.google-apps.folder","parents":["backup-id"],"trashed":false}],"incompleteSearch":false}"#
        let http = DriveHTTPFixture(outcomes: [.reply(200, root), .reply(200, child), .reply(200, nested)])
        let accounts = GoogleDriveAccounts(registryURL: directory.appendingPathComponent("accounts.json"), client: try client(),
                                          credentials: DriveCredentialFixture().store, transport: http.transport, clock: { 0 })
        let saved = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111", emailAddress: "fixture@example.invalid"), tokens: tokens())
        let path = try XCTUnwrap(GoogleDriveLocalPath(directory: URL(fileURLWithPath:
            "/Users/test/Library/CloudStorage/GoogleDrive-fixture@example.invalid/My Drive/Backups/Vaults")))
        let folder = try await accounts.folder(accountID: saved.account.id, path: path)
        XCTAssertEqual(folder.id, "vault-id")
        let snapshot = await http.snapshot()
        XCTAssertEqual(snapshot.requests.count, 3)
        let queries = snapshot.requests.compactMap { request in
            request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value }
        }
        XCTAssertEqual(queries, [
            "'root-id' in parents and name = 'Backups' and mimeType = 'application/vnd.google-apps.folder' and trashed = false",
            "'backup-id' in parents and name = 'Vaults' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"])
        XCTAssertTrue(snapshot.requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
    }

    func testLocalPathAccountMismatchCannotSendAnyMetadataRequest() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let http = DriveHTTPFixture(outcomes: [])
        let accounts = GoogleDriveAccounts(registryURL: directory.appendingPathComponent("accounts.json"), client: try client(),
                                          credentials: DriveCredentialFixture().store, transport: http.transport, clock: { 0 })
        let saved = try await accounts.save(identity: GoogleDriveIdentity(drivePermissionID: "111", emailAddress: "first@example.invalid"), tokens: tokens())
        let path = try XCTUnwrap(GoogleDriveLocalPath(directory: URL(fileURLWithPath:
            "/Users/test/Library/CloudStorage/GoogleDrive-second@example.invalid/My Drive")))
        do { _ = try await accounts.folder(accountID: saved.account.id, path: path); XCTFail("Mismatched account was accepted") }
        catch { XCTAssertEqual(error as? GoogleDriveAccountFailure, .invalidIdentity) }
        let snapshot = await http.snapshot()
        XCTAssertTrue(snapshot.requests.isEmpty)
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

    func testCancelledRefreshWaiterCannotCancelAnotherWaiter() async throws {
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
        for _ in 0..<100 { await Task.yield() }
        first.cancel()
        for _ in 0..<100 { await Task.yield() }
        await http.release()
        do { _ = try await first.value; XCTFail("Cancelled waiter returned an access token") }
        catch { XCTAssertTrue(error is CancellationError) }
        do {
            let token = try await second.value
            XCTAssertEqual(token, "renewed-access")
        } catch { XCTFail("The unrelated waiter failed: \(error)") }
        let requests = await http.count
        XCTAssertEqual(requests, 1)
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
    private let reply: GoogleDriveHTTPReply
    init(reply: GoogleDriveHTTPReply = GoogleDriveHTTPReply(statusCode: 200, body: Data(#"{"access_token":"renewed-access","expires_in":3600,"token_type":"Bearer"}"#.utf8))) {
        self.reply = reply
    }
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
        return reply
    }
}

actor DriveCredentialFixture {
    private var values: [UUID: Data] = [:]
    private var honorsCancellation = false
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
        if honorsCancellation { try Task.checkCancellation() }
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
        if honorsCancellation { try Task.checkCancellation() }
        if removalFails { throw GoogleDriveAccountFailure.credentialsUnavailable }
        values.removeValue(forKey: id)
    }
    func honorCancellation(_ honor: Bool) { honorsCancellation = honor }
    func failRemoval(_ fail: Bool) { removalFails = fail }
    func failAddAfterWrite(_ fail: Bool) { addAfterWriteFails = fail }
    func suspendNextAdd() { shouldSuspendAdd = true }
    func releaseAdd() { addContinuation?.resume(); addContinuation = nil }
    func suspendNextRemoval() { shouldSuspendRemoval = true }
    func releaseRemoval() { removalContinuation?.resume(); removalContinuation = nil }
    func snapshot() -> [UUID: Data] { values }
}

private final class RegistryDirectorySyncFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var successesRemaining: Int?
    func failAfter(successes: Int) { lock.withLock { successesRemaining = successes } }
    func allow() { lock.withLock { successesRemaining = nil } }
    func synchronize(_ directory: URL) throws {
        try lock.withLock {
            guard let remaining = successesRemaining else { return }
            guard remaining > 0 else { throw GoogleDriveAccountFailure.registryUnavailable }
            successesRemaining = remaining - 1
        }
    }
}

private actor DriveCredentialReadGate {
    private var armed = false
    private var continuation: CheckedContinuation<Void, Never>?
    var entered: Bool { continuation != nil }
    func arm() { armed = true }
    func capture(_ data: Data) async -> Data {
        if armed {
            armed = false
            await withCheckedContinuation { continuation = $0 }
        }
        return data
    }
    func release() { continuation?.resume(); continuation = nil }
}
