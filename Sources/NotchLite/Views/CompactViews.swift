import SwiftUI

/// Live activity beside the notch: album art on the left, visualizer on the right.
struct CompactWingsView: View {
    let model: IslandModel

    var body: some View {
        let media = model.media
        WingsLayout(notchWidth: model.notchSize.width, height: model.notchSize.height) {
            SwappingCover(media: media, size: 24, corner: 7)
                .allowsHitTesting(false)
        } trailing: {
            if model.isHovering && model.canShowWings {
                TransportControls(media: media)
            } else {
                WaveformView(isPlaying: media.isPlaying, color: media.accent)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: media.artworkIdentity)
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
            WingControl(symbol: "backward.fill", size: 12, glow: media.accent, help: "Previous") { media.previous() }
            // Play/pause is the primary action, so it reads a size larger than its neighbours.
            WingControl(symbol: media.isPlaying ? "pause.fill" : "play.fill", size: 16,
                        glow: media.accent, help: "Play or pause") { media.togglePlayPause() }
            WingControl(symbol: "forward.fill", size: 12, glow: media.accent, help: "Next") { media.next() }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.68), value: media.isPlaying)
        .disabled(!media.canControl)
        .opacity(media.canControl ? 1 : 0.35)
    }
}

/// One wing control: grows under the pointer, squashes on click, and morphs between glyphs.
private struct WingControl: View {
    let symbol: String
    let size: CGFloat
    var glow: Color = .white
    let help: String
    let action: () -> Void

    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .shadow(color: hovering ? glow.opacity(1) : .clear, radius: hovering ? 10 : 0)
                .frame(width: 18, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .scaleEffect(hovering ? 1.1 : 1)
        .animation(.spring(response: 0.26, dampingFraction: 0.62), value: hovering)
        .onHover { hovering = $0 }
        .help(help)
    }
}
