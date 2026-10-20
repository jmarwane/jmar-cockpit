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
    }
}
