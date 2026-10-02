import AppKit
import Combine
import Foundation
#if DIESIS_DIRECT_UPDATES
import Sparkle
#endif

struct AppUpdateConfiguration: Equatable {
    enum Channel: String { case development, direct, store }
    let channel: Channel
    let version: String
    let build: String
    let feedURL: URL?
    let publicKey: String?
    let storeURL: URL?

    init(info: [String: Any]) {
        channel = Channel(rawValue: info["DIESISDistributionChannel"] as? String ?? "") ?? .development
        version = info["CFBundleShortVersionString"] as? String ?? "?"
        build = info["CFBundleVersion"] as? String ?? "?"
        feedURL = Self.httpsURL(info["SUFeedURL"] as? String)
        if let key = info["SUPublicEDKey"] as? String,
           let bytes = Data(base64Encoded: key), bytes.count == 32,
           bytes.base64EncodedString() == key { publicKey = key }
        else { publicKey = nil }
        let candidate = Self.httpsURL(info["DIESISStoreURL"] as? String)
        storeURL = candidate?.host == "apps.apple.com" ? candidate : nil
    }

    static var current: Self { Self(info: Bundle.main.infoDictionary ?? [:]) }
    var directConfigured: Bool { channel == .direct && feedURL != nil && publicKey != nil }

    private static func httpsURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme == "https",
              let host = url.host, !host.isEmpty,
              host != "localhost", !host.hasSuffix(".invalid"), !host.hasSuffix(".example"),
              host != "example.com", host != "example.org", host != "example.net",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url
    }
}

/// Only direct builds compile Sparkle. The host owns durable shutdown and passes its result here.
@MainActor
final class AppUpdates: NSObject, ObservableObject {
    let configuration: AppUpdateConfiguration
    @Published private(set) var statusMessage: String
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var isPreparingInstallation = false
    @Published private(set) var installationBlocked = false
    @Published private(set) var isInstallingUpdate = false

    private let demo: Bool
    private let prepareForUpdate: @MainActor () async -> Bool
    private let resumeAfterCancelledUpdate: @MainActor () -> Void
    private var deferredInstallation: (() -> Void)?
    private var preparation: Task<Void, Never>?
    private var preparationGeneration = 0
#if DIESIS_DIRECT_UPDATES
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
#endif

    init(demo: Bool, configuration: AppUpdateConfiguration = .current,
         resumeAfterCancelledUpdate: @escaping @MainActor () -> Void = {},
         prepareForUpdate: @escaping @MainActor () async -> Bool) {
        self.configuration = configuration
        self.demo = demo
        self.prepareForUpdate = prepareForUpdate
        self.resumeAfterCancelledUpdate = resumeAfterCancelledUpdate
        if demo { statusMessage = "Updates are disabled in the preview." }
        else {
            switch configuration.channel {
            case .development: statusMessage = "This development build does not check for updates."
            case .store: statusMessage = "Updates are delivered through the Mac App Store."
            case .direct: statusMessage = "Updates are not configured for this build."
            }
        }
        super.init()
    }

    var channelTitle: String {
        switch configuration.channel {
        case .development: "Development"
        case .direct: "Direct distribution"
        case .store: "Mac App Store"
        }
    }

    var showsDirectControls: Bool { configuration.channel == .direct }
    var canOpenStore: Bool { !demo && configuration.channel == .store && configuration.storeURL != nil }

    /// Call after applicationDidFinishLaunching. Missing feed/key leaves all external effects disabled.
    func start() {
        guard !demo, configuration.directConfigured else { return }
#if DIESIS_DIRECT_UPDATES
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        // Profile reporting is an app policy, independent of old updater defaults.
        controller.updater.sendsSystemProfile = false
        do {
            try controller.updater.start()
            statusMessage = ""
            observations = [
                controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor in self?.refreshSettings() }
                },
                controller.updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor in self?.refreshSettings() }
                },
                controller.updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor in self?.refreshSettings() }
                },
            ]
            refreshSettings()
        } catch {
            // Never put raw updater errors, URLs or server responses in history.
            self.controller = nil
            statusMessage = "The updater could not be started."
        }
#endif
    }

    func checkNow() {
        guard !demo, !isPreparingInstallation else { return }
        if installationBlocked { beginPreparation(); return }
#if DIESIS_DIRECT_UPDATES
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
#endif
    }

    func setAutomaticChecks(_ enabled: Bool) {
#if DIESIS_DIRECT_UPDATES
        guard !demo, let controller else { return }
        controller.updater.automaticallyChecksForUpdates = enabled
        refreshSettings()
#endif
    }

    func setAutomaticDownloads(_ enabled: Bool) {
#if DIESIS_DIRECT_UPDATES
        guard !demo, let controller, controller.updater.allowsAutomaticUpdates else { return }
        controller.updater.automaticallyDownloadsUpdates = enabled
        refreshSettings()
#endif
    }

    func openStore() {
        guard canOpenStore, let url = configuration.storeURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Returns immediately, then releases the continuation once after durable preparation succeeds.
    /// A failed save retains the pending update for an explicit user retry.
    func postponeInstallation(until continuation: @escaping () -> Void) {
        guard !demo, deferredInstallation == nil else { return }
        isInstallingUpdate = true
        deferredInstallation = continuation
        beginPreparation()
    }

    func cancelInstallation() {
        let wasInstalling = isInstallingUpdate
        preparation?.cancel()
        preparationGeneration += 1
        preparation = nil
        deferredInstallation = nil
        isPreparingInstallation = false
        installationBlocked = false
        isInstallingUpdate = false
        statusMessage = ""
        if wasInstalling { resumeAfterCancelledUpdate() }
#if DIESIS_DIRECT_UPDATES
        refreshSettings()
#endif
    }

    private func beginPreparation() {
        guard deferredInstallation != nil, preparation == nil else { return }
        isPreparingInstallation = true
        installationBlocked = false
        canCheckForUpdates = false
        statusMessage = "Preparing update installation…"
        preparationGeneration += 1
        let generation = preparationGeneration
        preparation = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let prepared = await prepareForUpdate()
            // A cancelled attempt must not resume or overwrite a later attempt's state.
            guard !Task.isCancelled, preparationGeneration == generation else { return }
            preparation = nil
            isPreparingInstallation = false
            guard prepared else {
                installationBlocked = true
                statusMessage = "Update installation is blocked because settings could not be saved."
                return
            }
            let continuation = deferredInstallation
            deferredInstallation = nil
            statusMessage = ""
            continuation?()
        }
    }

#if DIESIS_DIRECT_UPDATES
    private func refreshSettings() {
        guard let updater = controller?.updater else { return }
        canCheckForUpdates = updater.canCheckForUpdates && !isPreparingInstallation && !installationBlocked
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
    }
#endif
}

#if DIESIS_DIRECT_UPDATES
extension AppUpdates: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? { configuration.feedURL?.absoluteString }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
    func feedParameters(for updater: SPUUpdater, sendingSystemProfile: Bool) -> [[String: String]] { [] }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeInstallation(until: installHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        // Keep normal Sparkle scheduling. The host's applicationShouldTerminate gate also covers install-on-quit.
        isInstallingUpdate = true
        return false
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        cancelInstallation()
        let code = (error as NSError).code
        statusMessage = (error as NSError).domain == SUSparkleErrorDomain &&
            (code == SUError.noUpdateError.rawValue || code == SUError.installationCanceledError.rawValue)
            ? "" : "The update could not be completed."
        refreshSettings()
    }
}
#endif
