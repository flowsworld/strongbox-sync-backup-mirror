import Foundation
import Testing
import SyncCopiesCore

private let abcSHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
private let abcMD5 = "900150983cd24fb0d6963f7d28e17f72"
private let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
private let emptyMD5 = "d41d8cd98f00b204e9800998ecf8427e"

struct UploadVerificationTests {
    private let context: UploadVerificationContext
    private let local: UploadLocalFingerprint
    private let matchingFile: UploadRemoteFile

    init() throws {
        context = try UploadVerificationContext(providerID: "google-drive", accountID: "account-1",
                                                folderID: "folder-1", filename: "database.kdbx", destinationID: "target-1")
        local = try UploadLocalFingerprint(size: 3, sha256: abcSHA256, md5: abcMD5)
        matchingFile = try UploadRemoteFile(id: "file-1", size: 3, sha256: abcSHA256, md5: abcMD5)
    }

    @Test func confirmsBothSizeAndThePreferredChecksum() throws {
        let confirmed = UploadVerification.evaluate(context: context, local: local, outcome: .file(matchingFile), now: 100)
        #expect(confirmed.status == .confirmed)
        #expect(confirmed.lastConfirmedAt == 100)
        #expect(confirmed.pendingSeconds == 0)
        #expect(confirmed.previousMismatchAt == nil)

        let wrongSize = try UploadRemoteFile(id: "file-1", size: 4, sha256: abcSHA256)
        #expect(UploadVerification.evaluate(context: context, local: local, outcome: .file(wrongSize), now: 100).status == .pending)
        let conflicting = try UploadRemoteFile(id: "file-1", size: 3, sha256: emptySHA256, md5: abcMD5)
        #expect(UploadVerification.evaluate(context: context, local: local, outcome: .file(conflicting), now: 100).status == .pending)
        let fallback = try UploadRemoteFile(id: "file-1", size: 3, md5: abcMD5.uppercased())
        #expect(UploadVerification.evaluate(context: context, local: local, outcome: .file(fallback), now: 100).status == .confirmed)
    }

    @Test func missingSupportedChecksumIsAnErrorEvenForDifferentSize() throws {
        for size: Int64 in [3, 4] {
            let remote = try UploadRemoteFile(id: "file-1", size: size)
            let state = UploadVerification.evaluate(context: context, local: local, outcome: .file(remote), now: 100)
            #expect(state.status == .error(.unsupportedChecksum))
            #expect(state.previousMismatchAt == nil)
        }
    }

    @Test func missingFileBecomesOverdueAndThenRecovers() {
        let pending = UploadVerification.evaluate(context: context, local: local, outcome: .missing, now: 100)
        #expect(pending.status == .pending)
        #expect(pending.pendingSeconds == 0)
        let stillPending = UploadVerification.evaluate(previous: pending, context: context, local: local, outcome: .missing, now: 1000)
        #expect(stillPending.status == .pending)
        #expect(stillPending.pendingSeconds == 900)
        let overdue = UploadVerification.evaluate(previous: stillPending, context: context, local: local, outcome: .missing, now: 1900)
        #expect(overdue.status == .overdue)
        #expect(overdue.pendingSeconds == 1800)
        let confirmed = UploadVerification.evaluate(previous: overdue, context: context, local: local, outcome: .file(matchingFile), now: 2800)
        #expect(confirmed.status == .confirmed)
        #expect(confirmed.pendingSeconds == 0)
        #expect(confirmed.lastConfirmedAt == 2800)
    }

    @Test func onlySuccessfulMismatchIntervalsCountIncludingShortChecks() {
        let first = UploadVerification.evaluate(context: context, local: local, outcome: .missing, now: 100)
        let short = UploadVerification.evaluate(previous: first, context: context, local: local, outcome: .missing, now: 160)
        #expect(short.pendingSeconds == 60)
        let afterSleep = UploadVerification.evaluate(previous: short, context: context, local: local, outcome: .missing, now: 100_000)
        #expect(afterSleep.pendingSeconds == 960)
        let backward = UploadVerification.evaluate(previous: afterSleep, context: context, local: local, outcome: .missing, now: 99_999)
        #expect(backward.pendingSeconds == 960)
    }

    @Test func failuresPauseWaitingAndTheNextSuccessStartsANewInterval() {
        let first = UploadVerification.evaluate(context: context, local: local, outcome: .missing, now: 100)
        let waiting = UploadVerification.evaluate(previous: first, context: context, local: local, outcome: .missing, now: 1000)
        let error = UploadVerification.evaluate(previous: waiting, context: context, local: local, outcome: .failure(.providerUnavailable), now: 1900)
        #expect(error.status == .error(.providerUnavailable))
        #expect(error.pendingSeconds == 900)
        #expect(error.previousMismatchAt == nil)
        let recovery = UploadVerification.evaluate(previous: error, context: context, local: local, outcome: .missing, now: 100_000)
        #expect(recovery.status == .pending)
        #expect(recovery.pendingSeconds == 900)
        let overdue = UploadVerification.evaluate(previous: recovery, context: context, local: local, outcome: .missing, now: 100_900)
        #expect(overdue.status == .overdue)
    }

    @Test func failedCurrentCheckRetainsHistoryWithoutClaimingConfirmation() {
        let confirmed = UploadVerification.evaluate(context: context, local: local, outcome: .file(matchingFile), now: 100)
        let error = UploadVerification.evaluate(previous: confirmed, context: context, local: local, outcome: .failure(.accessDenied), now: 200)
        #expect(error.status == .error(.accessDenied))
        #expect(error.checkedAt == 200)
        #expect(error.lastConfirmedAt == 100)
        #expect(error.remoteFileID == nil)
        let matchingAgain = UploadVerification.evaluate(previous: error, context: context, local: local, outcome: .file(matchingFile), now: 300)
        #expect(matchingAgain.status == .confirmed)
        #expect(matchingAgain.lastConfirmedAt == 300)
    }

    @Test func failuresBeforeIdentificationPreserveWaitAndHistory() {
        let confirmed = UploadVerification.evaluate(context: context, local: local, outcome: .file(matchingFile), now: 100)
        let firstMismatch = UploadVerification.evaluate(previous: confirmed, context: context, local: local, outcome: .missing, now: 200)
        let waiting = UploadVerification.evaluate(previous: firstMismatch, context: context, local: local, outcome: .missing, now: 1100)
        let unreadable = UploadVerification.evaluate(previous: waiting, context: nil, local: nil, outcome: .failure(.localFileUnavailable), now: 2000)
        #expect(unreadable.status == .error(.localFileUnavailable))
        #expect(unreadable.context == context)
        #expect(unreadable.localSHA256 == abcSHA256)
        #expect(unreadable.pendingSeconds == 900)
        #expect(unreadable.lastConfirmedAt == 100)
        #expect(unreadable.previousMismatchAt == nil)
    }

    @Test func changingContentResetsWaitingAndConfirmationEvenDuringFailure() throws {
        let confirmed = UploadVerification.evaluate(context: context, local: local, outcome: .file(matchingFile), now: 100)
        let changed = try UploadLocalFingerprint(size: 0, sha256: emptySHA256, md5: emptyMD5)
        let error = UploadVerification.evaluate(previous: confirmed, context: context, local: changed, outcome: .failure(.providerUnavailable), now: 200)
        #expect(error.localSHA256 == emptySHA256)
        #expect(error.lastConfirmedAt == nil)
        #expect(error.pendingSeconds == 0)
        let first = UploadVerification.evaluate(context: context, local: local, outcome: .missing, now: 100)
        let waiting = UploadVerification.evaluate(previous: first, context: context, local: local, outcome: .missing, now: 1000)
        let reset = UploadVerification.evaluate(previous: waiting, context: context, local: changed, outcome: .missing, now: 1900)
        #expect(reset.pendingSeconds == 0)
        #expect(reset.status == .pending)
    }

    @Test func allContextChangesResetContentHistory() throws {
        let confirmed = UploadVerification.evaluate(context: context, local: local, outcome: .file(matchingFile), now: 100)
        let first = UploadVerification.evaluate(previous: confirmed, context: context, local: local, outcome: .missing, now: 200)
        let waiting = UploadVerification.evaluate(previous: first, context: context, local: local, outcome: .missing, now: 1100)
        let contexts = try [
            UploadVerificationContext(providerID: "other", accountID: "account-1", folderID: "folder-1", filename: "database.kdbx", destinationID: "target-1"),
            UploadVerificationContext(providerID: "google-drive", accountID: "account-2", folderID: "folder-1", filename: "database.kdbx", destinationID: "target-1"),
            UploadVerificationContext(providerID: "google-drive", accountID: "account-1", folderID: "folder-2", filename: "database.kdbx", destinationID: "target-1"),
            UploadVerificationContext(providerID: "google-drive", accountID: "account-1", folderID: "folder-1", filename: "other.kdbx", destinationID: "target-1"),
            UploadVerificationContext(providerID: "google-drive", accountID: "account-1", folderID: "folder-1", filename: "database.kdbx", destinationID: "target-2")
        ]
        for changed in contexts {
            let reset = UploadVerification.evaluate(previous: waiting, context: changed, local: local, outcome: .missing, now: 2000)
            #expect(reset.status == .pending)
            #expect(reset.pendingSeconds == 0)
            #expect(reset.lastConfirmedAt == nil)
            let beforeHashing = UploadVerification.evaluate(previous: waiting, context: changed, local: nil, outcome: .failure(.localFileUnavailable), now: 2000)
            #expect(beforeHashing.pendingSeconds == 0)
            #expect(beforeHashing.lastConfirmedAt == nil)
        }
    }

    @Test func recreatedFileIDAndRepeatedConfirmationDoNotChangeContentIdentity() throws {
        let first = UploadVerification.evaluate(context: context, local: local, outcome: .file(matchingFile), now: 100)
        let recreated = try UploadRemoteFile(id: "file-recreated", size: 3, sha256: abcSHA256)
        let next = UploadVerification.evaluate(previous: first, context: context, local: local, outcome: .file(recreated), now: 1000)
        #expect(next.status == .confirmed)
        #expect(next.context == first.context)
        #expect(next.localSHA256 == first.localSHA256)
        #expect(next.remoteFileID == "file-recreated")
        #expect(next.lastConfirmedAt == 1000)
        #expect(next.previousMismatchAt == nil)
    }

    @Test func stateSurvivesRestartWithoutCountingAnUnboundedOfflineGap() throws {
        let pending = UploadVerification.evaluate(context: context, local: local, outcome: .missing, now: 100)
        let saved = try JSONEncoder().encode(pending)
        let restored = try JSONDecoder().decode(UploadVerificationState.self, from: saved)
        #expect(restored == pending)
        let next = UploadVerification.evaluate(previous: restored, context: context, local: local, outcome: .missing, now: 1_000_000)
        #expect(next.pendingSeconds == 900)
        let error = UploadVerification.evaluate(previous: next, context: nil, local: nil, outcome: .failure(.credentialsUnavailable), now: 1_000_001)
        let restoredError = try JSONDecoder().decode(UploadVerificationState.self, from: JSONEncoder().encode(error))
        #expect(restoredError == error)
        let recovery = UploadVerification.evaluate(previous: restoredError, context: context, local: local, outcome: .missing, now: 2_000_000)
        #expect(recovery.pendingSeconds == 900)
    }

    @Test func corruptStateIsRejectedAndResetStartsWithoutWaiting() throws {
        let confirmed = UploadVerification.evaluate(context: context, local: local, outcome: .file(matchingFile), now: 100)
        let data = try JSONEncoder().encode(confirmed)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["pendingSeconds"] = 500
        let invalid = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: UploadVerificationFailure.invalidSavedState) {
            try JSONDecoder().decode(UploadVerificationState.self, from: invalid)
        }
        let reset = UploadVerification.evaluate(context: nil, local: nil, outcome: .failure(.invalidSavedState), now: 200)
        #expect(reset.status == .error(.invalidSavedState))
        #expect(reset.pendingSeconds == 0)
        #expect(reset.lastConfirmedAt == nil)
        let next = UploadVerification.evaluate(previous: reset, context: context, local: local, outcome: .missing, now: 1100)
        #expect(next.pendingSeconds == 0)
    }

    @Test func decodedContextsAndUnknownStatusesCannotBypassValidation() throws {
        let state = UploadVerification.evaluate(context: context, local: local, outcome: .missing, now: 100)
        let data = try JSONEncoder().encode(state)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var invalidContext = try #require(object["context"] as? [String: Any])
        invalidContext["accountID"] = ""
        object["context"] = invalidContext
        let invalid = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: UploadVerificationFailure.invalidConfiguration) {
            try JSONDecoder().decode(UploadVerificationState.self, from: invalid)
        }
        object["context"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(context))
        object["status"] = ["futureStatus": [:] as [String: String]]
        let unknownStatus = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(UploadVerificationState.self, from: unknownStatus)
        }
    }

    @Test func invalidValuesFailAtThePublicBoundary() throws {
        #expect(throws: UploadVerificationFailure.invalidConfiguration) {
            try UploadVerificationContext(providerID: "google-drive", accountID: "", folderID: "folder-1", filename: "database.kdbx", destinationID: "target-1")
        }
        #expect(throws: UploadVerificationFailure.invalidLocalFingerprint) {
            try UploadLocalFingerprint(size: -1, sha256: abcSHA256, md5: abcMD5)
        }
        #expect(throws: UploadVerificationFailure.invalidRemoteMetadata) {
            try UploadRemoteFile(id: "file-1", size: 3, sha256: abcSHA256, md5: "bad")
        }
        #expect(throws: UploadVerificationFailure.invalidLocalFingerprint) {
            try UploadLocalFingerprint(size: 3, sha256: String(repeating: "g", count: 64), md5: abcMD5)
        }
        let uppercased = try UploadLocalFingerprint(size: 3, sha256: abcSHA256.uppercased(), md5: abcMD5.uppercased())
        #expect(uppercased == local)
        #expect(UploadVerification.evaluate(context: context, local: local, outcome: .missing, now: 100, warningSeconds: 0).status == .error(.invalidConfiguration))
        #expect(UploadVerification.evaluate(context: nil, local: local, outcome: .file(matchingFile), now: 100).status == .error(.invalidConfiguration))
    }

    @Test func waitingArithmeticRemainsBoundedAtTimestampLimits() throws {
        let first = UploadVerification.evaluate(context: context, local: local, outcome: .missing, now: 0)
        let next = UploadVerification.evaluate(previous: first, context: context, local: local, outcome: .missing, now: UInt64.max, warningSeconds: 1)
        #expect(next.status == .overdue)
        #expect(next.pendingSeconds == 900)
        let sameTime = UploadVerification.evaluate(previous: next, context: context, local: local, outcome: .missing, now: UInt64.max, warningSeconds: 1)
        #expect(sameTime.pendingSeconds == 900)

        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
        object["pendingSeconds"] = UInt64.max - 1
        let restored = try JSONDecoder().decode(UploadVerificationState.self, from: JSONSerialization.data(withJSONObject: object))
        let saturated = UploadVerification.evaluate(previous: restored, context: context, local: local, outcome: .missing, now: 900)
        #expect(saturated.pendingSeconds == UInt64.max)
        #expect(saturated.status == .overdue)
    }
}
