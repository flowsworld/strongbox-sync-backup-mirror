import AppKit
import SwiftUI
import SyncCopiesCore

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding<SettingsPage?>(get: { model.page }, set: { if let value = $0 { model.page = value } })) {
                ForEach(SettingsPage.allCases) { page in
                    Label(page.title, systemImage: page.symbol).tag(page)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 170)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.isDemo {
                        Label(L10n.text("Preview with sample data. No files are copied."), systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let problem = model.problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).textSelection(.enabled)
                    }
                    content
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 740, minHeight: 540)
    }

    @ViewBuilder private var content: some View {
        switch model.page {
        case .general: general
        case .databases: databases
        case .notifications: notifications
        case .googleDrive: googleDrive
        case .history: history
        }
    }

    private func heading(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2).fontWeight(.semibold)
            Text(description).foregroundStyle(.secondary)
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading(L10n.text("General"), L10n.text("Startup, shared destination and Strongbox access."))
            GroupBox(L10n.text("At login")) {
                Toggle(L10n.format("Start %@ automatically", L10n.appName), isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                    .toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(model.isDemo)
                if model.loginNeedsApproval {
                    Text(L10n.text("Allow the login item in macOS System Settings.")).foregroundStyle(.secondary)
                }
            }
            GroupBox(L10n.text("Shared destination folder")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) { folderPath(model.commonTargetName); Spacer(); Button(L10n.text("Change…")) { model.chooseTarget() }.disabled(model.isDemo || model.isChecking) }
                    Text(L10n.text("Used unless a database has its own destination.")).font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox(L10n.text("Strongbox access")) { sourceAccess }
            Text(L10n.text("The app copies automatically while running. Changes to local Strongbox backups trigger a check, as do waking from sleep and the 15-minute timer."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var databases: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                heading(L10n.text("Databases"), L10n.text("Choose the Strongbox Sync databases for your read-only copies."))
                Spacer()
                if model.isChecking { ProgressView().controlSize(.small) }
                Button(L10n.text("Check now")) { model.refresh() }
                    .disabled(model.isChecking || !model.sourceGranted || model.isDemo)
            }
            GroupBox {
                Text(L10n.text("The app copies only local backups of your Strongbox Sync databases. Changes to copies are never sent back to Strongbox and are replaced on the next successful reconciliation."))
                    .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.sourceGranted {
                Text(L10n.text("First allow read access to Strongbox in General. The app will then show the databases it finds."))
                    .foregroundStyle(.secondary)
            } else {
                if model.databases.isEmpty {
                    Text(L10n.text("No Strongbox Sync databases found.")).foregroundStyle(.secondary)
                }
                ForEach(model.databases) { database in
                    databaseRow(database)
                }
            }
        }
    }

    private func databaseRow(_ database: Database) -> some View {
        let preferences = model.preference(for: database)
        let state = model.states[database.id]
        return VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Toggle(database.displayName, isOn: Binding(get: { model.preference(for: database).enabled }, set: { model.setEnabled($0, for: database) }))
                    .toggleStyle(.checkbox).fontWeight(.medium).disabled(model.isDemo || model.isChecking)
                Spacer()
                if !preferences.enabled { Text(L10n.text("Not selected")).foregroundStyle(.secondary) }
                else if state?.error != nil { Label(L10n.text("Check failed"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                else if state?.checked != nil { Label(L10n.text("Copied locally"), systemImage: "checkmark.circle").foregroundStyle(.green) }
                else { Text(L10n.text("Not checked yet")).foregroundStyle(.secondary) }
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preferences.target == nil ? L10n.text("Shared destination folder") : L10n.text("Individual destination folder"))
                        .foregroundStyle(.secondary)
                    folderPath(model.targetFolderPath(for: database))
                }.font(.callout)
                Spacer()
                if preferences.target != nil {
                    Button(L10n.text("Shared destination")) { model.useCommonTarget(for: database) }.disabled(model.isDemo || model.isChecking)
                }
                Button(preferences.target == nil ? L10n.text("Own destination…") : L10n.text("Change destination…")) { model.chooseTarget(for: database) }
                    .disabled(model.isDemo || model.isChecking)
            }
            if let error = state?.error { Text(error.rendered()).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            Button {
                if model.expandedDatabases.contains(database.id) { model.expandedDatabases.remove(database.id) }
                else { model.expandedDatabases.insert(database.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.expandedDatabases.contains(database.id) ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L10n.text("Show copy details"))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)
            .accessibilityLabel(L10n.format("Show copy details, %@", database.displayName))
            .accessibilityValue(model.expandedDatabases.contains(database.id) ? L10n.text("Expanded") : L10n.text("Collapsed"))
            if model.expandedDatabases.contains(database.id) {
                VStack(alignment: .leading, spacing: 10) {
                    detail(L10n.text("Filename"), database.filename)
                    if let date = state?.backup?.creationDate { detail(L10n.text("Latest local backup"), L10n.date(date)) }
                    if let date = preferences.lastCopied { detail(L10n.text("Last successful copy"), L10n.date(date)) }
                    if let date = state?.checked { detail(L10n.text("Last check"), L10n.date(date)) }
                    if let size = state?.backup?.size { detail(L10n.text("File size"), L10n.size(size)) }
                    detail(L10n.text("Cloud check"), L10n.text("Unavailable in this version"))
                }.padding(.top, 10).font(.callout)
            }
        }
    }

    private func folderPath(_ path: String) -> some View {
        Label {
            Text(path)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "folder")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceAccess: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(model.sourceReadStatus.title, systemImage: model.sourceReadStatus == .available ? "checkmark.circle" : "lock")
                    .foregroundStyle(model.sourceReadStatus == .available ? Color.green : model.sourceReadStatus == .unavailable ? Color.orange : Color.secondary)
                Spacer()
                Button(model.sourceGranted ? L10n.text("Allow again…") : L10n.text("Allow access…")) { model.chooseSource() }
                    .disabled(!model.canChooseSource)
            }
            if model.sourceGranted { folderPath(model.sourceFolderPath).font(.callout) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(name).foregroundStyle(.secondary).frame(width: 170, alignment: .leading); Text(value).textSelection(.enabled); Spacer(minLength: 0) }
    }

    private var notifications: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading(L10n.text("Notifications"), L10n.text("Choose which events send notifications."))
            GroupBox(L10n.text("Local copies")) {
                VStack(alignment: .leading, spacing: 18) {
                    notificationOption(L10n.text("Copy and read errors"), L10n.text("Missing destination, denied access or unreadable backup."), \.failures)
                    notificationOption(L10n.text("Successful copies"), L10n.text("A new or changed file was copied successfully."), \.copies)
                    notificationOption(L10n.text("Resolved errors"), L10n.text("A previously failed copy is working again."), \.recoveries)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            GroupBox(L10n.text("macOS notifications")) {
                HStack {
                    Text(model.notificationStatus).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("Allow notifications…")) { model.requestNotifications() }.disabled(model.isDemo)
                    Button(L10n.text("Send test notification")) { model.testNotification() }.disabled(model.isDemo)
                }
            }
            Text(L10n.text("Repeated checks do not send the same error again. Unchanged files do not trigger another success notification. Status and history remain visible regardless of these choices."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }
    private func notificationOption(_ title: String, _ description: String, _ key: WritableKeyPath<NotificationPreferences, Bool>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(title, isOn: Binding(get: { model.preferences.notifications[keyPath: key] }, set: { model.setNotification(key, to: $0) })).toggleStyle(.checkbox)
            Text(description).font(.callout).foregroundStyle(.secondary).padding(.leading, 22)
        }
    }

    private var googleDrive: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading(L10n.text("Google Drive"), L10n.text("The optional upload check is coming in an update."))
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label(L10n.text("Planned update"), systemImage: "checkmark.icloud").font(.headline)
                    Text(L10n.text("The check will compare the cloud file with the local read-only copy. The app does not upload files itself."))
                    Text(L10n.text("The update will also let you choose notifications for check errors, overdue uploads and verified cloud files."))
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            Text(L10n.text("In this version, a successful copy confirms only the local file in the destination folder.")).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(L10n.text("History"), L10n.text("Copies, errors and resolved problems. The latest 200 events are saved."))
            if model.preferences.history.isEmpty { Text(L10n.text("No events yet.")).foregroundStyle(.secondary) }
            ForEach(model.preferences.history) { item in
                VStack(alignment: .leading, spacing: 5) {
                    Divider()
                    Text(L10n.date(item.date)).font(.caption).foregroundStyle(.secondary)
                    Text(item.displayName).fontWeight(.medium)
                    Label(item.message.rendered(), systemImage: item.isError ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(item.isError ? Color.orange : Color.secondary).textSelection(.enabled)
                }
            }
        }
    }
}
