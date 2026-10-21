import AppKit
import CueCore
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var app: AppModel?
    private var panel: PanelController?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        var store = LibraryStore()
        #if DEBUG
        // Debug aid: `-CueLibraryDirectory <dir>` reads and writes a fixture library instead of the real one.
        if let directory = UserDefaults.standard.string(forKey: "CueLibraryDirectory") {
            store = LibraryStore(directory: URL(fileURLWithPath: directory, isDirectory: true))
        }
        #endif
        let app = AppModel(store: store)
        let panel = PanelController(model: PanelModel(app: app))
        let statusItem = StatusItemController { [weak panel] in panel?.toggle() }
        app.onIconChange = { [weak statusItem] state in statusItem?.setIcon(state) }
        statusItem.setIcon(app.iconState)
        panel.anchor = { [weak statusItem] in statusItem?.buttonFrameOnScreen }
        panel.onVisibilityChange = { [weak statusItem] visible in statusItem?.setHighlighted(visible) }

        KeyboardShortcuts.onKeyDown(for: .togglePanel) { [weak panel] in panel?.toggle() }

        self.app = app
        self.panel = panel
        self.statusItem = statusItem

        #if DEBUG
        // Debug aid: `Cue.debug` distributed notifications toggle or snapshot the panel from a shell.
        DistributedNotificationCenter.default().addObserver(forName: .init("com.jmarwane.cue.debug"), object: nil, queue: .main) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated {
                if command == "toggle" { panel.toggle() }
                panel.model.debugCommand(command)
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
