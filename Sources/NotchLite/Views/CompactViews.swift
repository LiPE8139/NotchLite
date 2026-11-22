import SwiftUI

/// Live activity beside the notch: album art on the left, visualizer on the right.
struct CompactWingsView: View {
    let model: IslandModel

    var body: some View {
        let media = model.media
        WingsLayout(notchWidth: model.notchSize.width, height: model.notchSize.height) {
            ArtworkView(image: media.artwork, size: 24, corner: 7)
                .allowsHitTesting(false)
        } trailing: {
            if model.isHovering && model.canShowWings {
                TransportControls(media: media)
            } else {
                WaveformView(isPlaying: media.isPlaying, color: media.accent)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct PeekView: View {
    let kind: PeekKind
    let model: IslandModel

    var body: some View {
        switch kind {
        case .shelfAdded(let count):
            WingsLayout(notchWidth: model.notchSize.width, height: model.notchSize.height) {
                PeekLabel(kind: kind, color: .white)
            } trailing: {
                if count > 1 {
                    Text("+\(count)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.green)
                }
            }

        case .nowPlaying:
            VStack(spacing: 0) {
                Color.clear.frame(height: model.notchSize.height)
                HStack(spacing: 10) {
                    ArtworkView(image: model.media.artwork, size: 36, corner: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.media.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(model.media.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    WaveformView(isPlaying: model.media.isPlaying, color: model.media.accent)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 10)
                .frame(maxHeight: .infinity)
            }
        }
    }
}

/// Icon + title for banner peeks. Its metrics mirror `IslandModel.peekWingWidth`, which sizes the island to fit.
private struct PeekLabel: View {
    let kind: PeekKind
    let color: Color

    var body: some View {
        HStack(spacing: Metrics.peekIconSpacing) {
            Image(systemName: kind.symbol)
                .frame(width: Metrics.peekIconWidth)
            Text(kind.title)
                .lineLimit(1)
                .fixedSize()
        }
        .font(.system(size: Metrics.peekFontSize, weight: .semibold))
        .foregroundStyle(color)
    }
}


/// Previous / play-pause / next, shown in the trailing wing while the pointer rests on the notch.
private struct TransportControls: View {
    let media: NowPlayingService

    var body: some View {
        HStack(spacing: 3) {
            button("backward.fill", size: 12, help: "Previous") { media.previous() }
            // Play/pause is the primary action, so it reads a size larger than its neighbours.
            button(media.isPlaying ? "pause.fill" : "play.fill", size: 16, help: "Play or pause") {
                media.togglePlayPause()
            }
            button("forward.fill", size: 12, help: "Next") { media.next() }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.68), value: media.isPlaying)
        .disabled(!media.canControl)
        .opacity(media.canControl ? 1 : 0.35)
    }

    /// Every control gets the same 18 × 20 hit area, so the row stays optically even although the
    /// glyphs differ in width — and nothing sits against the wing's edge where it would be clipped.
    private func button(_ symbol: String, size: CGFloat,
                        help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                // Morph between glyphs instead of cross-fading, like morphicons.
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 18, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(help)
    }
}
