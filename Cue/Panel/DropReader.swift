import AppKit
import UniformTypeIdentifiers

/// Reads file URLs, web URLs or text from dropped item providers, then calls back on the main actor.
enum DropReader {
    static func read(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL], String?) -> Void) {
        guard let provider = providers.first else { return }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                Task { @MainActor in completion(url.map { [$0] } ?? [], nil) }
            }
        } else if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                Task { @MainActor in completion(url.map { [$0] } ?? [], nil) }
            }
        } else if provider.canLoadObject(ofClass: String.self) {
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                Task { @MainActor in completion([], text) }
            }
        }
    }

    /// The same, from an AppKit drag (the menu-bar icon).
    static func read(_ pasteboard: NSPasteboard) -> ([URL], String?) {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            return (urls, nil)
        }
        return ([], pasteboard.string(forType: .string))
    }
}
