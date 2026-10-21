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

    /// Called with each toast-worthy message; the panel shows it.
    var onToast: (String) -> Void = { _ in }
    var onIconChange: (MenuBarIcon.State) -> Void = { _ in }

    let store: LibraryStore
    let supervisor: Supervisor
    private let secrets: any SecretStore
    private var loadedFileDate: Date?
    private var environmentReady: Task<Void, Never>?

    init(store: LibraryStore = LibraryStore(), secrets: any SecretStore = InMemorySecretStore()) {
        self.store = store
        self.secrets = secrets
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
    }

    // MARK: Library

    var items: [Item] { library.orderedItems }

    func item(_ id: UUID) -> Item? { library.items.first { $0.id == id } }

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
        let items = library.items
        for item in items where item.kind == .service && services[item.id] == nil {
            services[item.id] = ServiceStatus()
        }
        for item in items where item.kind == .task && tasks[item.id] == nil {
            tasks[item.id] = .ready
        }
        Task { await supervisor.setItems(items) }
        updateIcon()
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
