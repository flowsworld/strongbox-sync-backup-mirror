import Foundation
import SyncCopiesCore

extension UploadVerificationFailure {
    var messageKey: String {
        switch self {
        case .providerUnavailable: "Google Drive is unreachable. The local copy is unaffected."
        case .accessDenied: "Google Drive access was denied. Check the account and folder permissions."
        case .credentialsUnavailable: "Reconnect the Google Drive account to continue checking."
        case .invalidConfiguration: "Choose a Google Drive account and folder for this database."
        case .invalidLocalFingerprint, .localFileUnavailable: "The local copy is unavailable for cloud verification."
        case .invalidRemoteMetadata: "Google Drive returned ambiguous or invalid file metadata."
        case .localFileChanged: "The local copy changed during verification. It will be checked again."
        case .unsupportedChecksum: "The cloud file has no supported checksum. Its upload cannot be confirmed."
        case .invalidSavedState: "The saved cloud verification could not be restored."
        }
    }
}

extension DriveVerificationEvent {
    var message: LocalizedMessage {
        switch kind {
        case .error: LocalizedMessage(key: problem?.messageKey ?? "Google Drive verification failed.")
        case .overdue: LocalizedMessage(key: "Google Drive upload is overdue.")
        case .recovery: LocalizedMessage(key: confirmed ? "Google Drive verification recovered and the upload is confirmed." : "Google Drive verification recovered. The upload is still pending.")
        case .confirmed: LocalizedMessage(key: "Google Drive upload confirmed.")
        }
    }
}

extension UploadVerificationState {
    var titleKey: String {
        switch status {
        case .confirmed: "Upload confirmed"
        case .pending: "Upload pending"
        case .overdue: "Upload overdue"
        case .error: "Cloud check failed"
        }
    }
}
