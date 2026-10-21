import CueCore
import SwiftUI

struct PanelRootView: View {
    @Bindable var model: PanelModel
    @FocusState private var searchFocused: Bool
    @Namespace private var selectionSpace
    @Environment(\.colorSchemeContrast) private var contrast

    /// The selection highlight; stronger with Increase Contrast.
    private var selectionFill: Color { Palette.ink.opacity(contrast == .increased ? 0.16 : 0.075) }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().opacity(0.6)
            content
            Divider().opacity(0.6)
            footer
        }
        .frame(width: PanelMetrics.width)
        .overlay {
            if model.isDropTargeted {
                RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(Palette.accent, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .url, .utf8PlainText], isTargeted: $model.isDropTargeted) { providers in
            DropReader.read(providers) { urls, text in model.receiveDrop(fileURLs: urls, text: text) }
            return true
        }
        .onChange(of: model.openCount, initial: true) {
            searchFocused = true
        }
        .onChange(of: model.expansion) { _, new in
            if new == nil { searchFocused = true }
        }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.ink2)
            TextField("Search or paste\u{2026}", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Palette.ink)
                .focused($searchFocused)
            Button {
                model.showAddRow()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.ink2)
            .help("Add")
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.searchHeight)
    }

    // MARK: Rows

    @ViewBuilder private var content: some View {
        let rows = model.visibleRows
        let recent = model.visibleRecent
        let count = rows.count + recent.count + (model.addRowVisible ? 1 : 0)
            + model.visibleReminders.count + (model.showsNewReminderRow && !model.rows.isEmpty ? 1 : 0)
        if count == 0 {
            if let error = model.app.loadError {
                message(error)
            } else {
                message("Paste a command, drop a script, add a link, or type \u{201C}stretch in 20m\u{201D}.")
            }
        } else if count > Metrics.maxVisibleRows {
            ScrollViewReader { proxy in
                ScrollView(.vertical) { list(rows) }
                    .frame(height: CGFloat(Metrics.maxVisibleRows) * Metrics.rowHeight + Metrics.listInset * 2)
                    .onChange(of: model.selection) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                    }
            }
        } else {
            list(rows)
        }
    }

    private func list(_ rows: [Item]) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 0) {
                if model.showsNewReminderRow {
                    newReminderRow(now: context.date)
                }
                ForEach(rows) { item in
                    row(item, now: context.date)
                }
                if model.addRowVisible {
                    addRow(now: context.date)
                    if model.expansion == .reminderForm(PanelModel.addRowID) {
                        ReminderFormView(model: model, rowID: PanelModel.addRowID)
                    }
                }
                let reminders = model.visibleReminders
                if !reminders.isEmpty {
                    groupLabel("Upcoming")
                    ForEach(reminders) { reminder in
                        reminderRow(reminder, now: context.date)
                    }
                }
                let recent = model.visibleRecent
                if !recent.isEmpty {
                    groupLabel("Recent")
                    ForEach(recent) { item in
                        row(item, now: context.date)
                    }
                }
            }
            .padding(Metrics.listInset)
            // The selection highlight slides between rows.
            .animation(.easeOut(duration: 0.14), value: model.selection)
        }
    }

    private func selectable<Label: View>(_ id: UUID, label spoken: String, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        let isSelected = model.selection == id
        return Button(action: action) {
            label()
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Metrics.selectionRadius, style: .continuous)
                            .fill(selectionFill)
                            .matchedGeometryEffect(id: "selection", in: selectionSpace)
                    }
                }
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel(spoken)
        .onContinuousHover { phase in
            if case .active = phase { withAnimation(.easeOut(duration: 0.14)) { model.hover(id: id) } }
        }
        .id(id)
    }

    @ViewBuilder private func newReminderRow(now: Date) -> some View {
        let id = PanelModel.newReminderRowID
        selectable(id, label: "New Reminder, \(ReminderBook.summary(model.app.reminders, now: now)).", action: { model.selection = id; model.activateNewReminderRow() }) {
            ReminderRowView(
                title: "New Reminder",
                presentation: RowPresentation(glyph: .chevron, subtitle: ReminderBook.summary(model.app.reminders, now: now), primary: .none),
                isSelected: model.selection == id,
                actionSymbol: "plus"
            )
        }
        if model.expansion == .reminderForm(id) {
            ReminderFormView(model: model, rowID: id)
        }
    }

    @ViewBuilder private func reminderRow(_ reminder: Reminder, now: Date) -> some View {
        let presentation = ReminderBook.presentation(reminder, now: now)
        let spoken = "\(reminder.text), \(presentation.subtitle.replacingOccurrences(of: " · ", with: ", ")). \(reminder.state == .pending ? "Change" : "Dismiss")."
        selectable(reminder.id, label: spoken, action: { model.activateReminder(reminder) }) {
            ReminderRowView(
                title: reminder.text,
                presentation: presentation,
                isSelected: model.selection == reminder.id,
                actionSymbol: reminder.state == .pending ? "pencil" : "checkmark"
            )
        }
        if model.expansion == .reminderForm(reminder.id) {
            ReminderFormView(model: model, rowID: reminder.id)
        }
    }

    private func addRow(now: Date) -> some View {
        let isSelected = model.selection == PanelModel.addRowID
        return Button {
            model.selection = PanelModel.addRowID
            model.activateAddRow()
        } label: {
            AddRowView(model: model, isSelected: isSelected, now: now)
                .accessibilityElement(children: .combine)
                .accessibilityHint("\(model.addRowFooterLabel). Tab switches between Link, Command and Reminder.")
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Metrics.selectionRadius, style: .continuous)
                            .fill(selectionFill)
                            .matchedGeometryEffect(id: "selection", in: selectionSpace)
                    }
                }
        }
        .buttonStyle(RowButtonStyle())
        .id(PanelModel.addRowID)
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.ink2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    @ViewBuilder private func row(_ item: Item, now: Date) -> some View {
        let isSelected = model.selection == item.id
        VStack(spacing: 0) {
            Button {
                model.activate(item)
            } label: {
                RowView(
                    item: item,
                    presentation: model.app.presentation(for: item, now: now),
                    isSelected: isSelected,
                    isStale: model.app.isStale(item.id, now: now)
                )
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Metrics.selectionRadius, style: .continuous)
                            .fill(selectionFill)
                            .matchedGeometryEffect(id: "selection", in: selectionSpace)
                    }
                }
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityLabel(RowPresentation.accessibilityLabel(
                item: item, service: model.app.services[item.id], task: model.app.tasks[item.id],
                problem: model.app.problems[item.id], now: now
            ))
            .onContinuousHover { phase in
                // Hover only selects; it doesn't pull the selection away from an open form.
                if case .active = phase {
                    withAnimation(.easeOut(duration: 0.14)) { model.hover(item) }
                }
            }
            if let expansion = model.expansion, expansion.itemID == item.id {
                ExpansionView(model: model, expansion: expansion, item: item)
            }
        }
        .id(item.id)
        .animation(.easeOut(duration: 0.18), value: model.expansion)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Palette.ink2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.toast ?? "")
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
                .animation(.easeOut(duration: 0.15), value: model.toast)
            Spacer(minLength: 8)
            if let label = model.reminderFooterLabel, model.expansion.map({ if case .reminderForm = $0 { true } else { false } }) == true {
                HStack(spacing: 5) {
                    Text(label)
                    KeyChip("↵")
                }
                .lineLimit(1)
            } else             if model.selection == PanelModel.addRowID, model.addRowVisible {
                HStack(spacing: 5) {
                    Text(model.addRowFooterLabel)
                    KeyChip("↵")
                }
                .lineLimit(1)
                Rectangle().fill(Palette.ink2.opacity(0.3)).frame(width: 1, height: 14)
                Button { model.presentActions() } label: {
                    HStack(spacing: 5) {
                        Text("Actions")
                        KeyChip("⌘K")
                    }
                }
                .buttonStyle(.plain)
            } else if let label = model.reminderFooterLabel {
                HStack(spacing: 5) {
                    Text(label)
                    KeyChip("↵")
                }
                .lineLimit(1)
                if model.selection != PanelModel.newReminderRowID {
                    Rectangle().fill(Palette.ink2.opacity(0.3)).frame(width: 1, height: 14)
                    Button { model.presentActions() } label: {
                        HStack(spacing: 5) {
                            Text("Actions")
                            KeyChip("⌘K")
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else if let item = model.selectedItem {
                let primary = model.app.presentation(for: item).primary
                if primary != .none {
                    HStack(spacing: 5) {
                        Text(primary.label)
                        KeyChip("↵")
                    }
                    .lineLimit(1)
                    Rectangle().fill(Palette.ink2.opacity(0.3)).frame(width: 1, height: 14)
                }
                Button { model.presentActions() } label: {
                    HStack(spacing: 5) {
                        Text("Actions")
                        KeyChip("⌘K")
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 14)
        .frame(height: Metrics.footerHeight)
    }
}

/// No highlight of its own: the selection background shows which row a click will act on.
private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}
