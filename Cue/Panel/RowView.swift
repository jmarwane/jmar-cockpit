import CueCore
import SwiftUI

/// Tile, title over subtitle, and a 30 pt accessory. The whole row is one button.
struct RowView: View {
    let item: Item
    let presentation: RowPresentation
    let isSelected: Bool
    let isStale: Bool

    var body: some View {
        HStack(spacing: 10) {
            ItemTile(icon: item.icon, tint: item.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(presentation.subtitle)
                    .font(presentation.subtitleIsMonospaced ? .system(size: 11.5, design: .monospaced) : .system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            accessory
        }
        .padding(.horizontal, 8)
        .frame(height: Metrics.rowHeight)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var accessory: some View {
        ZStack {
            if isSelected, let symbol = presentation.primary.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: Metrics.accessorySize, height: Metrics.accessorySize)
                    .background(Circle().fill(Palette.ink.opacity(0.07)))
                    .transition(.opacity)
            } else {
                GlyphView(glyph: presentation.glyph)
                    .opacity(isStale ? 0.4 : 1)
            }
        }
        .frame(width: Metrics.accessorySize, height: Metrics.accessorySize)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}

struct ItemTile: View {
    let icon: String
    let tint: Tint
    var size: CGFloat = Metrics.tileSize

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.tileRadius * size / Metrics.tileSize, style: .continuous)
            .fill(Palette.tile(tint))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil ? icon : "questionmark")
                    .font(.system(size: Metrics.tileSymbol * size / Metrics.tileSize, weight: .medium))
                    .foregroundStyle(Palette.symbol(tint))
            }
    }
}
