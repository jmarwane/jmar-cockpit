import AppKit
import SwiftUI

/// Shows the panel under the status item and closes it on Esc, a click outside, or the hotkey.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let model = PanelModel()

    /// The status item's frame on screen.
    var anchor: () -> NSRect? = { nil }
    var onVisibilityChange: (Bool) -> Void = { _ in }

    private let panel = CuePanel()
    private let hostingView: NSHostingView<PanelRootView>
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?

    override init() {
        hostingView = NSHostingView(rootView: PanelRootView(model: model))
        super.init()
        hostingView.sizingOptions = [.preferredContentSize]

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = PanelMetrics.cornerRadius
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: background.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        panel.delegate = self
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? close() : show()
    }

    func show() {
        let size = NSSize(width: PanelMetrics.width, height: hostingView.fittingSize.height)
        panel.setFrame(NSRect(origin: origin(for: size), size: size), display: false)
        // makeKey without NSApp.activate: the frontmost app keeps its active state.
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        model.didOpen()
        startMonitoring()
        onVisibilityChange(true)
    }

    func close() {
        guard panel.isVisible else { return }
        stopMonitoring()
        panel.orderOut(nil)
        model.didClose()
        onVisibilityChange(false)
    }

    /// Centered under the status item, kept inside the visible frame of its screen.
    private func origin(for size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first { screen in anchor().map { screen.frame.intersects($0) } ?? false }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        guard let anchor = anchor() else {
            return NSPoint(x: visible.maxX - size.width - 8, y: visible.maxY - size.height - PanelMetrics.gapBelowMenuBar)
        }
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let y = anchor.minY - size.height - PanelMetrics.gapBelowMenuBar
        return NSPoint(x: x, y: y)
    }

    private func startMonitoring() {
        stopMonitoring()
        // Global monitors only see events going to other apps, which is exactly "outside".
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel, event.keyCode == 53 else { return event }
            self.escape()
            return nil
        }
    }

    private func stopMonitoring() {
        [outsideClickMonitor, keyMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        outsideClickMonitor = nil
        keyMonitor = nil
    }

    /// Esc clears the search first, then closes the panel.
    private func escape() {
        if model.clearSearch() { return }
        close()
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
