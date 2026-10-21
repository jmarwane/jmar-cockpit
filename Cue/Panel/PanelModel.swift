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
    /// The reminder form, under the New Reminder row, the add row, or the reminder being changed.
    case reminderForm(UUID)
    /// `Stop process on port 4000 (node, pid 4312)?`
    case stopOnPort(UUID, port: Int, owner: PortOwner)

    var itemID: UUID {
        switch self {
        case .inputs(let id), .confirm(let id, _), .error(let id), .runDetails(let id), .reminderForm(let id), .stopOnPort(let id, _, _): id
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
        didSet {
            guard query != oldValue else { return }
            if !isSettingQuery {
                // Typing replaces whatever a drop or Tab decided.
                addKindOverride = nil
                pendingExecutable = nil
                dropNote = nil
            }
            if query.isEmpty { forceAddRow = false }
            keepSelectionVisible()
        }
    }

    /// The add row's selection ID; it isn't an item.
    static let addRowID = UUID()
    /// The built-in New Reminder row, first in the list.
    static let newReminderRowID = UUID()

    /// The reminder form's text, and the due time a chip picked.
    var reminderText = ""
    var reminderChip: Date?
    /// Which chip was picked, so it stays highlighted while the chips' times move with the clock.
    var reminderChipLabel: String?
    /// The time of the reminder being changed, offered as the `Keep` chip.
    private(set) var reminderKeep: Date?
    /// Set by the + button and by drops: show the add row even when something matches.
    var forceAddRow = false
    /// Set by Tab: the type the user chose instead of the guess.
    var addKindOverride: Classifier.Kind?
    /// A dropped script with a shebang that isn't executable yet.
    private(set) var pendingExecutable: String?
    /// What a drop changed, shown in the add row's subtitle.
    private(set) var dropNote: String?
    var isDropTargeted = false
    private var isSettingQuery = false
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
    /// Opens the editor on a new, unsaved item made from a command (Save… on a Recent row).
    var openEditorNew: (String) -> Void = { _ in }
    /// Opens the View Log window for an item.
    var openLog: (UUID) -> Void = { _ in }

    private var toastTask: Task<Void, Never>?
    /// Where the pointer was at the last selection change; hover only counts once it moves.
    private var pointerAtLastSelection: NSPoint?

    init(app: AppModel) {
        self.app = app
        app.onToast = { [weak self] message in self?.showToast(message) }
    }

    // MARK: Opening and closing

    func didOpen() {
        app.isPanelOpen = true
        pointerAtLastSelection = NSEvent.mouseLocation
        app.reloadIfChanged()
        rowOrder = app.items.map(\.id)
        expansion = nil
        keepSelectionVisible()
        openCount += 1
        app.checkAllServices()
    }

    func didClose() {
        app.isPanelOpen = false
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

    /// Reminders, soonest first; matched on their text while searching.
    var visibleReminders: [Reminder] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return app.reminders }
        return app.reminders.filter { $0.text.localizedCaseInsensitiveContains(needle) }
    }

    /// The New Reminder row shows while the search is empty.
    var showsNewReminderRow: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Commands run once, matching the search too.
    var visibleRecent: [Item] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !addRowVisible else { return app.recent }
        return app.recent.filter { $0.command.localizedCaseInsensitiveContains(needle) }
    }

    var selectedItem: Item? { selection.flatMap(app.item) }

    /// Everything ↑ and ↓ move through, top to bottom.
    var selectableIDs: [UUID] {
        (showsNewReminderRow ? [Self.newReminderRowID] : []) + visibleRows.map(\.id) + (addRowVisible ? [Self.addRowID] : [])
            + visibleReminders.map(\.id) + visibleRecent.map(\.id)
    }

    private func keepSelectionVisible() {
        let ids = selectableIDs
        if let expansion, !ids.contains(expansion.itemID) { self.expansion = nil }
        if let selection, ids.contains(selection) {
            // Typing that leaves no matches moves to the add row.
            if addRowVisible, visibleRows.isEmpty, selection != Self.addRowID { self.selection = Self.addRowID }
            return
        }
        if addRowVisible && visibleRows.isEmpty {
            selection = Self.addRowID
        } else {
            // Start on the first item rather than New Reminder, so ↵ does what the list is for.
            selection = visibleRows.first?.id ?? ids.first
        }
    }

    // MARK: Quick add

    /// Shown when typed text matches nothing, or after + or a drop.
    var addRowVisible: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (forceAddRow || visibleRows.isEmpty)
    }

    var addGuess: Classifier.Guess { Classifier.classify(query, path: app.commandPath) }

    var addKind: Classifier.Kind { addKindOverride ?? addGuess.kind }

    /// The + button: shows the add row even when something matches.
    func showAddRow() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast("Type or paste something to add")
            return
        }
        forceAddRow = true
        selection = Self.addRowID
        expansion = nil
    }

    func cycleAddKind() {
        addKindOverride = addKind.next
    }

    /// ↵ on the add row; ⌘↵ runs a command once without saving. The guess never acts on its own.
    func activateAddRow(runOnce: Bool = false) {
        let text = addGuess.text
        if let path = pendingExecutable {
            if app.makeExecutable(path) {
                pendingExecutable = nil
                dropNote = nil
                showToast("Made executable")
            }
            return
        }
        switch addKind {
        case .link:
            guard let item = app.addLink(text) else { return }
            clearQuery()
            selection = item.id
            showToast("Link added")
        case .command:
            if runOnce {
                app.runOnce(text)
                clearQuery()
                selection = app.recent.last?.id
            } else if let item = app.addCommand(text) {
                clearQuery()
                closePanel()
                openEditor(item.id, true)
            }
        case .reminder:
            let reminder = addGuess.reminder
            if let due = reminder.due {
                app.addReminder(text: reminder.text, due: due)
                clearQuery()
                showToast("Set for \(ReminderBook.clock(due, now: Date()))")
            } else {
                openReminderForm(under: Self.addRowID, text: text, keep: nil)
            }
        }
    }

    // MARK: Reminders

    func openReminderForm(under rowID: UUID, text: String, keep: Date?) {
        reminderText = text
        reminderChip = nil
        reminderChipLabel = nil
        reminderKeep = keep
        selection = rowID
        expansion = .reminderForm(rowID)
    }

    /// The form's due time: a picked chip, else a time typed in the text, else the one being kept.
    var reminderDraftDue: Date? {
        reminderChip ?? ReminderParser.parse(reminderText).due ?? reminderKeep
    }

    func submitReminderForm(_ rowID: UUID) {
        guard let due = reminderDraftDue else {
            showToast("Pick a time")
            return
        }
        let parsed = ReminderParser.parse(reminderText)
        let text = parsed.due != nil && reminderChip == nil ? parsed.text : reminderText.trimmingCharacters(in: .whitespacesAndNewlines)
        if app.reminder(rowID) != nil {
            app.updateReminder(rowID, text: text, due: due)
        } else {
            app.addReminder(text: text, due: due)
        }
        expansion = nil
        if rowID == Self.addRowID { clearQuery() }
        showToast("Set for \(ReminderBook.clock(due, now: Date()))")
    }

    /// A click on a reminder: change it while pending, dismiss it once fired.
    func activateReminder(_ reminder: Reminder) {
        selection = reminder.id
        if let expansion, expansion.itemID != reminder.id { self.expansion = nil }
        switch reminder.state {
        case .pending:
            if expansion == .reminderForm(reminder.id) {
                expansion = nil
            } else {
                openReminderForm(under: reminder.id, text: reminder.text, keep: reminder.due)
            }
        case .fired:
            app.dismissReminder(reminder.id)
        }
    }

    func activateNewReminderRow() {
        if expansion == .reminderForm(Self.newReminderRowID) {
            expansion = nil
        } else {
            openReminderForm(under: Self.newReminderRowID, text: "", keep: nil)
        }
    }

    private func clearQuery() {
        query = ""
        forceAddRow = false
    }

    /// Sets the search text without resetting a drop's or Tab's decisions.
    private func setQuery(_ text: String, kind: Classifier.Kind? = nil, note: String? = nil, executable: String? = nil) {
        isSettingQuery = true
        query = text
        isSettingQuery = false
        addKindOverride = kind
        dropNote = note
        pendingExecutable = executable
        forceAddRow = true
        expansion = nil
        selection = Self.addRowID
    }

    /// Something dropped on the panel or the icon becomes the add row.
    func receiveDrop(fileURLs: [URL], text: String?) {
        if let url = fileURLs.first {
            if url.isFileURL {
                switch DropAction.forFile(at: url.path) {
                case .command(let command):
                    setQuery(command, kind: .command)
                case .needsExecutable(let path, let command):
                    setQuery(command, kind: .command, note: "Not executable yet · ↵ makes it executable", executable: path)
                case .viaInterpreter(let command, let interpreter):
                    setQuery(command, kind: .command, note: "Runs with \(interpreter), since the file isn't executable")
                case .link(let path):
                    setQuery(path, kind: .link)
                }
            } else {
                setQuery(url.absoluteString)
            }
        } else if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setQuery(text)
        }
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
        case 36, 76:  // ↵, ⌘↵
            if modifiers.contains(.command) {
                guard selection == Self.addRowID, addKind == .command else { return false }
                activateAddRow(runOnce: true)
                return true
            }
            returnKey()
            return true
        case 48:  // Tab switches the add row's type
            guard addRowVisible, selection == Self.addRowID, modifiers.isEmpty else { return false }
            cycleAddKind()
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
    func hover(_ item: Item) { hover(id: item.id) }

    func hover(id: UUID) {
        let pointer = NSEvent.mouseLocation
        guard pointer != pointerAtLastSelection, selection != id, expansion == nil else { return }
        pointerAtLastSelection = pointer
        selection = id
    }

    /// The footer's label for New Reminder and reminder rows, or nil for other rows.
    var reminderFooterLabel: String? {
        if let expansion, case .reminderForm = expansion, expansion.itemID == selection { return "Set" }
        if selection == Self.newReminderRowID { return "New Reminder" }
        guard let selection, let reminder = app.reminder(selection) else { return nil }
        return reminder.state == .pending ? "Change" : "Dismiss"
    }

    func moveSelection(by offset: Int) {
        pointerAtLastSelection = NSEvent.mouseLocation
        let ids = selectableIDs
        guard !ids.isEmpty else { return }
        let current = ids.firstIndex { $0 == selection } ?? (offset > 0 ? -1 : ids.count)
        let next = min(max(current + offset, 0), ids.count - 1)
        if ids[next] != selection {
            selection = ids[next]
            expansion = nil
        }
    }

    func returnKey() {
        if let expansion, expansion.itemID == selection {
            submit(expansion)
        } else if selection == Self.addRowID {
            activateAddRow()
        } else if selection == Self.newReminderRowID {
            activateNewReminderRow()
        } else if let selection, let reminder = app.reminder(selection) {
            activateReminder(reminder)
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
            confirmStopOnPort(item, port: port)
        case .edit:
            edit(item)
        case .showError:
            expansion = expansion == .error(item.id) ? nil : .error(item.id)
        case .showRunDetails:
            expansion = expansion == .runDetails(item.id) ? nil : .runDetails(item.id)
        case .check:
            app.check(item.id)
        case .openEditorAtTestRun:
            closePanel()
            openEditor(item.id, true)
        case .runInTerminal:
            expansion = nil
            app.runInTerminal(item, inputs: item.currentInputValues)
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
        if case .reminderForm(let rowID) = expansion {
            submitReminderForm(rowID)
            return
        }
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
        case .stopOnPort(_, _, let owner):
            self.expansion = nil
            app.stopProcess(item.id, pid: owner.pid)
        case .runDetails, .reminderForm:
            break
        }
    }

    /// Looks up who listens on the port, then asks: `Stop process on port 4000 (node, pid 4312)?`
    func confirmStopOnPort(_ item: Item, port: Int) {
        if case .stopOnPort(item.id, _, _)? = expansion {
            expansion = nil
            return
        }
        Task {
            guard let owner = await PortOwner.lookup(port: port).first else {
                showToast("Nothing is listening on port \(port)")
                app.check(item.id)
                return
            }
            guard selection == item.id else { return }
            expansion = .stopOnPort(item.id, port: port, owner: owner)
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
        if let item, app.isRecent(item.id) { return }
        closePanel()
        openEditor(item?.id, item.map { !$0.isTested } ?? false)
    }

    // MARK: ⌘K

    func presentActions() {
        if selection == Self.addRowID, addRowVisible {
            showActionsMenu(addRowActions())
            return
        }
        if let selection, let reminder = app.reminder(selection) {
            var actions = [MenuAction(title: reminder.state == .pending ? "Change…" : "Dismiss", keyEquivalent: "\r") { [weak self] in
                self?.activateReminder(reminder)
            }]
            if reminder.state == .pending {
                actions.append(MenuAction(title: "Cancel Reminder") { [weak self] in self?.app.dismissReminder(reminder.id) })
            } else {
                actions.append(MenuAction(title: "Snooze 10 min") { [weak self] in self?.app.snoozeReminder(reminder.id) })
            }
            showActionsMenu(actions)
            return
        }
        guard let item = selectedItem else { return }
        showActionsMenu(actions(for: item))
    }

    private func addRowActions() -> [MenuAction] {
        var actions = [MenuAction(title: addRowFooterLabel, keyEquivalent: "\r") { [weak self] in self?.activateAddRow() }]
        if addKind == .command, pendingExecutable == nil {
            actions.append(MenuAction(title: "Run Once", keyEquivalent: "\r", modifiers: .command) { [weak self] in
                self?.activateAddRow(runOnce: true)
            })
        }
        for kind in Classifier.Kind.allCases where kind != addKind {
            actions.append(MenuAction(title: "Treat as \(kind.rawValue)") { [weak self] in self?.addKindOverride = kind })
        }
        return actions
    }

    /// The footer's label for the add row.
    var addRowFooterLabel: String {
        if pendingExecutable != nil { return "Make Executable" }
        switch addKind {
        case .link: return "Add Link"
        case .command: return "Save & Edit"
        case .reminder: return addGuess.reminder.due == nil ? "Pick a Time" : "Set Reminder"
        }
    }

    private static func isOnOrFailed(_ state: ServiceState?) -> Bool {
        switch state {
        case .on?, .failed?: true
        default: false
        }
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
        if app.hasLog(item.id) {
            actions.append(MenuAction(title: "View Log") { [weak self] in
                guard let self else { return }
                closePanel()
                openLog(item.id)
            })
        }
        if let details = app.errorDetails(for: item.id) {
            actions.append(MenuAction(title: "Copy Error Details") { [weak self] in
                self?.app.copy(details)
                self?.showToast("Copied")
            })
        }
        if app.isRecent(item.id) {
            actions.append(MenuAction(title: "Save…") { [weak self] in
                guard let self else { return }
                closePanel()
                openEditorNew(item.command)
            })
            if app.tasks[item.id]?.isRunning != true {
                actions.append(MenuAction(title: "Dismiss") { [weak self] in self?.app.dismissRecent(item.id) })
            }
        }
        if item.runsCommands, presentation.primary != .runInTerminal {
            actions.append(MenuAction(title: "Run in Terminal") { [weak self] in
                self?.app.runInTerminal(item, inputs: item.currentInputValues)
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
        // A port service answering through a process Cue doesn't own: offer to stop that process.
        if item.kind == .service, service?.ownsProcess == false, case .port(let text) = item.runningWhen,
           let port = try? Placeholders.port(text, values: LaunchSpec.placeholderValues(for: item, inputs: item.currentInputValues)),
           presentation.primary != .stopProcessOnPort(port), Self.isOnOrFailed(service?.state) {
            actions.append(MenuAction(title: "Stop Process on Port \(port)…") { [weak self] in self?.confirmStopOnPort(item, port: port) })
        }
        if case .failed(let failure)? = service?.state, failure.canForceStop {
            actions.append(MenuAction(title: "Force Stop") { [weak self] in self?.app.forceStop(item.id) })
        } else if case .stopping? = service?.state, service?.ownsProcess == true {
            actions.append(MenuAction(title: "Force Stop") { [weak self] in self?.app.forceStop(item.id) })
        }
        if !app.isRecent(item.id) {
            actions.append(.separator)
            actions.append(MenuAction(title: "Edit…", keyEquivalent: "e", modifiers: .command) { [weak self] in self?.edit(item) })
        }
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
            case "return": returnKey()
            case "esc": escape()
            default: break
            }
        case "type":
            query = argument
        case "click":
            if let item = (rows + app.recent).first(where: { $0.name == argument }) { activate(item) }
            if let reminder = app.reminders.first(where: { $0.text == argument }) { activateReminder(reminder) }
            if argument == "New Reminder" { activateNewReminderRow() }
        case "remind":
            reminderText = argument
        case "chip":
            if let index = Int(argument) {
                let chip = ReminderBook.chips(now: Date())[index]
                reminderChip = chip.due
                reminderChipLabel = chip.label
            }
        case "tab":
            if addRowVisible { cycleAddKind() }
        case "plus":
            showAddRow()
        case "runonce":
            if selection == Self.addRowID { activateAddRow(runOnce: true) }
        case "drop":
            receiveDrop(fileURLs: [URL(fileURLWithPath: argument)], text: nil)
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
        let selected = selection == Self.addRowID ? "add row (\(addKind.rawValue))" : (selectedItem?.name ?? "-")
        appLog.notice("debug \(command, privacy: .public) → selection=\(selected, privacy: .public) expansion=\(String(describing: self.expansion), privacy: .public)")
    }
}
#endif
