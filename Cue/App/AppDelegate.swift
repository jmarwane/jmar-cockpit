import AppKit
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: PanelController?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = PanelController()
        let statusItem = StatusItemController { [weak panel] in panel?.toggle() }
        panel.anchor = { [weak statusItem] in statusItem?.buttonFrameOnScreen }
        panel.onVisibilityChange = { [weak statusItem] visible in statusItem?.setHighlighted(visible) }

        KeyboardShortcuts.onKeyDown(for: .togglePanel) { [weak panel] in panel?.toggle() }

        self.panel = panel
        self.statusItem = statusItem

        #if DEBUG
        // Debug aid: `Cue.debug` distributed notifications toggle or snapshot the panel from a shell.
        DistributedNotificationCenter.default().addObserver(forName: .init("com.jmarwane.cue.debug"), object: nil, queue: .main) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated {
                if command == "toggle" { panel.toggle() }
                if command.hasPrefix("snapshot:") { panel.writeSnapshot(to: String(command.dropFirst("snapshot:".count))) }
            }
        }
        #endif

        // Debug aids, read from launch arguments only (never persisted):
        // `open Cue.app --args -CueOpenPanelAtLaunch YES -CueSnapshotPath /tmp/panel.png`
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "CueOpenPanelAtLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                panel.show()
                if let path = defaults.string(forKey: "CueSnapshotPath") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { panel.writeSnapshot(to: path) }
                }
            }
        }
    }
}
