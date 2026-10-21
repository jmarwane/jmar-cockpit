import AppKit
import CueCore
import Observation

/// What's open under a row. Opens under its row and pushes down only the rows below it.
enum Expansion: Equatable {
    /// Inputs to fill before a start or run.
    case inputs(UUID)
    /// The final command and input values, before running an item that asks first.
    case confirm(UUID, inputs: [String: String])
    case error(UUID)
    case runDetails(UUID)

    var itemID: UUID {
        switch self {
        case .inputs(let id), .confirm(let id, _), .error(let id), .runDetails(let id): id
        }
    }
}

/// One entry of the ⌘K menu.
struct MenuAction {
    var title: String
    var keyEquivalent: String = ""
    var modifiers: NSEvent.ModifierFlags = []
    var isSeparator = false
    var perform: () -> Void = {}

    @MainActor static let separator = MenuAction(title: "", isSeparator: true)
}

@MainActor @Observable
final class PanelModel {
    let app: AppModel

    var query = "" {
        didSet { if query != oldValue { keepSelectionVisible() } }
    }
    var selection: UUID?
    var expansion: Expansion?
    /// Values typed into the inputs form, by input name.
    var inputDrafts: [String: String] = [:]
    private(set) var toast: String?

    /// Changes every time the panel opens, so the view can move focus to the search field.
    private(set) var openCount = 0
    /// Row order frozen while the panel is open: rows never move; new items go at the end.
    private(set) var rowOrder: [UUID] = []

    /// Hooks the controller provides.
    var closePanel: () -> Void = {}
    /// Opens the editor on an item; `atTestRun` for untested items.
    var openEditor: (UUID?, _ atTestRun: Bool) -> Void = { _, _ in }
    var showActionsMenu: ([MenuAction]) -> Void = { _ in }

    private var toastTask: Task<Void, Never>?
    /// Where the pointer was at the last selection change; hover only counts once it moves.
    private var pointerAtLastSelection: NSPoint?

    init(app: AppModel) {
        self.app = app
        app.onToast = { [weak self] message in self?.showToast(message) }
    }

    // MARK: Opening and closing

    func didOpen() {
        pointerAtLastSelection = NSEvent.mouseLocation
        app.reloadIfChanged()
        rowOrder = app.items.map(\.id)
        expansion = nil
        keepSelectionVisible()
        openCount += 1
        app.checkAllServices()
    }

    func didClose() {
        expansion = nil
    }

    /// Items in the frozen order, then any added while open.
    var rows: [Item] {
        var ordered = rowOrder.compactMap(app.item)
        let known = Set(rowOrder)
        ordered += app.items.filter { !known.contains($0.id) }
        return ordered
    }

    /// Rows matching the search: names and command text, case-insensitive. Never reordered.
    var visibleRows: [Item] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        return rows.filter { item in
            item.name.localizedCaseInsensitiveContains(needle)
                || (item.runsCommands && item.command.localizedCaseInsensitiveContains(needle))
                || (item.kind == .link && item.target.localizedCaseInsensitiveContains(needle))
        }
    }

    var selectedItem: Item? { selection.flatMap(app.item) }

    private func keepSelectionVisible() {
        let visible = visibleRows
        if let selection, visible.contains(where: { $0.id == selection }) { return }
        selection = visible.first?.id
        if let expansion, !visible.contains(where: { $0.id == expansion.itemID }) { self.expansion = nil }
    }

    // MARK: Toasts

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: Metrics.toastDuration)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Keyboard

    /// Handles a key the panel should own. Returns false to let the event through (typing).
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch event.keyCode {
        case 53:  // Esc
            escape()
            return true
        case 125:  // ↓
            moveSelection(by: 1)
            return true
        case 126:  // ↑
            moveSelection(by: -1)
            return true
        case 36, 76:  // ↵
            if modifiers.contains(.command) { return false }
            returnKey()
            return true
        default:
            break
        }
        if modifiers == .command {
            switch key {
            case "k":
                presentActions()
                return true
            case "e":
                edit(selectedItem)
                return true
            case ",":
                showToast("Settings aren't built yet")
                return true
            default:
                return false
            }
        }
        return false
    }

    /// Close an expansion, then clear the search, then close the panel.
    func escape() {
        if expansion != nil {
            expansion = nil
        } else if !query.isEmpty {
            query = ""
        } else {
            closePanel()
        }
    }

    /// Hovering selects, but only when the pointer really moved: a resting pointer over a
    /// re-rendered row mustn't pull the selection back from the arrow keys.
    func hover(_ item: Item) {
        let pointer = NSEvent.mouseLocation
        guard pointer != pointerAtLastSelection, selection != item.id, expansion == nil else { return }
        pointerAtLastSelection = pointer
        selection = item.id
    }

    func moveSelection(by offset: Int) {
        pointerAtLastSelection = NSEvent.mouseLocation
        let visible = visibleRows
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.id == selection } ?? (offset > 0 ? -1 : visible.count)
        let next = min(max(current + offset, 0), visible.count - 1)
        if visible[next].id != selection {
            selection = visible[next].id
            expansion = nil
        }
    }

    private func returnKey() {
        if let expansion, expansion.itemID == selection {
            submit(expansion)
        } else if let item = selectedItem {
            activate(item)
        }
    }

    // MARK: Clicks

    /// A click anywhere on a row, or ↵: the footer's action.
    func activate(_ item: Item) {
        selection = item.id
        // An expansion belongs to its row; acting on another row closes it, so ↵ can't reach the wrong item.
        if let expansion, expansion.itemID != item.id { self.expansion = nil }
        let presentation = app.presentation(for: item)
        switch presentation.primary {
        case .start, .run:
            begin(item)
        case .stop:
            expansion = nil
            app.stop(item.id)
        case .stopProcessOnPort(let port):
            showToast("Can't stop port \(port) yet")
        case .showError:
            expansion = expansion == .error(item.id) ? nil : .error(item.id)
        case .showRunDetails:
            expansion = expansion == .runDetails(item.id) ? nil : .runDetails(item.id)
        case .check:
            app.check(item.id)
        case .openEditorAtTestRun:
            closePanel()
            openEditor(item.id, true)
        case .open:
            if app.open(item.target) {
                closePanel()
            } else {
                showToast("Can't open \(item.target)")
            }
        case .none:
            break
        }
    }

    /// Start or run: inputs form first if it has inputs, then confirmation if it asks first.
    private func begin(_ item: Item, inputs: [String: String]? = nil) {
        if inputs == nil, !item.inputs.isEmpty {
            inputDrafts = item.currentInputValues
            expansion = .inputs(item.id)
            return
        }
        let values = inputs ?? item.currentInputValues
        if item.confirmBeforeRunning, expansion != .confirm(item.id, inputs: values) {
            expansion = .confirm(item.id, inputs: values)
            return
        }
        expansion = nil
        if item.kind == .service {
            app.start(item.id, inputs: values)
        } else {
            app.run(item.id, inputs: values)
        }
    }

    /// ↵ inside an expansion.
    func submit(_ expansion: Expansion) {
        guard let item = app.item(expansion.itemID) else { return }
        switch expansion {
        case .inputs:
            let values = Dictionary(item.inputs.map { ($0.name, inputDrafts[$0.name] ?? $0.defaultValue) }, uniquingKeysWith: { _, last in last })
            if item.confirmBeforeRunning {
                self.expansion = .confirm(item.id, inputs: values)
            } else {
                begin(item, inputs: values)
            }
        case .confirm(_, let values):
            begin(item, inputs: values)
        case .error:
            retry(item)
        case .runDetails:
            break
        }
    }

    func retry(_ item: Item) {
        expansion = nil
        begin(item, inputs: item.inputs.isEmpty ? nil : item.currentInputValues)
    }

    func cancelRun(_ item: Item) {
        app.cancel(item.id)
        expansion = nil
    }

    /// ⌘E: the editor on the selected item, or on the first one when nothing is selected.
    func edit(_ item: Item?) {
        closePanel()
        openEditor(item?.id, item.map { !$0.isTested } ?? false)
    }

    // MARK: ⌘K

    func presentActions() {
        guard let item = selectedItem else { return }
        showActionsMenu(actions(for: item))
    }

    func actions(for item: Item) -> [MenuAction] {
        let presentation = app.presentation(for: item)
        var actions: [MenuAction] = []
        if presentation.primary != .none {
            actions.append(MenuAction(title: presentation.primary.label, keyEquivalent: "\r") { [weak self] in self?.activate(item) })
        }
        let service = app.services[item.id]
        if item.kind == .service, service?.state.isOn == true, presentation.primary == .stop {
            actions.append(MenuAction(title: "Restart") { [weak self] in self?.app.restart(item.id) })
        }
        if item.kind == .service, let address = app.address(of: item) {
            actions.append(MenuAction(title: "Open \(address)") { [weak self] in
                guard let self else { return }
                if app.open(address) { closePanel() } else { showToast("Can't open \(address)") }
            })
        }
        if let details = app.errorDetails(for: item.id) {
            actions.append(MenuAction(title: "Copy Error Details") { [weak self] in
                self?.app.copy(details)
                self?.showToast("Copied")
            })
        }
        if item.runsCommands {
            actions.append(MenuAction(title: "Copy Command") { [weak self] in
                self?.app.copy(item.command)
                self?.showToast("Copied")
            })
        } else {
            actions.append(MenuAction(title: "Copy Link") { [weak self] in
                self?.app.copy(item.target)
                self?.showToast("Copied")
            })
        }
        if case .failed(let failure)? = service?.state, failure.canForceStop {
            actions.append(MenuAction(title: "Force Stop") { [weak self] in self?.app.forceStop(item.id) })
        } else if case .stopping? = service?.state, service?.ownsProcess == true {
            actions.append(MenuAction(title: "Force Stop") { [weak self] in self?.app.forceStop(item.id) })
        }
        actions.append(.separator)
        actions.append(MenuAction(title: "Edit…", keyEquivalent: "e", modifiers: .command) { [weak self] in self?.edit(item) })
        return actions
    }
}

#if DEBUG
extension PanelModel {
    /// Debug aid: drives the panel through the same methods keys and clicks use, for testing from a shell.
    /// `key:down|up|return|esc`, `type:<text>`, `click:<row name>`, `select:<row name>`, `actions` (logs ⌘K titles).
    func debugCommand(_ command: String) {
        let (verb, argument) = command.firstIndex(of: ":").map {
            (String(command[..<$0]), String(command[command.index(after: $0)...]))
        } ?? (command, "")
        switch verb {
        case "key":
            switch argument {
            case "down": moveSelection(by: 1)
            case "up": moveSelection(by: -1)
            case "return":
                if let expansion { submit(expansion) } else if let item = selectedItem { activate(item) }
            case "esc": escape()
            default: break
            }
        case "type":
            query = argument
        case "click":
            if let item = rows.first(where: { $0.name == argument }) { activate(item) }
        case "select":
            if let item = rows.first(where: { $0.name == argument }) { selection = item.id }
        case "actions":
            if let item = selectedItem {
                let titles = actions(for: item).map { $0.isSeparator ? "—" : $0.title }
                appLog.notice("actions: \(titles.joined(separator: " | "), privacy: .public)")
            }
        default:
            break
        }
        appLog.notice("debug \(command, privacy: .public) → selection=\(self.selectedItem?.name ?? "-", privacy: .public) expansion=\(String(describing: self.expansion), privacy: .public)")
    }
}
#endif
