import CueCore
import SwiftUI

/// A reminder row, or the built-in New Reminder row.
struct ReminderRowView: View {
    let title: String
    let presentation: RowPresentation
    let isSelected: Bool
    let actionSymbol: String

    var body: some View {
        HStack(spacing: 10) {
            ItemTile(icon: presentation.glyph == .chevron ? "bell.badge" : "bell", tint: .amber)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(presentation.subtitle)
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            ZStack {
                if isSelected {
                    Image(systemName: actionSymbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: Metrics.accessorySize, height: Metrics.accessorySize)
                        .background(Circle().fill(Palette.ink.opacity(0.07)))
                } else {
                    GlyphView(glyph: presentation.glyph)
                }
            }
            .frame(width: Metrics.accessorySize, height: Metrics.accessorySize)
        }
        .padding(.horizontal, 8)
        .frame(height: Metrics.rowHeight)
        .contentShape(Rectangle())
    }
}

/// Text, chips, the due time read from the text, then Cancel · Set.
struct ReminderFormView: View {
    @Bindable var model: PanelModel
    let rowID: UUID
    @FocusState private var focused: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 8) {
                TextField("Write a note, or \u{201C}call the bank at 18:30\u{201D}", text: $model.reminderText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($focused)
                HStack(spacing: 6) {
                    if let keep = model.reminderKeep {
                        chip("Keep \(ReminderBook.clock(keep, now: context.date))", due: keep)
                    }
                    ForEach(ReminderBook.chips(now: context.date), id: \.label) { chip($0.label, due: $0.due) }
                }
                Text(model.reminderDraftDue.map { "Due \(ReminderBook.clock($0, now: context.date))" } ?? "Pick a time, or type one like \u{201C}in 20m\u{201D}")
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink2)
                HStack {
                    Spacer()
                    ExpansionButton("Cancel") { model.expansion = nil }
                    ExpansionButton("Set", key: "↵", isPrimary: true) { model.submitReminderForm(rowID) }
                        .disabled(model.reminderDraftDue == nil)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .onAppear { focused = true }
    }

    private func chip(_ label: String, due: Date) -> some View {
        let selected = model.reminderChipLabel == label || (model.reminderChipLabel == nil && model.reminderKeep == due && label.hasPrefix("Keep"))
        return Button {
            model.reminderChip = due
            model.reminderChipLabel = label
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? Color.white : Palette.ink)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(selected ? Palette.accent : Palette.ink.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }
}
