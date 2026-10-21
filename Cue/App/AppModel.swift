import AppKit
import CueCore
import Foundation
import Observation
import os

let appLog = Logger(subsystem: "com.jmarwane.cue", category: "app")

/// The library, the observed status of every item, and the actions that change them.
/// Status here is only ever what the supervisor reports.
@MainActor @Observable
final class AppModel {
    private(set) var library = Library()
    /// Set when items.json couldn't be read; saving is refused until it's fixed.
    private(set) var loadError: String?
    private(set) var services: [UUID: ServiceStatus] = [:]
    private(set) var tasks: [UUID: TaskState] = [:]
    private(set) var environment: CapturedEnvironment?
    /// Live runs, for run details (elapsed time, last output line).
    private(set) var activeRuns: [UUID: RunHandle] = [:]
    /// Commands run once without saving. Kept in memory only; gone when dismissed or when Cue quits.
    private(set) var recent: [Item] = []

    /// Called with each toast-worthy message; the panel shows it.
    var onToast: (String) -> Void = { _ in }
    var onIconChange: (MenuBarIcon.State) -> Void = { _ in }

    let store: LibraryStore
    let supervisor: Supervisor
    let secrets: any SecretStore
    private let notifications: any ReminderNotifying
    private var reminderTimer: Timer?
    private var loadedFileDate: Date?
    private var environmentReady: Task<Void, Never>?

    init(
        store: LibraryStore = LibraryStore(),
        secrets: any SecretStore = KeychainSecretStore(),
        notifications: any ReminderNotifying = ReminderNotifications()
    ) {
        self.store = store
        self.secrets = secrets
        self.notifications = notifications
        var fallback = ProcessInfo.processInfo.environment
        fallback["PATH"] = LoginShellEnvironment.defaultPATH
        supervisor = Supervisor(environment: fallback, secrets: secrets)

        reload()
        environmentReady = Task {
            let captured = await LoginShellEnvironment.capture()
            appLog.notice("environment captured via \(captured.source.rawValue, privacy: .public)")
            await supervisor.setEnvironment(captured.variables)
            self.environment = captured
        }
        Task { await consumeEvents() }

        notifications.onAction = { [weak self] id, action in self?.handleNotification(id, action) }
        if let real = notifications as? ReminderNotifications {
            real.onDenied = { [weak self] in self?.onToast("Notifications are off for Cue; reminders show only here") }
        }
        // Anything that came due while Cue wasn't running is "Was due"; pending ones are scheduled again.
        refreshReminders()
        library.reminders.filter { $0.state == .pending }.forEach(notifications.schedule)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshReminders() }
        }
    }

    /// Opens the panel when a reminder notification is clicked.
    var onOpenPanel: () -> Void = {}

    // MARK: Library

    var items: [Item] { library.orderedItems }

    func item(_ id: UUID) -> Item? { library.items.first { $0.id == id } ?? recent.first { $0.id == id } }

    func isRecent(_ id: UUID) -> Bool { recent.contains { $0.id == id } }

    /// The PATH commands run with, for classifying quick-add text.
    var commandPath: String { environment?.path ?? LoginShellEnvironment.defaultPATH }

    /// Reads items.json again if it changed on disk since the last load.
    func reloadIfChanged() {
        if modificationDate() != loadedFileDate { reload() }
    }

    private func reload() {
        do {
            library = try store.load()
            loadError = nil
        } catch {
            loadError = error.description
            appLog.error("load failed: \(error.description, privacy: .public)")
        }
        loadedFileDate = modificationDate()
        reconcileStatuses()
    }

    private func save() {
        guard loadError == nil else {
            onToast("Not saved: items.json couldn't be read")
            return
        }
        do {
            try store.save(library)
            loadedFileDate = modificationDate()
        } catch {
            onToast("Couldn't save: \(error.localizedDescription)")
        }
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: store.fileURL.path))?[.modificationDate] as? Date
    }

    /// Remembers the inputs used for a run, so the form starts from them next time.
    func rememberInputs(_ values: [String: String], for id: UUID) {
        guard let index = library.items.firstIndex(where: { $0.id == id }), !values.isEmpty,
              library.items[index].lastInputs != values else { return }
        library.items[index].lastInputs = values
        save()
        Task { await supervisor.setItems(library.items) }
    }

    // MARK: Editing

    enum EditError: Error, CustomStringConvertible {
        case notSaved(String)
        case running(String)

        var description: String {
            switch self {
            case .notSaved(let detail): detail
            case .running(let name): "Stop \(name) first"
            }
        }
    }

    /// Saves an item (new or existing), writing typed secret values to the Keychain
    /// and deleting the ones whose variables were removed or are no longer secret.
    func saveItem(_ item: Item, secretValues: [String: String]) throws(EditError) {
        guard loadError == nil else { throw .notSaved("items.json couldn't be read, so nothing is saved over it") }
        var item = item
        for index in item.environment.indices where item.environment[index].isSecret {
            item.environment[index].value = ""
        }
        let previous = self.item(item.id)

        if let keychain = secrets as? KeychainSecretStore {
            for (key, value) in secretValues where item.environment.contains(where: { $0.key == key && $0.isSecret }) {
                do {
                    try keychain.setSecret(value, itemID: item.id, key: key)
                } catch {
                    throw .notSaved("Keychain: \(error)")
                }
            }
            let keptSecrets = Set(item.environment.filter(\.isSecret).map(\.key))
            for old in previous?.environment ?? [] where old.isSecret && !keptSecrets.contains(old.key) {
                keychain.deleteSecret(itemID: item.id, key: old.key)
            }
        }

        recent.removeAll { $0.id == item.id }
        if let index = library.items.firstIndex(where: { $0.id == item.id }) {
            library.items[index] = item
        } else {
            item.order = (library.items.map(\.order).max() ?? -1) + 1
            library.items.append(item)
        }
        save()
        reconcileStatuses()
    }

    /// Removes an item and its Keychain secrets. Refused while Cue is running it.
    func removeItem(_ id: UUID) throws(EditError) {
        guard let item = item(id) else { return }
        if isActive(id) { throw .running(item.name) }
        if let keychain = secrets as? KeychainSecretStore {
            for variable in item.environment where variable.isSecret {
                keychain.deleteSecret(itemID: id, key: variable.key)
            }
        }
        library.items.removeAll { $0.id == id }
        save()
        reconcileStatuses()
    }

    /// Puts items in the given order and renumbers them.
    func reorder(_ ids: [UUID]) {
        var items = library.orderedItems
        let positions = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        items.sort { (positions[$0.id] ?? Int.max) < (positions[$1.id] ?? Int.max) }
        for index in items.indices { items[index].order = index }
        library.items = items
        save()
    }

    /// Stores a passing test's signature, if the saved item still has that exact setup.
    func markTested(_ id: UUID, signature: String) {
        guard let index = library.items.firstIndex(where: { $0.id == id }), library.items[index].signature == signature else { return }
        library.items[index].testedSignature = signature
        save()
        reconcileStatuses()
    }

    /// Running, starting, stopping or On because of Cue.
    func isActive(_ id: UUID) -> Bool {
        if tasks[id]?.isRunning == true { return true }
        guard let status = services[id] else { return false }
        return status.state.isTransitioning || status.ownsProcess || status.state.isOn
    }

    private func reconcileStatuses() {
        let ids = Set(library.items.map(\.id))
        for item in library.items {
            switch item.kind {
            case .service:
                tasks[item.id] = nil
                if services[item.id] == nil { services[item.id] = ServiceStatus() }
            case .task:
                services[item.id] = nil
                if tasks[item.id] == nil { tasks[item.id] = .ready }
            case .link:
                services[item.id] = nil
                tasks[item.id] = nil
            }
        }
        services = services.filter { ids.contains($0.key) }
        tasks = tasks.filter { ids.contains($0.key) }
        let items = library.items + recent
        Task { await supervisor.setItems(items) }
        updateIcon()
    }

    // MARK: Quick add

    /// Saves a link at the end of the list.
    @discardableResult
    func addLink(_ target: String) -> Item? {
        let item = Item(kind: .link, name: Classifier.linkName(target), tint: ItemSuggestions.tint(for: target), target: target)
        do {
            try saveItem(item, secretValues: [:])
            return item
        } catch {
            onToast(error.description)
            return nil
        }
    }

    /// Saves a command with its guessed kind, name and icon. It's Not yet tested until a Test Run passes.
    func addCommand(_ command: String) -> Item? {
        let kind = ItemSuggestions.kind(for: command)
        let name = ItemSuggestions.name(for: command)
        let item = Item(
            kind: kind, name: name, icon: ItemSuggestions.icon(for: command, kind: kind), tint: ItemSuggestions.tint(for: name),
            command: command, confirmBeforeRunning: CommandTraits.isRisky(command)
        )
        do {
            try saveItem(item, secretValues: [:])
            return item
        } catch {
            onToast(error.description)
            return nil
        }
    }

    /// Runs a command once without saving it; it shows in the Recent group.
    func runOnce(_ command: String) {
        if CommandTraits.needsTerminal(command) {
            runInTerminal(Item(kind: .task, name: "", command: command), inputs: [:])
            return
        }
        var item = Item(kind: .task, name: ItemSuggestions.name(for: command), icon: "clock.arrow.circlepath", tint: .sand, command: command)
        item.testedSignature = item.signature
        recent.append(item)
        tasks[item.id] = .ready
        let items = library.items + recent
        Task {
            await supervisor.setItems(items)
            await whenReady()
            await supervisor.run(item.id, inputs: [:])
        }
    }

    func dismissRecent(_ id: UUID) {
        guard isRecent(id), tasks[id]?.isRunning != true else { return }
        recent.removeAll { $0.id == id }
        reconcileStatuses()
    }

    /// Opens Terminal with `cd <folder> && <command>`. A new run, not a hand-off of one already going.
    func runInTerminal(_ item: Item, inputs: [String: String]) {
        let script = TerminalCommand.appleScript(for: TerminalCommand.line(for: item, inputs: inputs))
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Terminal didn't respond"
            onToast("Run in Terminal: \(message)")
        }
    }

    /// `chmod +x`: execute for the owner, and for group and others where they can read.
    func makeExecutable(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value else { return false }
        var updated = permissions | 0o100
        if permissions & 0o040 != 0 { updated |= 0o010 }
        if permissions & 0o004 != 0 { updated |= 0o001 }
        do {
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: updated)], ofItemAtPath: path)
            return true
        } catch {
            onToast("Couldn't make it executable: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Reminders

    var reminders: [Reminder] { ReminderBook.upcoming(library.reminders) }

    func reminder(_ id: UUID) -> Reminder? { library.reminders.first { $0.id == id } }

    func addReminder(text: String, due: Date) {
        let reminder = Reminder(text: text.isEmpty ? "Reminder" : text, due: due)
        library.reminders.append(reminder)
        save()
        notifications.schedule(reminder)
        refreshReminders()
    }

    func updateReminder(_ id: UUID, text: String, due: Date) {
        guard let index = library.reminders.firstIndex(where: { $0.id == id }) else { return }
        notifications.cancel(library.reminders[index])
        library.reminders[index].text = text.isEmpty ? "Reminder" : text
        library.reminders[index].due = due
        library.reminders[index].state = .pending
        library.reminders[index].firedAt = nil
        save()
        notifications.schedule(library.reminders[index])
        refreshReminders()
    }

    /// Done in the notification, a click on a fired reminder, or Cancel Reminder.
    func dismissReminder(_ id: UUID) {
        guard let reminder = reminder(id) else { return }
        notifications.cancel(reminder)
        library.reminders.removeAll { $0.id == id }
        save()
        refreshReminders()
    }

    func snoozeReminder(_ id: UUID) {
        guard let index = library.reminders.firstIndex(where: { $0.id == id }) else { return }
        notifications.cancel(library.reminders[index])
        library.reminders[index] = ReminderBook.snoozed(library.reminders[index], now: Date())
        save()
        notifications.schedule(library.reminders[index])
        refreshReminders()
    }

    private func handleNotification(_ id: UUID, _ action: ReminderNotifications.Action) {
        switch action {
        case .snooze: snoozeReminder(id)
        case .done: dismissReminder(id)
        case .open:
            refreshReminders()
            onOpenPanel()
        }
    }

    /// Marks due reminders fired, then sets a timer for the next one.
    func refreshReminders() {
        if !ReminderBook.markDue(&library.reminders, now: Date()).isEmpty { save() }
        reminderTimer?.invalidate()
        reminderTimer = nil
        guard let next = ReminderBook.nextDue(library.reminders) else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshReminders() }
        }
        RunLoop.main.add(timer, forMode: .common)
        reminderTimer = timer
    }

    // MARK: Status

    func presentation(for item: Item, now: Date = Date()) -> RowPresentation {
        RowPresentation.make(item: item, service: services[item.id], task: tasks[item.id], now: now)
    }

    /// True when the glyph shows an old result: last check over 30 s ago and a new one not in yet.
    func isStale(_ id: UUID, now: Date = Date()) -> Bool {
        guard let status = services[id], status.isChecking, let checked = status.lastCheckedAt else { return false }
        return now.timeIntervalSince(checked) > Metrics.staleAfter
    }

    private func consumeEvents() async {
        for await event in supervisor.events {
            switch event {
            case .service(let id, let status):
                services[id] = status
            case .task(let id, let state):
                tasks[id] = state
                if state.isRunning {
                    activeRuns[id] = await supervisor.activeRun(of: id)
                } else {
                    activeRuns[id] = nil
                }
            case .unexpectedExit(let id, let failure):
                appLog.notice("unexpected exit \(id, privacy: .public): \(failure.message, privacy: .public)")
            case .runFinished:
                break
            }
            updateIcon()
        }
    }

    var iconState: MenuBarIcon.State {
        let needsAttention = loadError != nil
            || services.values.contains { status in
                switch status.state {
                case .failed: true
                case .unknown(let reason): reason != nil
                default: false
                }
            }
            || tasks.values.contains { if case .failed = $0 { true } else { false } }
        if needsAttention { return .needsAttention }
        let somethingOn = services.values.contains { $0.state.isOn } || tasks.values.contains { $0.isRunning }
        return somethingOn ? .somethingOn : .idle
    }

    private func updateIcon() {
        onIconChange(iconState)
    }

    // MARK: Actions

    private func whenReady() async {
        await environmentReady?.value
    }

    func checkAllServices() {
        for item in library.items where item.kind == .service {
            Task {
                await whenReady()
                await supervisor.check(item.id)
            }
        }
    }

    func check(_ id: UUID) {
        Task {
            await whenReady()
            await supervisor.check(id)
        }
    }

    func start(_ id: UUID, inputs: [String: String]) {
        rememberInputs(inputs, for: id)
        Task {
            await whenReady()
            await supervisor.start(id, inputs: inputs)
            activeRuns[id] = await supervisor.activeRun(of: id)
        }
    }

    func stop(_ id: UUID) {
        Task {
            let outcome = await supervisor.stop(id)
            if case .notOwned = outcome {
                onToast("Cue didn't start it and it has no stop command")
            }
        }
    }

    func forceStop(_ id: UUID) {
        Task { await supervisor.forceStop(id) }
    }

    func restart(_ id: UUID) {
        guard let item = item(id) else { return }
        Task {
            await whenReady()
            await supervisor.stop(id)
            if await supervisor.status(of: id)?.state.isOn == false {
                await supervisor.start(id, inputs: item.currentInputValues)
            }
        }
    }

    func run(_ id: UUID, inputs: [String: String]) {
        rememberInputs(inputs, for: id)
        Task {
            await whenReady()
            await supervisor.run(id, inputs: inputs)
        }
    }

    func cancel(_ id: UUID) {
        Task { await supervisor.cancel(id) }
    }

    /// Opens a link target or a service address. Returns false if it isn't something macOS can open.
    @discardableResult
    func open(_ target: String) -> Bool {
        guard let url = LinkTarget.url(for: target) else { return false }
        return NSWorkspace.shared.open(url)
    }

    func address(of item: Item) -> String? {
        guard let address = item.address, !address.isEmpty else { return nil }
        return Placeholders.substitute(address, values: LaunchSpec.placeholderValues(for: item, inputs: item.currentInputValues))
    }

    /// A plain-text report of a failure for the clipboard. Output is already redacted.
    func errorDetails(for id: UUID) -> String? {
        guard let item = item(id) else { return nil }
        let failure: Failure
        switch (services[id]?.state, tasks[id]) {
        case (.failed(let f)?, _): failure = f
        case (_, .failed(let f)?): failure = f
        default: return nil
        }
        var lines = ["\(item.name): \(failure.message)"]
        if let code = failure.exitCode { lines.append("Exit code: \(code)") }
        if let errorLine = failure.errorLine { lines.append("Error: \(errorLine)") }
        if let reason = failure.reportedReason { lines.append("Reported by the script: \(reason)") }
        if let hint = failure.hint { lines.append(hint) }
        if let run = failure.run {
            lines.append("Command: \(run.command)")
            let tail = run.output.split(separator: "\n", omittingEmptySubsequences: false).suffix(40).joined(separator: "\n")
            if !tail.isEmpty { lines.append("\n\(tail)") }
        }
        return lines.joined(separator: "\n")
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
