import AppKit
import CueCore
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

enum SettingsKeys {
    static let reminderSound = "reminderSound"

    static func register() {
        UserDefaults.standard.register(defaults: [reminderSound: true])
    }
}

/// Hotkey, captured environment, launch at login, reminder sound, history (spec §15, M7).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let app: AppModel
    private var window: NSWindow?

    init(app: AppModel) {
        self.app = app
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cue Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView(app: app))
        window.setContentSize(NSSize(width: 520, height: 720))
        window.center()
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.hide(nil)
    }
}

private struct SettingsView: View {
    let app: AppModel
    @AppStorage(SettingsKeys.reminderSound) private var reminderSound = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginMessage: String?
    @State private var refreshing = false
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Section("Panel") {
                KeyboardShortcuts.Recorder("Open and close the panel:", name: .togglePanel)
            }

            Section("Environment") {
                LabeledContent("Captured from") {
                    Text(sourceDescription)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("PATH").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text(app.environment?.path ?? "Capturing…")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("Commands run with the environment of your login shell, captured when Cue starts.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(refreshing ? "Refreshing…" : "Refresh") {
                        refreshing = true
                        Task {
                            await app.refreshEnvironment()
                            refreshing = false
                        }
                    }
                    .disabled(refreshing)
                }
            }

            Section("General") {
                Toggle("Launch Cue at login", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                if let loginMessage {
                    Text(loginMessage).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Toggle("Play a sound with reminders", isOn: $reminderSound)
            }

            Section("History") {
                HStack {
                    Text("Cue keeps the last 20 runs of each item, with their output when Keep output is on.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History…") { confirmingClear = true }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Quit Cue") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear the run history of every item?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { app.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Logs kept for View Log are deleted too.")
        }
        .frame(width: 520)
    }

    private var sourceDescription: String {
        switch app.environment?.source {
        case .interactiveLogin?: "Your login shell (interactive)"
        case .login?: "Your login shell (non-interactive; the interactive one timed out)"
        case .fallback?: "A default PATH (your shell didn't answer)"
        case nil: "Capturing…"
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginMessage = SMAppService.mainApp.status == .requiresApproval ? "Approve Cue in System Settings › General › Login Items." : nil
        } catch {
            loginMessage = "Couldn't change it: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
