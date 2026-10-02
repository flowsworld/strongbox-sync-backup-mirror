import AppKit
import Combine
import Darwin
import SwiftUI

@main
struct Application {
    @MainActor static func main() {
        let application = NSApplication.shared
        if CommandLine.arguments.contains("--copy-test") || CommandLine.arguments.contains("--copy-test-fixtures") {
            application.setActivationPolicy(.accessory)
            let targetIndex = CommandLine.arguments.firstIndex(of: "--copy-test-target")
            let targetURL = targetIndex.flatMap { index in
                CommandLine.arguments.indices.contains(index + 1) ? URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true) : nil
            }
            let result = CopyIntegrationTest.run(fixturesOnly: CommandLine.arguments.contains("--copy-test-fixtures"), targetURL: targetURL)
            exit(result)
        }
        let delegate = ApplicationDelegate(demo: CommandLine.arguments.contains("--demo"))
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model: AppModel
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var observer: AnyCancellable?
    private var terminationPending = false

    init(demo: Bool) {
        model = AppModel(demo: demo)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if model.startupConflict {
            if let identifier = Bundle.main.bundleIdentifier {
                NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                    .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?
                    .activate(options: [])
            }
            NSApplication.shared.terminate(nil)
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateIcon()
        observer = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.updateIcon() }
        }
        model.onOpenSettings = { [weak self] in self?.showSettings() }
        if !model.sourceGranted || model.isDemo { showSettings() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await model.updateNotificationStatus() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task {
            // Finish any atomic copy before releasing access and the instance lock.
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let heading = NSMenuItem(title: model.isDemo ? "Sync-Kopien · Vorschau" : "Sync-Kopien", action: nil, keyEquivalent: "")
        menu.addItem(heading)
        if let problem = model.problem { menu.addItem(NSMenuItem(title: problem, action: nil, keyEquivalent: "")) }
        for database in model.databases where model.preference(for: database).enabled {
            let state = model.states[database.id]
            let status = state?.error != nil ? "Prüfung fehlgeschlagen" : (state?.checked != nil ? "Lokal kopiert" : "Noch nicht geprüft")
            let row = NSMenuItem(title: "\(database.displayName): \(status)", action: #selector(openDatabase(_:)), keyEquivalent: "")
            row.representedObject = database.id.uuidString
            row.target = self
            menu.addItem(row)
        }
        if model.databases.isEmpty { menu.addItem(NSMenuItem(title: "Strongbox-Zugriff einrichten", action: nil, keyEquivalent: "")) }
        menu.addItem(.separator())
        let check = NSMenuItem(title: model.isChecking ? "Prüfung läuft…" : "Jetzt prüfen", action: #selector(checkNow), keyEquivalent: "r")
        check.target = self
        check.isEnabled = model.sourceGranted && !model.isChecking && !model.isDemo
        menu.autoenablesItems = false
        menu.addItem(check)
        let settings = NSMenuItem(title: "Einstellungen…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Sync-Kopien beenden", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func updateIcon() {
        let warning = model.failureCount > 0 || model.problem != nil
        statusItem?.button?.image = NSImage(systemSymbolName: warning ? "exclamationmark.triangle" : "doc.on.doc", accessibilityDescription: "Sync-Kopien")
        statusItem?.button?.toolTip = "Sync-Kopien: \(model.activeCount) aktiv, \(model.failureCount) Probleme"
    }

    @objc private func checkNow() { model.refresh() }
    @objc private func quitApp() { NSApplication.shared.terminate(nil) }
    @objc private func openDatabase(_ item: NSMenuItem) {
        model.page = .databases
        if let id = (item.representedObject as? String).flatMap(UUID.init(uuidString:)) { model.expandedDatabases.insert(id) }
        showSettings()
    }

    @objc func showSettings() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Sync-Kopien · Einstellungen"
            window.contentMinSize = NSSize(width: 740, height: 540)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            self.window = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
