import AppKit

/// The menu-bar item. Clicking it toggles the panel.
@MainActor
final class StatusItemController: NSObject {
    private let item: NSStatusItem
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = item.button {
            button.image = MenuBarIcon.image(for: .idle)
            button.setAccessibilityLabel("Cue")
            button.target = self
            button.action = #selector(clicked)
        }
    }

    /// The button's frame in screen coordinates, used to place the panel below it.
    var buttonFrameOnScreen: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func setIcon(_ state: MenuBarIcon.State) {
        item.button?.image = MenuBarIcon.image(for: state)
        let label = switch state {
        case .idle: "Cue"
        case .somethingOn: "Cue, something running"
        case .needsAttention: "Cue, needs attention"
        }
        item.button?.setAccessibilityLabel(label)
    }

    func setHighlighted(_ highlighted: Bool) {
        item.button?.highlight(highlighted)
    }

    @objc private func clicked() { onClick() }
}

/// The monochrome template icon: two dots beside two lines.
enum MenuBarIcon {
    enum State { case idle, somethingOn, needsAttention }

    static func image(for state: State) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            let dotX: CGFloat = 5, topY: CGFloat = 5.5, bottomY: CGFloat = 12.5, radius: CGFloat = 2.25

            let top = NSBezierPath(ovalIn: NSRect(x: dotX - radius, y: topY - radius, width: radius * 2, height: radius * 2))
            if state == .idle {
                top.lineWidth = 1.4
                top.stroke()
            } else {
                top.fill()
            }

            if state == .needsAttention {
                NSBezierPath(roundedRect: NSRect(x: dotX - 0.8, y: bottomY - 3.6, width: 1.6, height: 4.4), xRadius: 0.8, yRadius: 0.8).fill()
                NSBezierPath(ovalIn: NSRect(x: dotX - 0.9, y: bottomY + 1.6, width: 1.8, height: 1.8)).fill()
            } else {
                let bottom = NSBezierPath(ovalIn: NSRect(x: dotX - radius, y: bottomY - radius, width: radius * 2, height: radius * 2))
                bottom.lineWidth = 1.4
                bottom.stroke()
            }

            for y in [topY, bottomY] {
                let line = NSBezierPath()
                line.move(to: NSPoint(x: 10, y: y))
                line.line(to: NSPoint(x: 16, y: y))
                line.lineWidth = 1.5
                line.lineCapStyle = .round
                line.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
