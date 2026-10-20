import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Toggles the panel. Default ⌃⌥Space.
    static let togglePanel = Self("togglePanel", initial: .init(.space, modifiers: [.control, .option]))
}
