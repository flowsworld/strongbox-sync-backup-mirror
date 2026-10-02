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
                        Label("Vorschau mit Beispieldaten. Es werden keine Dateien kopiert.", systemImage: "info.circle")
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
            heading("Allgemein", "Startverhalten, gemeinsames Ziel und Strongbox-Zugriff.")
            GroupBox("Beim Anmelden") {
                Toggle("Sync-Kopien automatisch starten", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                    .toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(model.isDemo)
                if model.loginNeedsApproval {
                    Text("Erlaube das Anmeldeobjekt in den macOS-Systemeinstellungen.").foregroundStyle(.secondary)
                }
            }
            GroupBox("Gemeinsamer Zielordner") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) { folderPath(model.commonTargetName); Spacer(); Button("Ändern…") { model.chooseTarget() }.disabled(model.isDemo || model.isChecking) }
                    Text("Wird verwendet, solange eine Datenbank kein eigenes Ziel hat.").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Strongbox-Zugriff") { sourceAccess }
            Text("Die App kopiert automatisch, solange sie läuft. Änderungen an lokalen Strongbox-Backups lösen eine Prüfung aus; zusätzlich wird alle 15 Minuten und nach dem Aufwachen geprüft.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var databases: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                heading("Datenbanken", "Wähle die Strongbox-Sync-Datenbanken für deine Lesekopien.")
                Spacer()
                if model.isChecking { ProgressView().controlSize(.small) }
                Button("Jetzt prüfen") { model.refresh() }
                    .disabled(model.isChecking || !model.sourceGranted || model.isDemo)
            }
            GroupBox {
                Text("Die App kopiert ausschließlich lokale Backups deiner Strongbox-Sync-Datenbanken. Änderungen an den Kopien werden nicht zurück zu Strongbox übertragen und beim nächsten erfolgreichen Abgleich überschrieben.")
                    .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Strongbox-Zugriff") { sourceAccess }
            if !model.sourceGranted {
                Text("Erlaube zuerst den Lesezugriff auf Strongbox. Die App zeigt anschließend die gefundenen Datenbanken.")
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top) {
                    folderPath(model.commonTargetName)
                    Spacer()
                    Button("Gemeinsames Ziel ändern…") { model.chooseTarget() }.disabled(model.isDemo || model.isChecking)
                }
                if model.databases.isEmpty {
                    Text("Keine Strongbox-Sync-Datenbank gefunden.").foregroundStyle(.secondary)
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
                if !preferences.enabled { Text("Nicht ausgewählt").foregroundStyle(.secondary) }
                else if state?.error != nil { Label("Prüfung fehlgeschlagen", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                else if state?.checked != nil { Label("Lokal kopiert", systemImage: "checkmark.circle").foregroundStyle(.green) }
                else { Text("Noch nicht geprüft").foregroundStyle(.secondary) }
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preferences.target == nil ? "Gemeinsamer Zielordner" : "Eigener Zielordner")
                        .foregroundStyle(.secondary)
                    folderPath(model.targetFolderPath(for: database))
                }.font(.callout)
                Spacer()
                if preferences.target != nil {
                    Button("Gemeinsames Ziel") { model.useCommonTarget(for: database) }.disabled(model.isDemo || model.isChecking)
                }
                Button(preferences.target == nil ? "Eigenes Ziel…" : "Ziel ändern…") { model.chooseTarget(for: database) }
                    .disabled(model.isDemo || model.isChecking)
            }
            if let error = state?.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            Button {
                if model.expandedDatabases.contains(database.id) { model.expandedDatabases.remove(database.id) }
                else { model.expandedDatabases.insert(database.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.expandedDatabases.contains(database.id) ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Kopierdetails anzeigen")
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)
            .accessibilityLabel("Kopierdetails anzeigen, \(database.displayName)")
            .accessibilityValue(model.expandedDatabases.contains(database.id) ? "Ausgeklappt" : "Eingeklappt")
            if model.expandedDatabases.contains(database.id) {
                VStack(alignment: .leading, spacing: 10) {
                    detail("Dateiname", database.filename)
                    if let date = state?.backup?.creationDate { detail("Neuestes lokales Backup", date.formatted(date: .abbreviated, time: .shortened)) }
                    if let date = preferences.lastCopied { detail("Letzte erfolgreiche Kopie", date.formatted(date: .abbreviated, time: .shortened)) }
                    if let date = state?.checked { detail("Letzte Prüfung", date.formatted(date: .abbreviated, time: .shortened)) }
                    if let size = state?.backup?.size { detail("Dateigröße", ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                    detail("Cloud-Prüfung", "In dieser Version nicht verfügbar")
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
                Button(model.sourceGranted ? "Erneut erlauben…" : "Zugriff erlauben…") { model.chooseSource() }
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
            heading("Mitteilungen", "Du entscheidest, welche Ereignisse gemeldet werden.")
            GroupBox("Lokale Kopien") {
                VStack(alignment: .leading, spacing: 18) {
                    notificationOption("Kopier- und Lesefehler", "Ziel fehlt, Zugriff verweigert oder Backup nicht lesbar.", \.failures)
                    notificationOption("Erfolgreiche Kopien", "Eine neue oder geänderte Datei wurde erfolgreich kopiert.", \.copies)
                    notificationOption("Behobene Fehler", "Eine zuvor fehlgeschlagene Kopie funktioniert wieder.", \.recoveries)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            GroupBox("macOS-Mitteilungen") {
                HStack {
                    Text(model.notificationStatus).foregroundStyle(.secondary)
                    Spacer()
                    Button("Mitteilungen erlauben…") { model.requestNotifications() }.disabled(model.isDemo)
                    Button("Testmitteilung senden") { model.testNotification() }.disabled(model.isDemo)
                }
            }
            Text("Gleiche Fehler werden nicht bei jeder Prüfung erneut gemeldet. Unveränderte Dateien lösen keine neue Erfolgsmeldung aus. Status und Verlauf bleiben unabhängig von dieser Auswahl sichtbar.")
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
            heading("Google Drive", "Die optionale Upload-Prüfung folgt in einem Update.")
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Geplantes Update", systemImage: "checkmark.icloud").font(.headline)
                    Text("Die Prüfung wird feststellen, ob die Cloud-Datei mit der lokalen Lesekopie übereinstimmt. Die App lädt selbst keine Dateien hoch.")
                    Text("Mit dem Update kommen auch wählbare Mitteilungen für Prüffehler, überfällige Uploads und bestätigte Cloud-Dateien.")
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            Text("Ein Kopiererfolg bestätigt in dieser Version nur die lokale Datei im Zielordner.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Verlauf", "Kopien, Fehler und behobene Probleme. Die letzten 200 Ereignisse bleiben gespeichert.")
            if model.preferences.history.isEmpty { Text("Noch keine Ereignisse.").foregroundStyle(.secondary) }
            ForEach(model.preferences.history) { item in
                VStack(alignment: .leading, spacing: 5) {
                    Divider()
                    Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    Text(item.name).fontWeight(.medium)
                    Label(item.message, systemImage: item.isError ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(item.isError ? Color.orange : Color.secondary).textSelection(.enabled)
                }
            }
        }
    }
}
