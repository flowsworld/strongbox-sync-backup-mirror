import SwiftUI
import SyncCopiesCore

struct SetupChecklist: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GroupBox(L10n.text("Prepare your first copy")) {
            VStack(alignment: .leading, spacing: 18) {
                step(1, complete: model.sourceReadStatus == .available && model.preferences.globalFailure == nil,
                     title: "Read Strongbox", description: "The app uses the newest local backup.") {
                    Button(L10n.text("Allow access…")) { model.chooseSource() }
                        .disabled(!model.canChooseSource)
                }
                step(2, complete: !model.preferences.defaultTargets.isEmpty,
                     title: "Choose where copies go", description: "Shared destinations for your databases.") {
                    Button(L10n.text("Choose folder…")) { model.chooseTarget() }
                        .disabled(model.isDemo || model.isChecking || model.isStopping)
                }
                step(3, complete: model.activeCount > 0,
                     title: "Select databases", description: "The list appears after read access is allowed.") {
                    Button(L10n.text("Go to databases")) { model.page = .databases }
                        .disabled(model.sourceReadStatus != .available)
                }
                Divider()
                Text(L10n.text("Only local Strongbox Sync backups are copied. The app never uploads files or writes back to Strongbox. Changes to copies are replaced on the next successful reconciliation."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("Google Drive is optional and can be set up later on its own page."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func step<Action: View>(_ number: Int, complete: Bool, title: String,
                                   description: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: complete ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title2)
                .foregroundStyle(complete ? Color.green : Color.secondary)
                .accessibilityLabel(complete ? L10n.text("Complete") : L10n.format("Step %@", L10n.count(number)))
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text(title)).fontWeight(.medium)
                Text(L10n.text(description)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            action()
        }
    }
}
