import CueCore
import SwiftUI

struct EditorView: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 0) {
            EditorSidebar(model: model)
                .frame(width: 200)
            Divider()
            if let item = model.draft {
                EditorDetail(model: model, item: item)
                    .id(item.id)
            } else {
                VStack(spacing: 8) {
                    Text("No item selected").font(.system(size: 13, weight: .medium))
                    Text("Add one with +, or paste a command into the panel.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

// MARK: Sidebar

private struct EditorSidebar: View {
    @Bindable var model: EditorModel
    @State private var confirmingRemoval: Item?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                ForEach(model.sidebarItems) { item in
                    HStack(spacing: 8) {
                        ItemTile(icon: item.icon, tint: item.tint, size: 20)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.name.isEmpty ? "Untitled" : item.name)
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                            if !item.isTested {
                                Text("Not tested").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 2)
                        if model.isDirty(item.id) {
                            Circle().fill(Palette.accentText).frame(width: 6, height: 6)
                                .help("Unsaved changes")
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(item.id)
                }
                .onMove { model.move(from: $0, to: $1) }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 0) {
                Button { model.addNew() } label: {
                    Image(systemName: "plus").frame(width: 28, height: 24)
                }
                .help("Add an item")
                Button {
                    confirmingRemoval = model.draft
                } label: {
                    Image(systemName: "minus").frame(width: 28, height: 24)
                }
                .disabled(model.selectedID == nil)
                .help("Remove the selected item")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(4)
        }
        .confirmationDialog(
            "Remove \(confirmingRemoval?.name ?? "this item")?",
            isPresented: Binding(get: { confirmingRemoval != nil }, set: { if !$0 { confirmingRemoval = nil } }),
            presenting: confirmingRemoval
        ) { item in
            Button("Remove", role: .destructive) { model.remove(item.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its secrets are deleted from the Keychain too.")
        }
    }
}

// MARK: Detail

private struct EditorDetail: View {
    @Bindable var model: EditorModel
    let item: Item

    private var binding: Binding<Item> {
        Binding(get: { model.draft ?? item }, set: { model.draft = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                CommandSection(model: model, item: binding)
                if let steps = model.testSteps[item.id], !steps.isEmpty || model.testRunning == item.id {
                    TestOutputSection(steps: steps, running: model.testRunning == item.id, passed: model.testPassed[item.id])
                }
                if binding.wrappedValue.kind != .link {
                    InputsSection(item: binding)
                }
                AppearanceSection(item: binding)
                if binding.wrappedValue.kind != .link {
                    AdvancedSection(model: model, item: binding)
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
    }

    private var header: some View {
        let current = binding.wrappedValue
        return HStack(spacing: 12) {
            ItemTile(icon: current.icon, tint: current.tint, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(current.name.isEmpty ? "Untitled" : current.name)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                Text(Self.caption(for: current.kind))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(model.pills(for: current), id: \.self) { Pill(text: $0) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    static func caption(for kind: ItemKind) -> String {
        switch kind {
        case .service: "Service · stays running until stopped"
        case .task: "Task · runs once and reports a result"
        case .link: "Link · opens an address"
        }
    }

    private var footer: some View {
        let current = binding.wrappedValue
        let testing = model.testRunning == item.id
        return HStack(spacing: 10) {
            if current.kind != .link {
                Button {
                    model.testRun(item.id)
                } label: {
                    HStack(spacing: 5) {
                        if testing { ProgressView().controlSize(.small) }
                        Text("Test Run")
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.testRunning != nil)
                .buttonStyle(.bordered)
                .tint(model.emphasizeTestRun ? Palette.accent : nil)
                .controlSize(.large)
            }
            Text(statusNote(current))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("Revert") { model.revert(item.id) }
                .disabled(!model.isDirty(item.id))
                .controlSize(.large)
            Button("Save") { model.save(item.id) }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .disabled(!model.isDirty(item.id))
                .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func statusNote(_ current: Item) -> String {
        if let message = model.message { return message }
        if model.testRunning == item.id { return "Testing…" }
        if let passed = model.testPassed[item.id] { return passed ? "Test passed" : "Test failed" }
        if model.emphasizeTestRun { return "Test it before using it from the menu" }
        return ""
    }
}

private struct Pill: View {
    let text: String

    var body: some View {
        let color: Color = switch text {
        case "Test passed": Palette.ok
        case "Not yet tested": Palette.warn
        default: Palette.accentText
        }
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.13)))
    }
}

// MARK: Sections

private struct CommandSection: View {
    let model: EditorModel
    @Binding var item: Item

    var body: some View {
        Section("Command") {
            Picker("Type", selection: $item.kind) {
                Text("Service").tag(ItemKind.service)
                Text("Task").tag(ItemKind.task)
                Text("Link").tag(ItemKind.link)
            }
            .pickerStyle(.segmented)

            if item.kind == .link {
                TextField("Target", text: $item.target, prompt: Text("https://… or ~/Folder"))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Run")
                    TextEditor(text: $item.command)
                        .font(.system(size: 12, design: .monospaced))
                        .multilineTextAlignment(.leading)
                        .frame(minHeight: 54, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                }
                LabeledContent("Folder") {
                    HStack {
                        TextField("Folder", text: $item.workingDirectory, prompt: Text("~"))
                            .labelsHidden()
                            .font(.system(size: 12, design: .monospaced))
                        Button("Choose…") { model.chooseFolder(for: item.id) }
                    }
                }
            }

            if item.kind == .service {
                RunningWhenField(item: $item)
                StopByField(item: $item)
                TextField("Address", text: Binding(get: { item.address ?? "" }, set: { item.address = $0.isEmpty ? nil : $0 }),
                          prompt: Text("Optional, e.g. localhost:$PORT"))
            }
        }
    }
}

private struct RunningWhenField: View {
    @Binding var item: Item

    private enum Choice: Hashable { case process, port, status }

    private var choice: Binding<Choice> {
        Binding(
            get: {
                switch item.runningWhen {
                case .process: .process
                case .port: .port
                case .statusCommand: .status
                }
            },
            set: { new in
                switch new {
                case .process: item.runningWhen = .process
                case .port: if case .port = item.runningWhen {} else { item.runningWhen = .port("") }
                case .status: if case .statusCommand = item.runningWhen {} else { item.runningWhen = .statusCommand("") }
                }
            }
        )
    }

    var body: some View {
        Picker("Running when", selection: choice) {
            Text("Its process is alive").tag(Choice.process)
            Text("A port responds").tag(Choice.port)
            Text("A status command").tag(Choice.status)
        }
        switch item.runningWhen {
        case .process:
            Hint("Only sees processes Cue started. If the command exits within 3 s, it counts as failed.")
        case .port(let port):
            TextField("Port", text: Binding(get: { port }, set: { item.runningWhen = .port($0) }), prompt: Text("4000 or $PORT"))
                .font(.system(size: 12, design: .monospaced))
            Hint("On when a connection to 127.0.0.1 or ::1 succeeds within 1 s.")
        case .statusCommand(let command):
            TextField("Status command", text: Binding(get: { command }, set: { item.runningWhen = .statusCommand($0) }), axis: .vertical)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1...4)
            Hint("Exit 0 means on, 1 means off; anything else, or no answer in 5 s, shows as unknown.")
        }
    }
}

private struct StopByField: View {
    @Binding var item: Item

    private var isCommand: Binding<Bool> {
        Binding(
            get: { if case .command = item.stopBy { true } else { false } },
            set: { item.stopBy = $0 ? .command(item.stopCommandText) : .process }
        )
    }

    var body: some View {
        Picker("Stop by", selection: isCommand) {
            Text("Ending the process Cue started").tag(false)
            Text("Running a stop command").tag(true)
        }
        if case .command(let command) = item.stopBy {
            TextField("Stop command", text: Binding(get: { command }, set: { item.stopBy = .command($0) }), axis: .vertical)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1...4)
        }
    }
}

private extension Item {
    var stopCommandText: String {
        if case .command(let command) = stopBy { return command }
        return ""
    }
}

private struct TestOutputSection: View {
    let steps: [TestStep]
    let running: Bool
    let passed: Bool?

    var body: some View {
        Section("Test Run") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        switch step.kind {
                        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ok)
                        case .failure: Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.err)
                        case .info: Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.tertiary).frame(width: 13)
                        }
                        Text(step.text)
                            .font(step.isCode ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                            .foregroundStyle(step.kind == .info ? Color.secondary : Color.primary)
                            .textSelection(.enabled)
                            .lineLimit(4)
                    }
                    .font(.system(size: 11))
                }
                if running {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Running…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct InputsSection: View {
    @Binding var item: Item

    var body: some View {
        Section("Inputs") {
            ForEach(item.inputs.indices, id: \.self) { index in
                HStack {
                    TextField("NAME", text: Binding(get: { item.inputs[index].name }, set: { item.inputs[index].name = $0.uppercased() }))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 140)
                    TextField("Default value", text: $item.inputs[index].defaultValue)
                        .font(.system(size: 12, design: .monospaced))
                    Button { item.inputs.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
                .labelsHidden()
            }
            Button("Add Input") { item.inputs.append(Input(name: "")) }
            Hint("The menu asks for these before each run. Use them as \"$NAME\".")
        }
    }
}

private struct AppearanceSection: View {
    @Binding var item: Item

    var body: some View {
        Section("Appearance") {
            TextField("Name", text: $item.name)
            LabeledContent("Icon") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 6), count: 8), spacing: 6) {
                    ForEach(ItemSuggestions.icons, id: \.self) { icon in
                        Button { item.icon = icon } label: {
                            Image(systemName: icon)
                                .font(.system(size: 13))
                                .frame(width: 28, height: 28)
                                .foregroundStyle(item.icon == icon ? Palette.symbol(item.tint) : .secondary)
                                .background(RoundedRectangle(cornerRadius: 6).fill(item.icon == icon ? Palette.tile(item.tint) : .clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(icon)
                    }
                }
            }
            LabeledContent("Color") {
                HStack(spacing: 8) {
                    ForEach(Tint.allCases, id: \.self) { tint in
                        Button { item.tint = tint } label: {
                            Circle()
                                .fill(Palette.tile(tint))
                                .overlay(Circle().fill(Palette.symbol(tint)).padding(6))
                                .overlay(Circle().strokeBorder(Palette.accent, lineWidth: item.tint == tint ? 2 : 0))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help(tint.rawValue.capitalized)
                    }
                }
            }
        }
    }
}

private struct AdvancedSection: View {
    @Bindable var model: EditorModel
    @Binding var item: Item

    var body: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $model.showAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    environment
                    Divider()
                    Picker("Shell", selection: $item.shell) {
                        ForEach(Shell.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    TimeLimitField(limit: $item.timeLimit)
                    Toggle("Ask before running", isOn: $item.confirmBeforeRunning)
                    Hint("Switched on when you save a command with rm -r, sudo, --force, git push or git reset --hard.")
                    Toggle("Keep output", isOn: $item.keepOutput)
                }
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder private var environment: some View {
        Text("Environment").font(.system(size: 12, weight: .medium))
        ForEach(item.environment.indices, id: \.self) { index in
            HStack {
                TextField("KEY", text: Binding(get: { item.environment[index].key }, set: { item.environment[index].key = $0 }))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 140)
                Text("=").foregroundStyle(.secondary)
                if item.environment[index].isSecret {
                    let key = item.environment[index].key
                    SecureField(
                        model.app.secrets.secret(itemID: item.id, key: key) != nil ? "Saved in Keychain" : "Secret value",
                        text: Binding(
                            get: { model.secretDrafts[item.id]?[key] ?? "" },
                            set: { model.secretDrafts[item.id, default: [:]][key] = $0 }
                        )
                    )
                } else {
                    TextField("value", text: $item.environment[index].value)
                        .font(.system(size: 12, design: .monospaced))
                }
                Toggle("Secret", isOn: Binding(
                    get: { item.environment[index].isSecret },
                    set: { secret in
                        if secret {
                            let value = item.environment[index].value
                            if !value.isEmpty { model.secretDrafts[item.id, default: [:]][item.environment[index].key] = value }
                            item.environment[index].value = ""
                        }
                        item.environment[index].isSecret = secret
                    }
                ))
                .toggleStyle(.checkbox)
                Button { item.environment.remove(at: index) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
            .labelsHidden()
        }
        Button("Add Variable") { item.environment.append(EnvironmentVariable(key: "")) }
    }
}

private struct TimeLimitField: View {
    @Binding var limit: TimeLimit

    private var isCustom: Bool { !TimeLimit.presets.contains(limit) }

    var body: some View {
        Picker("Time limit", selection: Binding(
            get: { isCustom ? TimeLimit.seconds(-1) : limit },
            set: { limit = $0 == .seconds(-1) ? .seconds(300) : $0 }
        )) {
            Text("None").tag(TimeLimit.none)
            Text("30 s").tag(TimeLimit.seconds(30))
            Text("2 min").tag(TimeLimit.seconds(120))
            Text("10 min").tag(TimeLimit.seconds(600))
            Text("Custom").tag(TimeLimit.seconds(-1))
        }
        if isCustom, case .seconds(let seconds) = limit {
            Stepper(value: Binding(get: { seconds }, set: { limit = .seconds(max(1, $0)) }), in: 1...86_400, step: 30) {
                Text("\(DurationText.short(.seconds(seconds)))").monospacedDigit()
            }
        }
    }
}

private struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
    }
}
