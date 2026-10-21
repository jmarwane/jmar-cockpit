import CueCore
import SwiftUI

/// The inline expansion under a row.
struct ExpansionView: View {
    @Bindable var model: PanelModel
    let expansion: Expansion
    let item: Item

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch expansion {
            case .inputs:
                InputsForm(model: model, item: item)
            case .confirm(_, let values):
                ConfirmView(model: model, item: item, values: values)
            case .error:
                ErrorDetailsView(model: model, item: item)
            case .runDetails:
                RunDetailsView(model: model, item: item)
            case .reminderForm:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

private struct InputsForm: View {
    @Bindable var model: PanelModel
    let item: Item
    @FocusState private var focused: String?

    var body: some View {
        ForEach(item.inputs, id: \.name) { input in
            HStack(spacing: 8) {
                Text(input.name)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.ink2)
                    .frame(width: 84, alignment: .leading)
                    .lineLimit(1)
                TextField(input.defaultValue, text: Binding(
                    get: { model.inputDrafts[input.name] ?? "" },
                    set: { model.inputDrafts[input.name] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .focused($focused, equals: input.name)
            }
        }
        HStack {
            Spacer()
            ExpansionButton("Cancel") { model.expansion = nil }
            ExpansionButton(item.kind == .service ? "Start" : "Run", key: "↵", isPrimary: true) {
                model.submit(.inputs(item.id))
            }
        }
        .onAppear { focused = item.inputs.first?.name }
    }
}

private struct ConfirmView: View {
    let model: PanelModel
    let item: Item
    let values: [String: String]

    var body: some View {
        Text(item.kind == .service ? "Start with this command?" : "Run this command?")
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Palette.ink2)
        CommandBlock(text: item.command)
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(values.keys.sorted(), id: \.self) { key in
                    Text("\(key) = \(values[key] ?? "")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.ink2)
                }
            }
        }
        HStack {
            Spacer()
            ExpansionButton("Cancel") { model.expansion = nil }
            ExpansionButton(item.kind == .service ? "Start" : "Run", key: "↵", isPrimary: true) {
                model.submit(.confirm(item.id, inputs: values))
            }
        }
    }
}

private struct ErrorDetailsView: View {
    let model: PanelModel
    let item: Item

    private var failure: Failure? {
        switch (model.app.services[item.id]?.state, model.app.tasks[item.id]) {
        case (.failed(let failure)?, _): failure
        case (_, .failed(let failure)?): failure
        default: nil
        }
    }

    var body: some View {
        if let failure {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(headline(failure, now: context.date))
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(2)
            }
            if let line = failure.errorLine {
                CommandBlock(text: line, color: Palette.err)
            }
            if let reason = failure.reportedReason {
                Text("Reported by the script: \(reason)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink)
            }
            if let hint = failure.hint {
                Text(hint).font(.system(size: 11.5)).foregroundStyle(Palette.ink2)
            }
            HStack {
                Spacer()
                ExpansionButton("Copy") {
                    if let details = model.app.errorDetails(for: item.id) {
                        model.app.copy(details)
                        model.showToast("Copied")
                    }
                }
                ExpansionButton("Retry", key: "↵", isPrimary: true) { model.retry(item) }
            }
        }
    }

    /// `Exit 1 · 2m ago` above the error line, or `<message> · 2m ago` when there's no exit code.
    private func headline(_ failure: Failure, now: Date) -> String {
        let when = RelativeText.ago(failure.at, now: now)
        if let code = failure.exitCode, code != 0 {
            return failure.errorLine == nil ? "Exit \(code) · \(when) · \(failure.message)" : "Exit \(code) · \(when)"
        }
        return "\(failure.message) · \(when)"
    }
}

private struct RunDetailsView: View {
    let model: PanelModel
    let item: Item

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            VStack(alignment: .leading, spacing: 6) {
                if case .running(let since)? = model.app.tasks[item.id] {
                    Text("Running for \(RelativeText.elapsed(since: since, now: context.date))")
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink2)
                }
                CommandBlock(text: model.app.activeRuns[item.id]?.output.lastLine ?? "No output yet")
            }
        }
        HStack {
            Spacer()
            ExpansionButton("Cancel Run", isDestructive: true) { model.cancelRun(item) }
        }
    }
}

/// Monospaced text, at most two lines, on a faint background.
struct CommandBlock: View {
    let text: String
    var color: Color = Palette.ink

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(2)
            .truncationMode(.tail)
            .textSelection(.enabled)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.ink.opacity(0.05)))
    }
}

struct ExpansionButton: View {
    let title: String
    var key: String?
    var isPrimary = false
    var isDestructive = false
    let action: () -> Void

    init(_ title: String, key: String? = nil, isPrimary: Bool = false, isDestructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.key = key
        self.isPrimary = isPrimary
        self.isDestructive = isDestructive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                if let key { KeyChip(key) }
            }
            .font(.system(size: 11.5, weight: isPrimary ? .semibold : .regular))
            .foregroundStyle(isPrimary ? Color.white : (isDestructive ? Palette.err : Palette.ink))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isPrimary ? Palette.accent : Palette.ink.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
    }
}

struct KeyChip: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 15)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.09)))
    }
}
