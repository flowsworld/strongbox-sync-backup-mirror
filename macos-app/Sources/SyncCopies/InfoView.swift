import SwiftUI
import SyncCopiesCore

struct InfoView: View {
    @ObservedObject var updates: AppUpdates

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(L10n.text("Info")).font(.title2).fontWeight(.semibold)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.appName).font(.headline)
                    HStack {
                        Text(L10n.text("Version")); Text(updates.configuration.version)
                        Text(L10n.text("Build")); Text(updates.configuration.build)
                    }
                    HStack {
                        Text(L10n.text("Distribution")); Text(L10n.text(updates.channelTitle))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox(L10n.text("Updates")) {
                VStack(alignment: .leading, spacing: 12) {
                    if !updates.statusMessage.isEmpty {
                        Text(L10n.text(updates.statusMessage)).foregroundStyle(.secondary)
                    }
                    if updates.showsDirectControls {
                        Button(L10n.text(updates.installationBlocked ? "Retry update installation" : "Check for updates…")) {
                            updates.checkNow()
                        }.disabled((!updates.canCheckForUpdates && !updates.installationBlocked) || updates.isPreparingInstallation)
                        Toggle(L10n.text("Automatically check for updates"), isOn: Binding(
                            get: { updates.automaticallyChecksForUpdates }, set: updates.setAutomaticChecks
                        )).toggleStyle(.checkbox).disabled(!updates.canCheckForUpdates)
                        Toggle(L10n.text("Automatically download and install updates"), isOn: Binding(
                            get: { updates.automaticallyDownloadsUpdates }, set: updates.setAutomaticDownloads
                        )).toggleStyle(.checkbox).disabled(!updates.canCheckForUpdates || !updates.automaticallyChecksForUpdates)
                    } else if updates.configuration.channel == .store {
                        Button(L10n.text("Open in the Mac App Store")) { updates.openStore() }
                            .disabled(!updates.canOpenStore)
                        if updates.configuration.storeURL == nil {
                            Text(L10n.text("The Mac App Store link is not configured.")).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
