import CueCore
import SwiftUI

/// The quick-add row: its guess as a small type label, and what ↵ will do.
struct AddRowView: View {
    let model: PanelModel
    let isSelected: Bool
    let now: Date

    var body: some View {
        let guess = model.addGuess
        HStack(spacing: 10) {
            ItemTile(icon: icon, tint: .plum)
            VStack(alignment: .leading, spacing: 1) {
                Text(title(guess))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle(guess))
                    .font(model.addKind == .command && model.dropNote == nil ? .system(size: 11.5, design: .monospaced) : .system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Text(model.addKind.rawValue)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Palette.accentText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Palette.accent.opacity(0.14)))
                .help("Tab switches between Link, Command and Reminder")
            GlyphView(glyph: .plus)
                .frame(width: Metrics.accessorySize, height: Metrics.accessorySize)
        }
        .padding(.horizontal, 8)
        .frame(height: Metrics.rowHeight)
        .contentShape(Rectangle())
    }

    private var icon: String {
        switch model.addKind {
        case .link: "link"
        case .command: "terminal"
        case .reminder: "bell"
        }
    }

    private func title(_ guess: Classifier.Guess) -> String {
        switch model.addKind {
        case .link: return "Add link"
        case .command: return "Add command"
        case .reminder:
            let text = guess.reminder.due == nil ? guess.text : guess.reminder.text
            if let due = guess.reminder.due {
                return "Remind me at \(due.formatted(date: .omitted, time: .shortened)): \u{201C}\(text)\u{201D}"
            }
            return "Remind me: \u{201C}\(text)\u{201D}"
        }
    }

    private func subtitle(_ guess: Classifier.Guess) -> String {
        if let note = model.dropNote { return note }
        switch model.addKind {
        case .link:
            return LinkTarget.display(guess.text)
        case .command:
            let lines = guess.text.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.count > 1 ? "\(lines[0]) … (\(lines.count) lines)" : guess.text
        case .reminder:
            guard let due = guess.reminder.due else { return "Pick a time…" }
            return "in \(RelativeText.countdown(to: due, now: now)) · \(due.formatted(date: .omitted, time: .shortened))"
        }
    }
}
