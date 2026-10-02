import Foundation

public enum UploadVerificationFailure: String, Error, Codable, Equatable, Sendable {
    case providerUnavailable, accessDenied, credentialsUnavailable, invalidConfiguration
    case invalidLocalFingerprint, invalidRemoteMetadata, localFileUnavailable, localFileChanged
    case unsupportedChecksum, invalidSavedState
}

/// Account and destination identities prevent reusing a result after setup changes.
public struct UploadVerificationContext: Codable, Equatable, Sendable {
    public let providerID: String
    public let accountID: String
    public let folderID: String
    public let filename: String
    public let destinationID: String

    public init(providerID: String, accountID: String, folderID: String, filename: String, destinationID: String) throws {
        guard [providerID, accountID, folderID, filename, destinationID].allSatisfy(validVerificationIdentity),
              validFilename(filename) else { throw UploadVerificationFailure.invalidConfiguration }
        self.providerID = providerID
        self.accountID = accountID
        self.folderID = folderID
        self.filename = filename
        self.destinationID = destinationID
    }

    private enum CodingKeys: String, CodingKey {
        case providerID, accountID, folderID, filename, destinationID
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            providerID: values.decode(String.self, forKey: .providerID),
            accountID: values.decode(String.self, forKey: .accountID),
            folderID: values.decode(String.self, forKey: .folderID),
            filename: values.decode(String.self, forKey: .filename),
            destinationID: values.decode(String.self, forKey: .destinationID)
        )
    }
}

/// Hashes describe a stable read of the current local copy, supplied by an adapter.
public struct UploadLocalFingerprint: Equatable, Sendable {
    public let size: Int64
    public let sha256: String
    public let md5: String

    public init(size: Int64, sha256: String, md5: String) throws {
        guard size >= 0, validVerificationDigest(sha256, length: 64),
              validVerificationDigest(md5, length: 32) else {
            throw UploadVerificationFailure.invalidLocalFingerprint
        }
        self.size = size
        self.sha256 = sha256.lowercased()
        self.md5 = md5.lowercased()
    }
}

/// Providers must finish an unambiguous folder/name search before returning a file.
public struct UploadRemoteFile: Equatable, Sendable {
    public let id: String
    public let size: Int64
    public let sha256: String?
    public let md5: String?

    public init(id: String, size: Int64, sha256: String? = nil, md5: String? = nil) throws {
        guard validVerificationIdentity(id), size >= 0,
              sha256.map({ validVerificationDigest($0, length: 64) }) ?? true,
              md5.map({ validVerificationDigest($0, length: 32) }) ?? true else {
            throw UploadVerificationFailure.invalidRemoteMetadata
        }
        self.id = id
        self.size = size
        self.sha256 = sha256?.lowercased()
        self.md5 = md5?.lowercased()
    }
}

public enum UploadCheckOutcome: Equatable, Sendable {
    case missing
    case file(UploadRemoteFile)
    case failure(UploadVerificationFailure)
}

public enum UploadVerificationStatus: Codable, Equatable, Sendable {
    case confirmed, pending, overdue
    case error(UploadVerificationFailure)
}

/// Current status is authoritative. A historical confirmation never turns an error into success.
public struct UploadVerificationState: Codable, Equatable, Sendable {
    public let status: UploadVerificationStatus
    public let context: UploadVerificationContext?
    public let localSHA256: String?
    public let checkedAt: UInt64
    public let lastConfirmedAt: UInt64?
    public let pendingSeconds: UInt64
    public let previousMismatchAt: UInt64?
    public let remoteFileID: String?

    fileprivate init(status: UploadVerificationStatus, context: UploadVerificationContext?, localSHA256: String?,
                     checkedAt: UInt64, lastConfirmedAt: UInt64?, pendingSeconds: UInt64,
                     previousMismatchAt: UInt64?, remoteFileID: String?) {
        self.status = status
        self.context = context
        self.localSHA256 = localSHA256
        self.checkedAt = checkedAt
        self.lastConfirmedAt = lastConfirmedAt
        self.pendingSeconds = pendingSeconds
        self.previousMismatchAt = previousMismatchAt
        self.remoteFileID = remoteFileID
    }

    private enum CodingKeys: String, CodingKey {
        case status, context, localSHA256, checkedAt, lastConfirmedAt
        case pendingSeconds, previousMismatchAt, remoteFileID
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let status = try values.decode(UploadVerificationStatus.self, forKey: .status)
        let context = try values.decodeIfPresent(UploadVerificationContext.self, forKey: .context)
        let sha256 = try values.decodeIfPresent(String.self, forKey: .localSHA256)
        let checkedAt = try values.decode(UInt64.self, forKey: .checkedAt)
        let confirmedAt = try values.decodeIfPresent(UInt64.self, forKey: .lastConfirmedAt)
        let pending = try values.decode(UInt64.self, forKey: .pendingSeconds)
        let mismatchAt = try values.decodeIfPresent(UInt64.self, forKey: .previousMismatchAt)
        let remoteID = try values.decodeIfPresent(String.self, forKey: .remoteFileID)
        guard sha256.map({ validVerificationDigest($0, length: 64) && $0 == $0.lowercased() }) ?? true,
              remoteID.map(validVerificationIdentity) ?? true else {
            throw UploadVerificationFailure.invalidSavedState
        }
        switch status {
        case .confirmed:
            guard context != nil, sha256 != nil, remoteID != nil, pending == 0,
                  mismatchAt == nil, confirmedAt == checkedAt else {
                throw UploadVerificationFailure.invalidSavedState
            }
        case .pending, .overdue:
            guard context != nil, sha256 != nil, mismatchAt == checkedAt else {
                throw UploadVerificationFailure.invalidSavedState
            }
        case .error:
            guard mismatchAt == nil, remoteID == nil,
                  (pending == 0 && confirmedAt == nil) || (context != nil && sha256 != nil) else {
                throw UploadVerificationFailure.invalidSavedState
            }
        }
        self.init(status: status, context: context, localSHA256: sha256, checkedAt: checkedAt,
                  lastConfirmedAt: confirmedAt, pendingSeconds: pending,
                  previousMismatchAt: mismatchAt, remoteFileID: remoteID)
    }
}

public enum UploadVerification {
    /// Only consecutive successful mismatches add waiting time. Errors pause it.
    /// Timestamps are injected Unix seconds; a long missed interval counts at most 900 seconds.
    public static func evaluate(previous: UploadVerificationState? = nil,
                                context: UploadVerificationContext?, local: UploadLocalFingerprint?,
                                outcome: UploadCheckOutcome, now: UInt64, warningSeconds: UInt64 = 1800) -> UploadVerificationState {
        let identifiedContext = context ?? previous?.context
        let sha256 = local?.sha256 ?? previous?.localSHA256
        let sameContent = previous != nil && previous?.context == identifiedContext && previous?.localSHA256 == sha256
        let confirmedAt = sameContent ? previous?.lastConfirmedAt : nil
        let pending = sameContent ? previous?.pendingSeconds ?? 0 : 0

        func failure(_ reason: UploadVerificationFailure) -> UploadVerificationState {
            UploadVerificationState(status: .error(reason), context: identifiedContext, localSHA256: sha256,
                                    checkedAt: now, lastConfirmedAt: confirmedAt, pendingSeconds: pending,
                                    previousMismatchAt: nil, remoteFileID: nil)
        }

        guard warningSeconds > 0 else { return failure(.invalidConfiguration) }
        if case .failure(let reason) = outcome { return failure(reason) }
        guard let context, let local else { return failure(.invalidConfiguration) }

        var remoteID: String?
        if case .file(let remote) = outcome {
            remoteID = remote.id
            let matchingDigest: Bool
            if let sha256 = remote.sha256 { matchingDigest = sha256 == local.sha256 }
            else if let md5 = remote.md5 { matchingDigest = md5 == local.md5 }
            else { return failure(.unsupportedChecksum) }
            if matchingDigest && remote.size == local.size {
                return UploadVerificationState(status: .confirmed, context: context, localSHA256: local.sha256,
                                               checkedAt: now, lastConfirmedAt: now, pendingSeconds: 0,
                                               previousMismatchAt: nil, remoteFileID: remoteID)
            }
        }

        var waiting = pending
        if sameContent, let mismatchAt = previous?.previousMismatchAt {
            let elapsed = now >= mismatchAt ? min(900, now - mismatchAt) : 0
            let addition = waiting.addingReportingOverflow(elapsed)
            waiting = addition.overflow ? UInt64.max : addition.partialValue
        }
        return UploadVerificationState(status: waiting >= warningSeconds ? .overdue : .pending,
                                       context: context, localSHA256: local.sha256, checkedAt: now,
                                       lastConfirmedAt: confirmedAt, pendingSeconds: waiting,
                                       previousMismatchAt: now, remoteFileID: remoteID)
    }
}

private func validVerificationIdentity(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 16_384 && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
}

private func validVerificationDigest(_ value: String, length: Int) -> Bool {
    value.utf8.count == length && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
    }
}
