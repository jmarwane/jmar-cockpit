import AppKit

/// A borderless panel that becomes key without activating Cue,
/// so the frontmost app stays active while typing goes to the search field.
final class CuePanel: NSPanel {
    init() {
        // .nonactivatingPanel only takes full effect when passed at init.
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum PanelMetrics {
    static let width: CGFloat = 340
    static let cornerRadius: CGFloat = 14
    static let gapBelowMenuBar: CGFloat = 4
}
