import AppKit
import CueCore
import SwiftUI

/// The editor window (~720 × 600). Opening it brings Cue to the front; closing it hands focus back.
@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    let model: EditorModel
    private var window: NSWindow?

    init(model: EditorModel) {
        self.model = model
    }

    /// Opens on an item, or the first one. `atTestRun` emphasizes Test Run for untested items.
    func show(itemID: UUID? = nil, atTestRun: Bool = false) {
        if let itemID { model.select(itemID) } else if model.selectedID == nil { model.select(model.sidebarItems.first?.id) }
        model.emphasizeTestRun = atTestRun
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Adds an unsaved item from a command and opens it at Test Run.
    func showNew(command: String, kind: ItemKind? = nil) {
        model.addNew(command: command, kind: kind)
        show(itemID: model.selectedID, atTestRun: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cue Items"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: EditorView(model: model))
        window.setContentSize(NSSize(width: 720, height: 600))
        window.center()
        window.setFrameAutosaveName("CueEditor")
        window.delegate = self
        return window
    }

    #if DEBUG
    func closeWindow() { window?.performClose(nil) }

    /// Debug aid: renders the editor window's content into a PNG.
    func writeSnapshot(to path: String) {
        guard let window, let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        // cacheDisplay skips the window's own background; paint it first so text is legible.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: rep.size).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #endif

    func windowWillClose(_ notification: Notification) {
        // Cue has no Dock icon; give focus back to the app that had it.
        NSApp.hide(nil)
    }
}
