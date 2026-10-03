import SwiftUI
import SyncCopiesCore

struct DriveView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var drive: DriveVerificationController
    @State private var actionFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.text("Google Drive")).font(.title2).fontWeight(.semibold)
            Text(L10n.text("Optional: confirm that Google Drive has received your local copy.")).foregroundStyle(.secondary)
            Text(L10n.text("The app reads file metadata only. It does not upload files, read cloud file contents or write to Google Drive."))
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("Google grants read access to metadata across all Drive files. Choosing a folder limits this app's queries, not Google's permission."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !drive.isAvailable {
                Label(L10n.text(model.isDemo ? "Google Drive is disabled in the preview." : "Google Drive is not configured for this build."), systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            if let failure = actionFailure ?? drive.failure.map({ L10n.text($0.messageKey) }) {
                Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if drive.cleanupPending {
                Text(L10n.text("Some previous Google credentials could not be removed. Retry when Keychain is available."))
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button(L10n.text("Retry credential cleanup")) { Task { await drive.start() } }
            }
            GroupBox(L10n.text("Google accounts")) {
                VStack(alignment: .leading, spacing: 12) {
                    if drive.accounts.isEmpty { Text(L10n.text("No Google account connected.")).foregroundStyle(.secondary) }
                    ForEach(drive.accounts) { account in
                        HStack {
                            Text(account.label).textSelection(.enabled)
                            Spacer()
                            Button(L10n.text("Disconnect")) {
                                Task {
                                    do { try await drive.disconnect(accountID: account.id); actionFailure = nil }
                                    catch { actionFailure = L10n.text("The Google Drive account is unavailable.") }
                                }
                            }.disabled(model.isDemo || drive.isConnecting)
                            .accessibilityLabel(L10n.format("Disconnect %@", account.label))
                        }
                    }
                    if drive.isConnecting {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(L10n.text("Complete Google sign-in in your browser."))
                            Button(L10n.text("Cancel")) { drive.cancelConnect() }
                        }
                    } else {
                        Button(L10n.text(drive.accounts.isEmpty ? "Connect Google account…" : "Connect another Google account…")) {
                            actionFailure = nil
                            drive.connect()
                        }.disabled(!drive.isAvailable || model.isDemo)
                    }
                    Text(L10n.text("Disconnecting stops checks on this Mac. Manage or revoke Google's permission separately in your Google account."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Link(L10n.text("Manage Google permissions"), destination: DriveVerificationController.permissionURL)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox(L10n.text("Check uploads per database")) {
                VStack(alignment: .leading, spacing: 16) {
                    let selected = model.databases.filter { model.preference(for: $0).enabled }
                    if selected.isEmpty { Text(L10n.text("Select a database on the Databases page first.")).foregroundStyle(.secondary) }
                    ForEach(selected) { database in
                        DriveDatabaseView(database: database, drive: drive, demo: model.isDemo)
                    }
                    Button(L10n.text(drive.isChecking ? "Checking…" : "Check cloud now")) { drive.requestCheck() }
                        .disabled(!drive.isAvailable || drive.bindings.isEmpty || drive.isChecking || model.isDemo || model.isChecking)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox(L10n.text("Cloud notifications")) {
                VStack(alignment: .leading, spacing: 10) {
                    option("Cloud check errors", \.errors)
                    option("Overdue uploads", \.overdue)
                    option("Resolved cloud check errors", \.recoveries)
                    option("Confirmed uploads", \.confirmed)
                    Text(L10n.text("Cloud notifications are independent of local copy notifications. macOS permission is shared."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(L10n.text("Allow notifications…")) { model.requestNotifications() }.disabled(model.isDemo)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.disabled(!drive.canChangeSettings)
    }

    private func option(_ title: String, _ key: WritableKeyPath<DriveNotificationPreferences, Bool>) -> some View {
        Toggle(L10n.text(title), isOn: Binding(get: { drive.preferences[keyPath: key] }, set: { value in
            var preferences = drive.preferences
            preferences[keyPath: key] = value
            do { try drive.setPreferences(preferences); actionFailure = nil }
            catch { actionFailure = L10n.text("Google Drive settings could not be saved or read.") }
        })).toggleStyle(.checkbox).disabled(model.isDemo)
    }
}

private struct DriveDatabaseView: View {
    let database: Database
    @ObservedObject var drive: DriveVerificationController
    let demo: Bool
    @State private var accountID = ""
    @State private var folderInput = ""
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(database.displayName).font(.headline)
            if let binding = drive.bindings[database.id] {
                Label(binding.folderName, systemImage: "folder").textSelection(.enabled)
                DriveStatusView(state: drive.results[database.id])
                Button(L10n.text("Turn off cloud checking")) {
                    do { try drive.disable(databaseID: database.id); failure = nil }
                    catch { failure = L10n.text("Google Drive settings could not be saved or read.") }
                }.disabled(demo || saving)
            } else { Text(L10n.text("Cloud checking is off.")).foregroundStyle(.secondary) }
            Picker(L10n.text("Google account"), selection: $accountID) {
                Text(L10n.text("Choose an account")).tag("")
                ForEach(drive.accounts) { account in Text(account.label).tag(account.id) }
            }.disabled(demo || saving)
            TextField(L10n.text("Google Drive folder link or ID"), text: $folderInput)
                .textFieldStyle(.roundedBorder).disabled(demo || saving)
                .onSubmit { saveFolder() }
            HStack {
                Button(L10n.text("Verify and use folder")) { saveFolder() }
                    .disabled(demo || saving || !drive.isAvailable || accountID.isEmpty || folderInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if saving { ProgressView().controlSize(.small) }
            }
            Text(L10n.format("The check looks for %@ in this folder. Choose the folder containing the synced copy.", database.filename))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let failure { Text(failure).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            Divider()
        }
        .task {
            if let binding = drive.bindings[database.id] { accountID = binding.accountID; folderInput = binding.folderID }
            else if drive.accounts.count == 1 { accountID = drive.accounts[0].id }
        }
    }

    private func saveFolder() {
        guard !saving, !demo, drive.isAvailable, !accountID.isEmpty else { return }
        let account = accountID, folder = folderInput
        saving = true
        Task {
            defer { saving = false }
            do { try await drive.selectFolder(databaseID: database.id, accountID: account, input: folder); failure = nil }
            catch { failure = L10n.text((error as? DriveControllerFailure)?.messageKey ?? "The Google Drive folder could not be verified.") }
        }
    }
}

struct DriveStatusView: View {
    let state: UploadVerificationState?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let state {
                Label(L10n.text(state.titleKey), systemImage: symbol(state.status))
                    .foregroundStyle(state.status == .confirmed ? Color.green : Color.secondary)
                if case .error(let reason) = state.status {
                    Text(L10n.text(reason.messageKey)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L10n.format("Cloud last checked: %@", L10n.date(Date(timeIntervalSince1970: Double(state.checkedAt)))))
                    .font(.caption).foregroundStyle(.secondary)
                if state.status != .confirmed, let time = state.lastConfirmedAt {
                    Text(L10n.format("Previously confirmed: %@. This does not confirm the current upload.", L10n.date(Date(timeIntervalSince1970: Double(time)))))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else { Text(L10n.text("Cloud not checked yet")).foregroundStyle(.secondary) }
        }
    }

    private func symbol(_ status: UploadVerificationStatus) -> String {
        switch status {
        case .confirmed: "checkmark.icloud"
        case .pending: "clock"
        case .overdue, .error: "exclamationmark.triangle"
        }
    }
}
