import Observation

@MainActor @Observable
final class PanelModel {
    var query = ""

    /// Changes every time the panel opens, so the view can move focus to the search field.
    private(set) var openCount = 0

    func didOpen() { openCount += 1 }

    func didClose() {}

    /// Clears the search. Returns false if it was already empty.
    func clearSearch() -> Bool {
        guard !query.isEmpty else { return false }
        query = ""
        return true
    }
}
