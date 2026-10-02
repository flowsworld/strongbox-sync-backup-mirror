import Foundation
import Testing
@testable import SyncCopies

@MainActor
struct AppUpdatesTests {
    @Test func developmentAndPreviewNeverStartExternalUpdateChecks() {
        let development = AppUpdates(demo: false, configuration: AppUpdateConfiguration(info: [:]), prepareForUpdate: { true })
        development.start()
        development.checkNow()
        #expect(!development.canCheckForUpdates)
        #expect(!development.canOpenStore)
        let preview = AppUpdates(demo: true, configuration: AppUpdateConfiguration(info: ["DIESISDistributionChannel": "direct"]), prepareForUpdate: { true })
        preview.start()
        #expect(preview.statusMessage == "Updates are disabled in the preview.")
        #expect(!preview.canCheckForUpdates)
    }

    @Test func directUpdatesRequireBothHTTPSFeedAndCanonicalPublicKey() {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        for feed in ["http://updates.test.invalid/appcast.xml", "https://example.com/appcast.xml",
                     "https://user:password@updates.company.test/appcast.xml", "https://updates.company.test/appcast.xml?identity=private"] {
            let configuration = AppUpdateConfiguration(info: ["DIESISDistributionChannel": "direct", "SUFeedURL": feed, "SUPublicEDKey": key])
            #expect(!configuration.directConfigured)
        }
        let complete = AppUpdateConfiguration(info: ["DIESISDistributionChannel": "direct", "SUFeedURL": "https://updates.company.test/appcast.xml", "SUPublicEDKey": key])
        #expect(complete.directConfigured)
        #expect(!AppUpdateConfiguration(info: ["DIESISDistributionChannel": "direct", "SUFeedURL": "https://updates.company.test/appcast.xml"]).directConfigured)
        #expect(!AppUpdateConfiguration(info: ["DIESISDistributionChannel": "direct", "SUFeedURL": "https://updates.company.test/appcast.xml", "SUPublicEDKey": "not-a-key"]).directConfigured)
    }

    @Test func storeLinkCanOnlyPointAtAppleAndCannotEnableDirectUpdates() {
        let valid = AppUpdateConfiguration(info: ["DIESISDistributionChannel": "store", "DIESISStoreURL": "https://apps.apple.com/app/id123"])
        let updates = AppUpdates(demo: false, configuration: valid, prepareForUpdate: { true })
        updates.start()
        #expect(updates.canOpenStore)
        #expect(!updates.showsDirectControls)
        #expect(!updates.canCheckForUpdates)
        #expect(AppUpdateConfiguration(info: ["DIESISDistributionChannel": "store", "DIESISStoreURL": "https://evil.test/app/id123"]).storeURL == nil)
    }

    @Test func installationWaitsForPreparationAndReleasesOnlyOneContinuation() async {
        var releasePreparation: CheckedContinuation<Bool, Never>?
        var installations = 0
        let updates = AppUpdates(demo: false, prepareForUpdate: {
            await withCheckedContinuation { releasePreparation = $0 }
        })
        updates.postponeInstallation { installations += 1 }
        updates.postponeInstallation { installations += 100 }
        for _ in 0..<1_000 where releasePreparation == nil { await Task.yield() }
        #expect(releasePreparation != nil)
        #expect(installations == 0)
        #expect(updates.isPreparingInstallation)
        #expect(updates.isInstallingUpdate)
        releasePreparation?.resume(returning: true)
        for _ in 0..<1_000 where updates.isPreparingInstallation { await Task.yield() }
        #expect(!updates.isPreparingInstallation)
        #expect(installations == 1)
        #expect(updates.isInstallingUpdate)
    }

    @Test func failedPersistenceBlocksInstallationAndExplicitRetryCanComplete() async {
        let persistence = UpdatePersistenceFixture()
        var installations = 0
        let updates = AppUpdates(demo: false, prepareForUpdate: { persistence.canSave })
        updates.postponeInstallation { installations += 1 }
        for _ in 0..<1_000 where updates.isPreparingInstallation { await Task.yield() }
        #expect(!updates.isPreparingInstallation)
        #expect(updates.installationBlocked)
        #expect(installations == 0)
        #expect(updates.statusMessage == "Update installation is blocked because settings could not be saved.")
        persistence.canSave = true
        updates.checkNow()
        for _ in 0..<1_000 where updates.isPreparingInstallation { await Task.yield() }
        #expect(!updates.isPreparingInstallation)
        #expect(!updates.installationBlocked)
        #expect(installations == 1)
    }
    @Test func cancelledPreparedInstallationResumesTheModel() async {
        var resumptions = 0
        let updates = AppUpdates(demo: false, resumeAfterCancelledUpdate: { resumptions += 1 }, prepareForUpdate: { true })
        updates.postponeInstallation {}
        for _ in 0..<1_000 where updates.isPreparingInstallation { await Task.yield() }
        #expect(!updates.isPreparingInstallation)
        #expect(updates.isInstallingUpdate)
        updates.cancelInstallation()
        updates.cancelInstallation()
        #expect(!updates.isInstallingUpdate)
        #expect(resumptions == 1)
    }

    @Test func cancelledPreparationCannotOverwriteALaterAttempt() async {
        let fixture = UpdatePreparationFixture()
        var oldInstallations = 0
        var newInstallations = 0
        let updates = AppUpdates(demo: false, prepareForUpdate: { await fixture.prepare() })
        updates.postponeInstallation { oldInstallations += 1 }
        for _ in 0..<1_000 where fixture.pending.isEmpty { await Task.yield() }
        #expect(fixture.pending.count == 1)
        updates.cancelInstallation()
        updates.postponeInstallation { newInstallations += 1 }
        for _ in 0..<1_000 where fixture.pending.count < 2 { await Task.yield() }
        #expect(fixture.pending.count == 2)
        guard fixture.pending.count == 2 else { return }
        fixture.pending[0].resume(returning: true)
        await Task.yield()
        #expect(updates.isPreparingInstallation)
        #expect(oldInstallations == 0)
        fixture.pending[1].resume(returning: true)
        for _ in 0..<1_000 where updates.isPreparingInstallation { await Task.yield() }
        #expect(newInstallations == 1)
        #expect(oldInstallations == 0)
    }
}

@MainActor
private final class UpdatePersistenceFixture {
    var canSave = false
}

@MainActor
private final class UpdatePreparationFixture {
    var pending: [CheckedContinuation<Bool, Never>] = []
    func prepare() async -> Bool {
        await withCheckedContinuation { pending.append($0) }
    }
}
