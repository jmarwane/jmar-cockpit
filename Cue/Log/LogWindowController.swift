import AppKit
import CueCore
import SwiftUI

/// Read-only, monospaced output of an item's latest run, with Copy and Reveal in Finder (spec §15, M6).
@MainActor
final class LogWindowController: NSObject, NSWindowDelegate {
    let app: AppModel
    private var windows: [UUID: NSWindow] = [:]

    init(app: AppModel) {
        self.app = app
    }

    func show(_ id: UUID) {
        guard let item = app.item(id) else { return }
        let window = windows[id] ?? makeWindow(for: item)
        windows[id] = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(for item: Item) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(item.name) — Log"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: LogView(app: app, itemID: item.id))
        window.setContentSize(NSSize(width: 640, height: 420))
        window.center()
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== window }
        if windows.isEmpty, !NSApp.windows.contains(where: { $0.isVisible && $0 !== window && $0.styleMask.contains(.titled) }) {
            NSApp.hide(nil)
        }
    }
}

private struct LogView: View {
    let app: AppModel
    let itemID: UUID

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let text = app.logText(for: itemID) ?? ""
            VStack(spacing: 0) {
                LogTextView(text: text.isEmpty ? "No output kept for this item." : text)
                Divider()
                HStack {
                    Text(app.activeRuns[itemID] != nil ? "Running · updates live" : "Latest run")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy") { app.copy(text) }
                        .disabled(text.isEmpty)
                    Button("Reveal in Finder") {
                        if let url = app.history.latestLog(for: itemID) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    .disabled(app.history.latestLog(for: itemID) == nil)
                }
                .padding(10)
            }
        }
        .frame(minWidth: 420, minHeight: 240)
    }
}

/// An NSTextView: fast with long output, selectable, never editable. Follows the end while it's scrolled there.
private struct LogTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            view.textContainerInset = NSSize(width: 8, height: 8)
            view.string = text
            view.scrollToEndOfDocument(nil)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        let atEnd = scroll.verticalScroller.map { $0.floatValue > 0.98 } ?? true
        view.string = text
        if atEnd { view.scrollToEndOfDocument(nil) }
    }
}
