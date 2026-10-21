import AppKit
import CueCore
import Observation

/// The editor's drafts. Each item keeps its own draft until it's saved or reverted,
/// so switching items in the sidebar never loses typing.
@MainActor @Observable
final class EditorModel {
    let app: AppModel

    var selectedID: UUID?
    private(set) var drafts: [UUID: Item] = [:]
    /// Drafts not yet in the library.
    private(set) var newIDs: [UUID] = []
    /// Secret values typed in this session, by item and key. Never written to items.json.
    var secretDrafts: [UUID: [String: String]] = [:]
    /// Input values used for Test Run, by item.
    var testInputs: [UUID: [String: String]] = [:]

    private(set) var testSteps: [UUID: [TestStep]] = [:]
    private(set) var testRunning: UUID?
    private(set) var testPassed: [UUID: Bool] = [:]
    /// Set when the editor opened "at Test Run"; the footer button is emphasized.
    var emphasizeTestRun = false
    var showAdvanced = false
    var message: String?

    /// The last name and icon filled in automatically, so typing a command updates them only until the user changes them.
    private var autoName: [UUID: String] = [:]
    private var autoIcon: [UUID: String] = [:]

    init(app: AppModel) {
        self.app = app
    }

    // MARK: Sidebar

    /// Library items in order, then new drafts.
    var sidebarItems: [Item] {
        app.items.map { drafts[$0.id] ?? $0 } + newIDs.compactMap { drafts[$0] }
    }

    func isDirty(_ id: UUID) -> Bool {
        if newIDs.contains(id) { return true }
        if let values = secretDrafts[id], !values.isEmpty { return true }
        guard let draft = drafts[id], let saved = app.item(id) else { return false }
        return draft != saved
    }

    func select(_ id: UUID?) {
        selectedID = id
        message = nil
    }

    // MARK: Drafts

    var draft: Item? {
        get { selectedID.flatMap { drafts[$0] ?? app.item($0) } }
        set {
            guard let newValue else { return }
            update(newValue)
        }
    }

    private func update(_ value: Item) {
        var value = value
        let before = drafts[value.id] ?? app.item(value.id)
        if let before, before.command != value.command || before.workingDirectory != value.workingDirectory {
            autofill(&value)
        }
        if let before, before.kind != value.kind {
            if value.icon == Item.defaultIcon(for: before.kind) || value.icon == autoIcon[value.id] {
                value.icon = value.kind == .link ? "link" : ItemSuggestions.icon(for: value.command, kind: value.kind)
                autoIcon[value.id] = value.icon
            }
        }
        drafts[value.id] = value
        message = nil
    }

    /// Name and icon follow the command until the user picks their own.
    private func autofill(_ item: inout Item) {
        guard item.kind != .link else { return }
        let nameIsAuto = item.name.isEmpty || item.name == "New Item" || item.name == autoName[item.id]
        if nameIsAuto {
            let suggested = ItemSuggestions.name(for: item.command, folder: item.workingDirectory)
            item.name = suggested
            autoName[item.id] = suggested
            item.tint = ItemSuggestions.tint(for: suggested)
        }
        let iconIsAuto = item.icon == Item.defaultIcon(for: item.kind) || item.icon == autoIcon[item.id]
        if iconIsAuto {
            item.icon = ItemSuggestions.icon(for: item.command, kind: item.kind)
            autoIcon[item.id] = item.icon
        }
    }

    /// Adds a new, unsaved task and selects it.
    func addNew(command: String = "", kind: ItemKind? = nil) {
        let kind = kind ?? (command.isEmpty ? .task : ItemSuggestions.kind(for: command))
        var item = Item(kind: kind, name: command.isEmpty ? "New Item" : "", command: command)
        if !command.isEmpty { autofill(&item) }
        autoName[item.id] = item.name
        autoIcon[item.id] = item.icon
        drafts[item.id] = item
        newIDs.append(item.id)
        select(item.id)
    }

    func revert(_ id: UUID) {
        drafts[id] = nil
        secretDrafts[id] = nil
        if let index = newIDs.firstIndex(of: id) {
            newIDs.remove(at: index)
            if selectedID == id { select(sidebarItems.first?.id) }
        }
        message = nil
    }

    func remove(_ id: UUID) {
        if newIDs.contains(id) {
            revert(id)
            return
        }
        do {
            try app.removeItem(id)
            drafts[id] = nil
            secretDrafts[id] = nil
            testSteps[id] = nil
            if selectedID == id { select(sidebarItems.first?.id) }
        } catch {
            message = error.description
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        var ids = sidebarItems.map(\.id).filter { !newIDs.contains($0) }
        let moving = source.compactMap { $0 < ids.count ? ids[$0] : nil }
        guard !moving.isEmpty else { return }
        ids.move(fromOffsets: IndexSet(source.filter { $0 < ids.count }), toOffset: min(destination, ids.count))
        app.reorder(ids)
    }

    // MARK: Save

    /// Problems that block saving, or nil.
    func validationError(_ item: Item) -> String? {
        if item.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give it a name" }
        switch item.kind {
        case .link:
            if LinkTarget.url(for: item.target) == nil { return "Enter a URL or a path" }
        case .task, .service:
            if item.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a command" }
            if item.kind == .service {
                switch item.runningWhen {
                case .port(let text):
                    let values = LaunchSpec.placeholderValues(for: item, inputs: item.currentInputValues)
                    if text.contains("$") { break }
                    if (try? Placeholders.port(text, values: values)) == nil { return "Port must be a number from 1 to 65535" }
                case .statusCommand(let command):
                    if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a status command" }
                case .process:
                    break
                }
                if case .command(let command) = item.stopBy, command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return "Enter a stop command"
                }
            }
            let names = item.inputs.map(\.name)
            if names.contains(where: { !ProgramResolver.isVariableName($0) }) { return "Input names use letters, digits and _" }
            if Set(names).count != names.count { return "Two inputs have the same name" }
            let keys = item.environment.map(\.key).filter { !$0.isEmpty }
            if keys.contains(where: { !ProgramResolver.isVariableName($0) }) { return "Environment keys use letters, digits and _" }
            for variable in item.environment where variable.isSecret && !variable.key.isEmpty {
                let typed = secretDrafts[item.id]?[variable.key]
                if typed == nil && app.secrets.secret(itemID: item.id, key: variable.key) == nil {
                    return "Enter a value for the secret \(variable.key)"
                }
            }
        }
        return nil
    }

    func save(_ id: UUID) {
        guard var item = drafts[id] ?? app.item(id) else { return }
        if let error = validationError(item) {
            message = error
            return
        }
        item.environment.removeAll { $0.key.isEmpty }
        item.inputs.removeAll { $0.name.isEmpty }
        // Ask before running switches on when a saved command turns risky; turning it off again sticks.
        let previous = app.item(id)
        if item.runsCommands, previous?.command != item.command, CommandTraits.isRisky(item.command) {
            item.confirmBeforeRunning = true
        }
        // A test that passed for exactly this setup still counts.
        if testPassed[id] == true, let passed = passedSignature[id], passed == item.signature {
            item.testedSignature = passed
        }
        do {
            try app.saveItem(item, secretValues: secretDrafts[id] ?? [:])
            drafts[id] = nil
            secretDrafts[id] = nil
            newIDs.removeAll { $0 == id }
            message = item.isTested ? "Saved" : "Saved · not yet tested"
        } catch {
            message = error.description
        }
    }

    // MARK: Test Run

    private var passedSignature: [UUID: String] = [:]

    func testRun(_ id: UUID) {
        guard testRunning == nil, var item = drafts[id] ?? app.item(id) else { return }
        item.environment.removeAll { $0.key.isEmpty }
        if let error = validationError(item) {
            message = error
            return
        }
        if app.isActive(id) {
            message = "Stop \(item.name) before testing it"
            return
        }
        testRunning = id
        testSteps[id] = []
        testPassed[id] = nil
        emphasizeTestRun = false
        message = nil

        let inputs = Dictionary(item.inputs.map { ($0.name, testInputs[id]?[$0.name] ?? item.currentInputValues[$0.name] ?? $0.defaultValue) },
                                uniquingKeysWith: { _, last in last })
        let secrets = OverlaySecretStore(drafts: secretDrafts[id] ?? [:], itemID: id, base: app.secrets)
        let environment = app.environment?.variables ?? ProcessInfo.processInfo.environment
        let signature = item.signature
        Task {
            let passed = await TestRunner.run(item, inputs: inputs, environment: environment, secrets: secrets) { step in
                Task { @MainActor in self.testSteps[id, default: []].append(step) }
            }
            // Let the last reported steps land first.
            try? await Task.sleep(for: .milliseconds(50))
            testPassed[id] = passed
            testRunning = nil
            if passed {
                passedSignature[id] = signature
                drafts[id]?.testedSignature = signature
                app.markTested(id, signature: signature)
            }
        }
    }

    /// The pill for the header: Unsaved changes, Not yet tested, or Test passed.
    func pills(for item: Item) -> [String] {
        var pills: [String] = []
        if isDirty(item.id) { pills.append("Unsaved changes") }
        if item.kind != .link {
            if item.testedSignature == item.signature || testPassed[item.id] == true && passedSignature[item.id] == item.signature {
                pills.append("Test passed")
            } else {
                pills.append("Not yet tested")
            }
        }
        return pills
    }

    /// Choose… for the folder field.
    func chooseFolder(for id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if let current = draft?.workingDirectory {
            panel.directoryURL = URL(fileURLWithPath: LaunchSpec.expandFolder(current))
        }
        guard panel.runModal() == .OK, let url = panel.url, var item = drafts[id] ?? app.item(id) else { return }
        let home = NSHomeDirectory()
        item.workingDirectory = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
        update(item)
    }
}
