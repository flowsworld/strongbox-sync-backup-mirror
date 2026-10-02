import Foundation

/// One host gate owns the copy and provider workers throughout an update attempt.
@MainActor
final class AppUpdatePreparation {
    private let model: AppModel
    private let drive: DriveVerificationController
    private var generation = 0

    init(model: AppModel, drive: DriveVerificationController) {
        self.model = model
        self.drive = drive
    }

    func prepare() async -> Bool {
        generation += 1
        let attempt = generation
        async let providerReady = drive.quiesceAndPersist()
        let copyReady = await model.prepareForUpdate()
        let ready = await providerReady
        guard !Task.isCancelled, attempt == generation else { return false }
        guard copyReady && ready else { resume(); return false }
        return true
    }

    func resume() {
        guard !model.isTerminating else { return }
        generation += 1
        model.resumeAfterCancelledUpdate()
        drive.resume()
    }
}
