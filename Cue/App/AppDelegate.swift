import AppKit
import CueCore
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var app: AppModel?
    private var panel: PanelController?
    private var statusItem: StatusItemController?
    private var editor: EditorWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        var store = LibraryStore()
        var secrets: any SecretStore = KeychainSecretStore()
        var notifications: any ReminderNotifying = ReminderNotifications()
        #if DEBUG
        // Debug aid: `-CueLibraryDirectory <dir>` reads and writes a fixture library instead of the real one,
        // with secrets kept in memory so testing never touches the login Keychain.
        if let directory = UserDefaults.standard.string(forKey: "CueLibraryDirectory") {
            store = LibraryStore(directory: URL(fileURLWithPath: directory, isDirectory: true))
            secrets = InMemorySecretStore()
            notifications = LoggedReminderNotifications()
        }
        #endif
        let app = AppModel(store: store, secrets: secrets, notifications: notifications)
        let editor = EditorWindowController(model: EditorModel(app: app))
        let panel = PanelController(model: PanelModel(app: app))
        panel.model.openEditor = { [weak editor] id, atTestRun in editor?.show(itemID: id, atTestRun: atTestRun) }
        panel.model.openEditorNew = { [weak editor] command in editor?.showNew(command: command) }
        let statusItem = StatusItemController { [weak panel] in panel?.toggle() }
        app.onIconChange = { [weak statusItem] state in statusItem?.setIcon(state) }
        app.onOpenPanel = { [weak panel] in if panel?.isVisible == false { panel?.show() } }
        statusItem.onDrop = { [weak panel] urls, text in
            guard let panel else { return }
            if !panel.isVisible { panel.show() }
            panel.model.receiveDrop(fileURLs: urls, text: text)
        }
        statusItem.setIcon(app.iconState)
        panel.anchor = { [weak statusItem] in statusItem?.buttonFrameOnScreen }
        panel.onVisibilityChange = { [weak statusItem] visible in statusItem?.setHighlighted(visible) }

        KeyboardShortcuts.onKeyDown(for: .togglePanel) { [weak panel] in panel?.toggle() }

        self.app = app
        self.editor = editor
        self.panel = panel
        self.statusItem = statusItem

        #if DEBUG
        // Debug aid: `Cue.debug` distributed notifications toggle or snapshot the panel from a shell.
        DistributedNotificationCenter.default().addObserver(forName: .init("com.jmarwane.cue.debug"), object: nil, queue: .main) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated {
                if command == "toggle" { panel.toggle() }
                if command.hasPrefix("editor-snapshot:") { editor.writeSnapshot(to: String(command.dropFirst("editor-snapshot:".count))) }
                if command == "editor-close" { editor.closeWindow() }
                if command.hasPrefix("editor-new:") { editor.showNew(command: String(command.dropFirst("editor-new:".count))) }
                if command == "editor-save", let id = editor.model.selectedID { editor.model.save(id) }
                if command == "editor-revert", let id = editor.model.selectedID { editor.model.revert(id) }
                if command == "editor-remove", let id = editor.model.selectedID { editor.model.remove(id) }
                if command.hasPrefix("editor-command:"), var draft = editor.model.draft {
                    draft.command = String(command.dropFirst("editor-command:".count))
                    editor.model.draft = draft
                }
                if command.hasPrefix("editor-move:"), let parts = Optional(command.dropFirst("editor-move:".count).split(separator: ",")),
                   parts.count == 2, let from = Int(parts[0]), let to = Int(parts[1]) {
                    editor.model.move(from: IndexSet(integer: from), to: to)
                }
                if command.hasPrefix("editor-test") { if let id = editor.model.selectedID { editor.model.testRun(id) } }
                if command.hasPrefix("editor-select:") {
                    let name = String(command.dropFirst("editor-select:".count))
                    editor.model.select(editor.model.sidebarItems.first { $0.name == name }?.id)
                }
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
