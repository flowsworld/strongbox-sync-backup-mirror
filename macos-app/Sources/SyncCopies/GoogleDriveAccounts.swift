import Darwin
import Foundation
import LocalAuthentication
import Security
import SyncCopiesCore

enum GoogleDriveAccountFailure: Error, Equatable, Sendable {
    case invalidIdentity, invalidRegistry, registryUnavailable, credentialsMissing, credentialsUnavailable
    case credentialsDenied, credentialsInvalid, missingEntitlement, accountMissing, accountChanged, busy, rollbackFailed
}

/// Drive's permission ID is an account identifier. It is not an OpenID Connect subject claim.
struct GoogleDriveIdentity: Equatable, Sendable {
    let drivePermissionID: String
    let emailAddress: String?
    let displayName: String?

    init(drivePermissionID: String, emailAddress: String? = nil, displayName: String? = nil) throws {
        guard !drivePermissionID.isEmpty, drivePermissionID.utf8.count <= 256,
              drivePermissionID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              emailAddress.map({ validAccountLabel($0) && $0.contains("@") }) ?? true,
              displayName.map(validAccountLabel) ?? true else { throw GoogleDriveAccountFailure.invalidIdentity }
        self.drivePermissionID = drivePermissionID
        self.emailAddress = emailAddress
        self.displayName = displayName
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1_048_576 else { throw GoogleDriveAccountFailure.invalidIdentity }
        let response: IdentityResponse
        do { response = try JSONDecoder().decode(IdentityResponse.self, from: data) }
        catch { throw GoogleDriveAccountFailure.invalidIdentity }
        guard response.user.me else { throw GoogleDriveAccountFailure.invalidIdentity }
        return try Self(drivePermissionID: response.user.permissionId, emailAddress: response.user.emailAddress,
                        displayName: response.user.displayName)
    }

    private struct IdentityResponse: Decodable {
        let user: User
        struct User: Decodable {
            let permissionId: String
            let emailAddress: String?
            let displayName: String?
            let me: Bool
            private enum CodingKeys: String, CodingKey { case permissionId, emailAddress, displayName, me }
            init(from decoder: any Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                permissionId = try values.decode(String.self, forKey: .permissionId)
                me = try values.decode(Bool.self, forKey: .me)
                emailAddress = values.contains(.emailAddress) ? try values.decode(String.self, forKey: .emailAddress) : nil
                displayName = values.contains(.displayName) ? try values.decode(String.self, forKey: .displayName) : nil
            }
        }
    }
}

/// Settings contain labels and a random Keychain reference, never tokens or client secrets.
struct GoogleDriveAccount: Codable, Equatable, Identifiable, Sendable {
    let drivePermissionID: String
    let emailAddress: String?
    let displayName: String?
    let credentialID: UUID
    var id: String { "google-drive:" + drivePermissionID }
    var label: String { emailAddress ?? displayName ?? "Google Drive" }

    init(identity: GoogleDriveIdentity, credentialID: UUID) {
        drivePermissionID = identity.drivePermissionID
        emailAddress = identity.emailAddress
        displayName = identity.displayName
        self.credentialID = credentialID
    }

    private enum CodingKeys: String, CodingKey { case drivePermissionID, emailAddress, displayName, credentialID }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let identity = try GoogleDriveIdentity(drivePermissionID: values.decode(String.self, forKey: .drivePermissionID),
                                             emailAddress: values.decodeIfPresent(String.self, forKey: .emailAddress),
                                             displayName: values.decodeIfPresent(String.self, forKey: .displayName))
        self.init(identity: identity, credentialID: try values.decode(UUID.self, forKey: .credentialID))
    }
}

struct GoogleDriveCredentialStore: Sendable {
    let read: @Sendable (UUID) async throws -> Data
    let add: @Sendable (UUID, Data) async throws -> Void
    let update: @Sendable (UUID, Data) async throws -> Void
    let remove: @Sendable (UUID) async throws -> Void

    static func live() -> Self {
        let keychain = GoogleDriveKeychain()
        return Self(read: { try await keychain.read($0) }, add: { try await keychain.add($0, data: $1) },
                    update: { try await keychain.update($0, data: $1) },
                    remove: { try await keychain.remove($0) })
    }
}

/// SecItem calls run on this actor, away from the UI actor. Only this app's new service is queried.
private actor GoogleDriveKeychain {
    private let service = "cloud.diesis.sync-copies.google-drive.native"

    func read(_ id: UUID) throws -> Data {
        var query = attributes(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        try check(status)
        guard let data = item as? Data, !data.isEmpty, data.count <= 65_536 else { throw GoogleDriveAccountFailure.credentialsInvalid }
        return data
    }

    func add(_ id: UUID, data: Data) throws {
        guard !data.isEmpty, data.count <= 65_536 else { throw GoogleDriveAccountFailure.credentialsInvalid }
        var query = attributes(id)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        try check(SecItemAdd(query as CFDictionary, nil))
        guard try read(id) == data else { throw GoogleDriveAccountFailure.credentialsInvalid }
    }

    func remove(_ id: UUID) throws {
        let status = SecItemDelete(attributes(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    func update(_ id: UUID, data: Data) throws {
        guard !data.isEmpty, data.count <= 65_536 else { throw GoogleDriveAccountFailure.credentialsInvalid }
        try check(SecItemUpdate(attributes(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary))
        guard try read(id) == data else { throw GoogleDriveAccountFailure.credentialsInvalid }
    }

    private func attributes(_ id: UUID) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString, kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false, kSecUseAuthenticationContext as String: context]
    }

    private func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound: throw GoogleDriveAccountFailure.credentialsMissing
        case errSecInteractionNotAllowed, errSecNotAvailable: throw GoogleDriveAccountFailure.credentialsUnavailable
        case errSecAuthFailed, errSecUserCanceled: throw GoogleDriveAccountFailure.credentialsDenied
        case errSecMissingEntitlement: throw GoogleDriveAccountFailure.missingEntitlement
        default: throw GoogleDriveAccountFailure.credentialsInvalid
        }
    }
}

struct GoogleDriveAccountSave: Sendable {
    let account: GoogleDriveAccount
    let cleanupPending: Bool
}

enum GoogleDriveGrantRevocation: Sendable { case notRequested, confirmed, failed }

struct GoogleDriveAccountDisconnect: Sendable {
    let cleanupPending: Bool
    let revocation: GoogleDriveGrantRevocation
}

actor GoogleDriveAccounts {
    private let registryURL: URL
    private let client: GoogleDriveOAuthClient
    private let credentials: GoogleDriveCredentialStore
    private let transport: GoogleDriveTransport
    private let clock: @Sendable () -> TimeInterval
    private let synchronizeDirectory: (@Sendable (URL) throws -> Void)?
    private var mutationActive = false
    private var cachedTokens: [String: GoogleDriveOAuthTokens] = [:]
    private struct Refresh {
        let id: UUID
        let task: Task<GoogleDriveOAuthTokens, any Error>
        var waiters: Int
    }
    private var refreshes: [UUID: Refresh] = [:]

    init(registryURL: URL, client: GoogleDriveOAuthClient, credentials: GoogleDriveCredentialStore,
         transport: GoogleDriveTransport, clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
         synchronizeDirectory: (@Sendable (URL) throws -> Void)? = nil) {
        self.registryURL = registryURL
        self.client = client
        self.credentials = credentials
        self.transport = transport
        self.clock = clock
        self.synchronizeDirectory = synchronizeDirectory
    }

    /// Listing retries deferred removal after Keychain access becomes available.
    /// A suspended owned mutation keeps exclusive ownership of registry cleanup.
    func list() async throws -> [GoogleDriveAccount] {
        try Task.checkCancellation()
        var registry = try loadRegistry()
        guard !mutationActive, !registry.pendingRemovals.isEmpty else { return registry.accounts }
        mutationActive = true
        defer { mutationActive = false }
        _ = await cleanup(&registry)
        return registry.accounts
    }

    func hasPendingCleanup() throws -> Bool { try !loadRegistry().pendingRemovals.isEmpty }

    /// Journal new credential IDs before staging secrets. Reconnecting preserves the stable account ID.
    func save(identity: GoogleDriveIdentity, tokens: GoogleDriveOAuthTokens) async throws -> GoogleDriveAccountSave {
        try Task.checkCancellation()
        guard !mutationActive else { throw GoogleDriveAccountFailure.busy }
        mutationActive = true
        defer { mutationActive = false }
        var registry = try loadRegistry()
        let original = registry
        let previous = registry.accounts.first { $0.drivePermissionID == identity.drivePermissionID }
        if let previous, let refresh = refreshes[previous.credentialID] {
            // The worker owns token rotation through its final Keychain write.
            // Drain it before capturing rollback state. Its existing waiters
            // report failures; a fresh authorization can still repair the account.
            _ = await refresh.task.result
            try Task.checkCancellation()
        }
        let account = GoogleDriveAccount(identity: identity, credentialID: UUID())
        let payload = StoredCredentials(clientID: client.clientID, drivePermissionID: identity.drivePermissionID, refreshToken: tokens.refreshToken)
        registry.pendingRemovals.append(account.credentialID)
        try saveRegistry(registry)
        // Persist the journal's rename before a secret can exist outside the registry.
        try syncRegistryDirectory()
        var previousCredential: Data?
        var committed = false
        do {
            try await credentials.add(account.credentialID, JSONEncoder().encode(payload))
            try Task.checkCancellation()
            if let previous {
                do { previousCredential = try await credentials.read(previous.credentialID) }
                catch GoogleDriveAccountFailure.credentialsMissing { /* Reconnect can repair an already missing credential. */ }
            }
            try Task.checkCancellation()
            var updated = registry
            updated.accounts.removeAll { $0.id == account.id }
            updated.accounts.append(account)
            updated.pendingRemovals.removeAll { $0 == account.credentialID }
            if let previous { updated.pendingRemovals.append(previous.credentialID) }
            try saveRegistry(updated)
            registry = updated
            committed = true
            if let previous { refreshes.removeValue(forKey: previous.credentialID)?.task.cancel() }
            let cleanupPending = await cleanup(&registry)
            try Task.checkCancellation()
            cachedTokens[account.id] = tokens
            return GoogleDriveAccountSave(account: account, cleanupPending: cleanupPending)
        } catch {
            // Drain rollback in an owned, uncancelled task. The caller may have
            // cancelled while Keychain deletion was already in progress.
            let retainedCredential = committed ? previousCredential : nil
            let rollback = Task {
                try await self.rollbackSave(account: account, previous: previous,
                                            previousCredential: retainedCredential, original: original)
            }
            do { try await rollback.value }
            catch { throw GoogleDriveAccountFailure.rollbackFailed }
            throw error
        }
    }

    private func rollbackSave(account: GoogleDriveAccount, previous: GoogleDriveAccount?,
                              previousCredential: Data?, original: Registry) async throws {
        if let previous, let previousCredential {
            do { _ = try await credentials.read(previous.credentialID) }
            catch GoogleDriveAccountFailure.credentialsMissing {
                // Restoration can itself fail after adding a secret. Journal it
                // before writing so a failed rollback cannot orphan credentials.
                var journal = try loadRegistry()
                if !journal.pendingRemovals.contains(previous.credentialID) {
                    journal.pendingRemovals.append(previous.credentialID)
                    try saveRegistry(journal)
                }
                try syncRegistryDirectory()
                try await credentials.add(previous.credentialID, previousCredential)
            }
        }
        var restored = original
        restored.pendingRemovals.append(account.credentialID)
        try saveRegistry(restored)
        // The restored registry must be durable before deleting the replacement.
        // If restoration fails, the replacement remains active. A failed sync
        // or replacement removal leaves its credential recorded for retry.
        try syncRegistryDirectory()
        try await credentials.remove(account.credentialID)
        restored.pendingRemovals.removeAll { $0 == account.credentialID }
        try saveRegistry(restored)
    }

    /// Local disconnect works offline. Google grant revocation is a separate explicit choice.
    func disconnect(accountID: String, revokeGoogleGrant: Bool = false) async throws -> GoogleDriveAccountDisconnect {
        guard !mutationActive else { throw GoogleDriveAccountFailure.busy }
        mutationActive = true
        defer { mutationActive = false }
        var registry = try loadRegistry()
        guard let account = registry.accounts.first(where: { $0.id == accountID }) else { throw GoogleDriveAccountFailure.accountMissing }
        registry.accounts.removeAll { $0.id == accountID }
        registry.pendingRemovals.append(account.credentialID)
        try saveRegistry(registry)
        cachedTokens.removeValue(forKey: accountID)
        refreshes.removeValue(forKey: account.credentialID)?.task.cancel()
        var revocation = GoogleDriveGrantRevocation.notRequested
        if revokeGoogleGrant {
            do {
                let stored = try await loadCredentials(account)
                _ = try await transport.oauth(client.revocationRequest(token: stored.refreshToken))
                revocation = .confirmed
            } catch {
                // Local disconnect has already committed. Report that the online grant might remain.
                revocation = .failed
            }
        }
        return GoogleDriveAccountDisconnect(cleanupPending: await cleanup(&registry), revocation: revocation)
    }

    func retryCleanup() async throws -> Bool {
        guard !mutationActive else { throw GoogleDriveAccountFailure.busy }
        mutationActive = true
        defer { mutationActive = false }
        var registry = try loadRegistry()
        return await cleanup(&registry)
    }

    func accessToken(accountID: String) async throws -> String {
        let account = try requireAccount(accountID)
        let now = clock()
        guard now.isFinite, now >= 0 else { throw GoogleDriveAccountFailure.credentialsInvalid }
        if let tokens = cachedTokens[accountID], tokens.expiresAt > now + 30 { return tokens.accessToken }
        let refresh: Refresh
        if var existing = refreshes[account.credentialID] {
            existing.waiters += 1
            refreshes[account.credentialID] = existing
            refresh = existing
        } else {
            // Existing workers may finish or gain waiters during a mutation, but
            // a new worker cannot rotate a credential being staged or removed.
            guard !mutationActive else { throw GoogleDriveAccountFailure.busy }
            let client = self.client, transport = self.transport, credentials = self.credentials, clock = self.clock
            let task = Task {
                let data = try await credentials.read(account.credentialID)
                let stored = try StoredCredentials.decode(data, clientID: client.clientID, account: account)
                let response = try await transport.oauth(client.refreshRequest(refreshToken: stored.refreshToken))
                let tokens = try GoogleDriveOAuthTokens.decodeResponse(response, existingRefreshToken: stored.refreshToken, receivedAt: clock())
                return try await self.finishRefresh(account: account, tokens: tokens)
            }
            refresh = Refresh(id: UUID(), task: task, waiters: 1)
            refreshes[account.credentialID] = refresh
        }
        defer {
            if var current = refreshes[account.credentialID], current.id == refresh.id {
                current.waiters -= 1
                if current.waiters == 0 { refreshes.removeValue(forKey: account.credentialID) }
                else { refreshes[account.credentialID] = current }
            }
        }
        // A cancelled waiter drains the bounded shared request before returning
        // cancellation. It cannot cancel another caller's refresh or outlive shutdown.
        let tokens = try await refresh.task.value
        try requireCurrent(account)
        try Task.checkCancellation()
        return tokens.accessToken
    }

    /// One shared worker persists rotation before any waiter or reconnect can
    /// observe completion. Individual waiters never write credentials.
    private func finishRefresh(account: GoogleDriveAccount, tokens: GoogleDriveOAuthTokens) async throws -> GoogleDriveOAuthTokens {
        try Task.checkCancellation()
        try requireCurrent(account)
        let stored = try await loadCredentials(account)
        try requireCurrent(account)
        try Task.checkCancellation()
        if tokens.refreshToken != stored.refreshToken {
            let updated = StoredCredentials(clientID: client.clientID, drivePermissionID: account.drivePermissionID, refreshToken: tokens.refreshToken)
            try await credentials.update(account.credentialID, JSONEncoder().encode(updated))
        }
        try requireCurrent(account)
        try Task.checkCancellation()
        cachedTokens[account.id] = tokens
        return tokens
    }

    /// Traverse exact names from this account's My Drive root. No first-match guesses.
    func folder(accountID: String, path: GoogleDriveLocalPath) async throws -> GoogleDriveFolder {
        let account = try requireAccount(accountID)
        guard account.emailAddress?.caseInsensitiveCompare(path.accountEmail) == .orderedSame else {
            throw GoogleDriveAccountFailure.invalidIdentity
        }
        let token = try await accessToken(accountID: accountID)
        let root = try await transport.metadata(GoogleDriveMetadata.folderRequest(id: "root"), accessToken: token)
        try requireCurrent(account)
        try Task.checkCancellation()
        var folder = try GoogleDriveMetadata.resolveFolder(root, requestedID: "root")
        for name in path.components {
            var search = try GoogleDriveFolderSearch(folder: folder, name: name)
            var found: GoogleDriveFolder?
            while let request = search.request {
                let data = try await transport.metadata(request, accessToken: token)
                try requireCurrent(account)
                try Task.checkCancellation()
                if case .complete(let child) = try search.consume(data) { found = child }
            }
            guard let child = found else { throw GoogleDriveMetadataError.unexpectedFolder }
            folder = child
        }
        return folder
    }

    /// An optional notice about equal-content files elsewhere, never the primary check.
    func otherCopies(accountID: String, folderID: String, filename: String, local: UploadLocalFingerprint) async throws -> Int {
        let account = try requireAccount(accountID)
        let token = try await accessToken(accountID: accountID)
        var search = try GoogleDriveOtherCopiesSearch(filename: filename, excludingFolderID: folderID, local: local)
        while let request = search.request {
            let data = try await transport.metadata(request, accessToken: token)
            try requireCurrent(account)
            try Task.checkCancellation()
            if case .complete(let count) = try search.consume(data) { return count }
        }
        throw GoogleDriveMetadataError.searchFinished
    }

    func remoteFile(accountID: String, folderID: String, filename: String) async throws -> UploadRemoteFile? {
        let account = try requireAccount(accountID)
        let token = try await accessToken(accountID: accountID)
        let folderData = try await transport.metadata(GoogleDriveMetadata.folderRequest(id: folderID), accessToken: token)
        try requireCurrent(account)
        let folder = try GoogleDriveMetadata.resolveFolder(folderData, requestedID: folderID)
        var search = try GoogleDriveFileSearch(folder: folder, filename: filename)
        while let request = search.request {
            let data = try await transport.metadata(request, accessToken: token)
            try requireCurrent(account)
            if case .complete(let file) = try search.consume(data) { return file }
        }
        throw GoogleDriveMetadataError.searchFinished
    }

    private func requireAccount(_ id: String) throws -> GoogleDriveAccount {
        guard let account = try loadRegistry().accounts.first(where: { $0.id == id }) else { throw GoogleDriveAccountFailure.accountMissing }
        return account
    }

    private func requireCurrent(_ account: GoogleDriveAccount) throws {
        guard try loadRegistry().accounts.contains(account) else { throw GoogleDriveAccountFailure.accountChanged }
    }

    private func loadCredentials(_ account: GoogleDriveAccount) async throws -> StoredCredentials {
        try StoredCredentials.decode(try await credentials.read(account.credentialID), clientID: client.clientID, account: account)
    }

    private struct Registry: Codable {
        var accounts: [GoogleDriveAccount] = []
        var pendingRemovals: [UUID] = []
    }

    private struct StoredCredentials: Codable {
        let clientID: String
        let drivePermissionID: String
        let refreshToken: String

        static func decode(_ data: Data, clientID: String, account: GoogleDriveAccount) throws -> Self {
            guard data.count <= 65_536 else { throw GoogleDriveAccountFailure.credentialsInvalid }
            let value: Self
            do { value = try JSONDecoder().decode(Self.self, from: data) }
            catch { throw GoogleDriveAccountFailure.credentialsInvalid }
            guard value.clientID == clientID, value.drivePermissionID == account.drivePermissionID else {
                throw GoogleDriveAccountFailure.credentialsInvalid
            }
            do { _ = try GoogleDriveOAuthClient(clientID: clientID).refreshRequest(refreshToken: value.refreshToken) }
            catch { throw GoogleDriveAccountFailure.credentialsInvalid }
            return value
        }
    }

    private func loadRegistry() throws -> Registry {
        guard registryURL.isFileURL else { throw GoogleDriveAccountFailure.registryUnavailable }
        do {
            let descriptor = open(registryURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if descriptor < 0 {
                if errno == ENOENT { return Registry() }
                throw GoogleDriveAccountFailure.registryUnavailable
            }
            defer { close(descriptor) }
            var stamp = stat()
            guard fstat(descriptor, &stamp) == 0, stamp.st_mode & S_IFMT == S_IFREG,
                  stamp.st_size >= 0, stamp.st_size <= 131_072 else { throw GoogleDriveAccountFailure.invalidRegistry }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw GoogleDriveAccountFailure.registryUnavailable }
                if count == 0 { break }
                guard data.count + count <= 131_072 else { throw GoogleDriveAccountFailure.invalidRegistry }
                data.append(contentsOf: buffer.prefix(count))
            }
            guard data.count <= 131_072 else { throw GoogleDriveAccountFailure.invalidRegistry }
            let registry: Registry
            do { registry = try JSONDecoder().decode(Registry.self, from: data) }
            catch { throw GoogleDriveAccountFailure.invalidRegistry }
            let liveIDs = Set(registry.accounts.map(\.credentialID))
            guard registry.accounts.count <= 100, Set(registry.accounts.map(\.id)).count == registry.accounts.count,
                  liveIDs.count == registry.accounts.count, Set(registry.pendingRemovals).count == registry.pendingRemovals.count,
                  liveIDs.isDisjoint(with: registry.pendingRemovals) else { throw GoogleDriveAccountFailure.invalidRegistry }
            return registry
        } catch let error as GoogleDriveAccountFailure { throw error }
        catch { throw GoogleDriveAccountFailure.invalidRegistry }
    }

    private func saveRegistry(_ registry: Registry) throws {
        do {
            let data = try JSONEncoder().encode(registry)
            guard data.count <= 131_072, registry.accounts.count <= 100 else { throw GoogleDriveAccountFailure.registryUnavailable }
            let directory = registryURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var template = Array(directory.appendingPathComponent(".google-drive-XXXXXX").path.utf8CString)
            let descriptor = mkstemp(&template)
            guard descriptor >= 0 else { throw GoogleDriveAccountFailure.registryUnavailable }
            let temporary = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            defer { close(descriptor); unlink(temporary) }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw GoogleDriveAccountFailure.registryUnavailable }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0, rename(temporary, registryURL.path) == 0 else { throw GoogleDriveAccountFailure.registryUnavailable }
        } catch let error as GoogleDriveAccountFailure { throw error }
        catch { throw GoogleDriveAccountFailure.registryUnavailable }
    }

    private func syncRegistryDirectory() throws {
        if let synchronizeDirectory { try synchronizeDirectory(registryURL.deletingLastPathComponent()); return }
        let descriptor = open(registryURL.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw GoogleDriveAccountFailure.registryUnavailable }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw GoogleDriveAccountFailure.registryUnavailable }
    }

    /// Failed deletion remains recorded by opaque ID for another attempt, without retaining tokens in settings.
    private func cleanup(_ registry: inout Registry) async -> Bool {
        guard !registry.pendingRemovals.isEmpty else { return false }
        // A failed sync leaves the logical commit intact and all credentials
        // available. Retry only after its registry rename is durable.
        do { try syncRegistryDirectory() }
        catch { return true }
        var remaining: [UUID] = []
        for id in registry.pendingRemovals {
            do { try await credentials.remove(id) }
            catch { remaining.append(id) }
        }
        if remaining != registry.pendingRemovals {
            var updated = registry
            updated.pendingRemovals = remaining
            do { try saveRegistry(updated); registry = updated }
            catch { return true }
        }
        return !remaining.isEmpty
    }
}

private func validAccountLabel(_ value: String) -> Bool {
    !value.isEmpty && value.unicodeScalars.count <= 1024 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
}
