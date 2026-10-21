import CueCore
import SwiftUI

/// A row's state glyph (spec §14). Every state has its own shape, so color is never the only signal.
struct GlyphView: View {
    let glyph: Glyph
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            switch glyph {
            case .none:
                EmptyView()
            case .off:
                Circle().strokeBorder(Palette.unknown, lineWidth: 1.5)
                    .frame(width: 11, height: 11)
            case .starting:
                SpinnerArc(color: Palette.warn, reverse: false, reduceMotion: reduceMotion)
            case .checking:
                SpinnerArc(color: Palette.unknown, reverse: false, reduceMotion: reduceMotion)
            case .on:
                Circle().fill(Palette.ok)
                    .frame(width: 9, height: 9)
                    .scaleEffect(pulse ? 1.45 : 1)
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.easeOut(duration: 0.18)) { pulse = true } completion: {
                            withAnimation(.easeIn(duration: 0.22)) { pulse = false }
                        }
                    }
            case .stopping:
                ZStack {
                    SpinnerArc(color: Palette.warn, reverse: true, reduceMotion: reduceMotion)
                    RoundedRectangle(cornerRadius: 1).fill(Palette.warn).frame(width: 5, height: 5)
                }
            case .failed:
                ZStack {
                    Circle().fill(Palette.err).frame(width: 14, height: 14)
                    Text("!").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                }
            case .unknown:
                ZStack {
                    Circle().stroke(Palette.unknown, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                        .frame(width: 11, height: 11)
                    Circle().fill(Palette.unknown).frame(width: 3, height: 3)
                }
            case .link:
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink2)
            case .bell:
                Image(systemName: "bell").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.ink2)
            case .fired:
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ok)
            case .chevron:
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink2)
            case .plus:
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink2)
            }
        }
        .frame(width: Metrics.glyphSize, height: Metrics.glyphSize)
        .id(glyph)
        .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
        .animation(.spring(duration: 0.26), value: glyph)
    }
}

/// An arc turning once every 0.9 s over a faint track; static with Reduce Motion.
private struct SpinnerArc: View {
    let color: Color
    let reverse: Bool
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            let angle = reduceMotion ? 0 : (reverse ? -phase : phase) * 360
            ZStack {
                Circle().stroke(color.opacity(0.2), lineWidth: 1.5)
                Circle().trim(from: 0, to: 0.3)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(angle - 90))
            }
            .frame(width: 12, height: 12)
        }
    }
}
