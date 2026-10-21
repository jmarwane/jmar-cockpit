import AppKit
import os
import SwiftUI

let panelLog = Logger(subsystem: "com.jmarwane.cue", category: "panel")

/// Shows the panel under the status item and closes it on Esc, a click outside, or the hotkey.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let model: PanelModel

    /// The status item's frame on screen.
    var anchor: () -> NSRect? = { nil }
    var onVisibilityChange: (Bool) -> Void = { _ in }

    private let panel = CuePanel()
    private let hostingView: PanelHostingView
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    /// While the ⌘K menu tracks, the panel isn't key; that mustn't close it.
    private var isShowingMenu = false

    init(model: PanelModel) {
        self.model = model
        hostingView = PanelHostingView(rootView: PanelRootView(model: model))
        super.init()
        model.closePanel = { [weak self] in self?.close(reason: "model") }
        model.showActionsMenu = { [weak self] actions in self?.showMenu(actions) }
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.onIntrinsicSizeChange = { [weak self] in self?.fitToContent() }

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
        panelLog.notice("toggle visible=\(self.isVisible)")
        isVisible ? close(reason: "toggle") : show()
    }

    func show() {
        let size = contentSize
        panel.setFrame(NSRect(origin: origin(for: size), size: size), display: false)
        // makeKey without NSApp.activate: the frontmost app keeps its active state.
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        panelLog.notice("show frame=\(NSStringFromRect(self.panel.frame), privacy: .public) visible=\(self.panel.isVisible) key=\(self.panel.isKeyWindow) anchor=\(String(describing: self.anchor()), privacy: .public) appActive=\(NSApp.isActive) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-", privacy: .public)")
        model.didOpen()
        startMonitoring()
        onVisibilityChange(true)
    }

    func close(reason: String = "") {
        panelLog.notice("close reason=\(reason, privacy: .public) visible=\(self.panel.isVisible)")
        guard panel.isVisible else { return }
        stopMonitoring()
        panel.orderOut(nil)
        model.didClose()
        onVisibilityChange(false)
    }

    private var contentSize: NSSize {
        NSSize(width: PanelMetrics.width, height: max(hostingView.fittingSize.height, 1))
    }

    /// Debug aid: renders the panel's content view into a PNG at `path`.
    func writeSnapshot(to path: String) {
        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = rep.representation(using: .png, properties: [:])
        try? data?.write(to: URL(fileURLWithPath: path))
        panelLog.notice("snapshot \(path, privacy: .public) key=\(self.panel.isKeyWindow) appActive=\(NSApp.isActive) firstResponder=\(String(describing: self.panel.firstResponder), privacy: .public)")
    }

    /// Follows the SwiftUI content's height, keeping the top edge under the menu bar.
    private func fitToContent() {
        guard panel.isVisible else { return }
        let size = contentSize
        guard size.height != panel.frame.height else { return }
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
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
            MainActor.assumeIsolated { self?.close(reason: "outside click") }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let handled = MainActor.assumeIsolated { self.model.handleKeyDown(event) }
            return handled ? nil : event
        }
    }

    private func stopMonitoring() {
        [outsideClickMonitor, keyMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        outsideClickMonitor = nil
        keyMonitor = nil
    }

    // MARK: ⌘K

    private func showMenu(_ actions: [MenuAction]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var handlers: [() -> Void] = []
        for action in actions {
            if action.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: action.title, action: #selector(menuItemChosen(_:)), keyEquivalent: action.keyEquivalent)
            item.keyEquivalentModifierMask = action.modifiers
            item.target = self
            item.tag = handlers.count
            handlers.append(action.perform)
            menu.addItem(item)
        }
        menuHandlers = handlers
        guard let view = panel.contentView else { return }
        // Opens up from the footer's right edge, where "Actions ⌘K" sits.
        let point = NSPoint(x: view.bounds.maxX - 12, y: Metrics.footerHeight - 6)
        isShowingMenu = true
        panelLog.notice("actions menu: \(actions.map(\.title).joined(separator: " | "), privacy: .public)")
        menu.popUp(positioning: nil, at: point, in: view)
        isShowingMenu = false
        menuHandlers = []
        if panel.isVisible { panel.makeKey() }
        pendingMenuAction?()
        pendingMenuAction = nil
    }

    private var menuHandlers: [() -> Void] = []
    private var pendingMenuAction: (() -> Void)?

    @objc private func menuItemChosen(_ sender: NSMenuItem) {
        guard menuHandlers.indices.contains(sender.tag) else { return }
        // Run after tracking ends, so actions that close the panel do so cleanly.
        pendingMenuAction = menuHandlers[sender.tag]
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        guard !isShowingMenu else { return }
        close(reason: "resign key")
    }
}

/// Reports when the SwiftUI content's size changes, so the panel can follow it.
final class PanelHostingView: NSHostingView<PanelRootView> {
    var onIntrinsicSizeChange: () -> Void = {}

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onIntrinsicSizeChange() }
    }
}
