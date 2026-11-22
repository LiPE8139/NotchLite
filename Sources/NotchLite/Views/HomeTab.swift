import SwiftUI

struct HomeTab: View {
    let model: IslandModel

    var body: some View {
        MediaCard(media: model.media)
            .frame(maxWidth: .infinity)
    }
}

/// Spring tuned to match morphicons' feel: quick, with a slight overshoot.
enum MediaMotion {
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.68)
}

private struct MediaCard: View {
    let media: NowPlayingService
    @ViewState private var artworkHovering = false

    var body: some View {
        if media.hasMedia {
            HStack(spacing: 16) {
                artwork
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        MarqueeText(text: media.title, font: .system(size: 15, weight: .semibold), height: 19)
                        if media.supportsLike {
                            // NetEase cannot report the flag, so its heart only lights while the
                            // optimistic value is set right after the press.
                            let liked = media.isLoved
                            Button { media.toggleLoved() } label: {
                                Image(systemName: liked ? "heart.fill" : "heart")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(liked ? Color.red : Color.white.opacity(0.4))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(liked ? "Remove from loved" : "Love this track")
                        }
                    }
                    Text(media.artist.isEmpty ? (media.album.isEmpty ? "Not playing" : media.album) : media.artist)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    ScrubBar(media: media)
                    controls
                }
            }
        } else {
            HStack(spacing: 14) {
                ArtworkView(image: nil, size: 86, corner: 16).opacity(0.5)
                VStack(alignment: .leading, spacing: 8) {
                    Text(media.isAvailable ? String(localized: "Nothing playing") : String(localized: "Can't read Now Playing"))
                        .font(.system(size: 14, weight: .semibold))
                    Text("Play something in Music, Spotify or YouTube and it shows up here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Music") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Music.app"))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.14)))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var artwork: some View {
        ZStack {
            ArtworkView(image: media.artwork, size: 104, corner: 20)
                // Keyed on the artwork itself: the fade starts when the new image actually lands,
                // not when the track metadata does.
                .id(media.artworkIdentity)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.45), value: media.artworkIdentity)
            // Hovering lifts the cover and glows in the album's own colour.
            .shadow(color: media.accent.opacity(artworkHovering ? 0.85 : 0.55),
                    radius: artworkHovering ? 26 : 16)
            .overlay(alignment: .bottomTrailing) {
                if let icon = media.playerIcon {
                    Image(nsImage: icon).resizable().frame(width: 26, height: 26).offset(x: 7, y: 7)
                }
            }
            .scaleEffect(artworkHovering ? 1.1 : (media.isPlaying ? 1 : 0.92))
            .onHover { artworkHovering = $0 }
            .animation(MediaMotion.spring, value: artworkHovering)
            .animation(MediaMotion.spring, value: media.isPlaying)
            .onTapGesture { media.openPlayerApp() }
            // Two-finger style swipe over the cover cycles the sessions that are playing.
            .gesture(DragGesture(minimumDistance: 24).onEnded { value in
                if value.translation.height < -24 { media.selectNext() }
                else if value.translation.height > 24 { media.selectPrevious() }
            })
            .help("Open the playing app")
    }

    private var controls: some View {
        HStack(spacing: 18) {
            IconButton(symbol: "backward.fill", size: 13) { media.previous() }
            IconButton(symbol: media.isPlaying ? "pause.fill" : "play.fill", size: 18) { media.togglePlayPause() }
                .contentTransition(.symbolEffect(.replace))
            IconButton(symbol: "forward.fill", size: 13) { media.next() }
        }
        .frame(maxWidth: .infinity)
        .animation(MediaMotion.spring, value: media.isPlaying)
        .disabled(!media.canControl)
        .opacity(media.canControl ? 1 : 0.35)
    }
}

/// Playback position with drag-to-seek.
private struct ScrubBar: View {
    let media: NowPlayingService

    @ViewState private var dragProgress: Double?
    /// Where the user let go. Held until the reported position catches up, otherwise the bar snaps
    /// back to the old spot for the ~400 ms the bridge needs to notice the seek.
    @ViewState private var settleTarget: Double?
    @ViewState private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let elapsed = media.elapsed(at: context.date)
            let live = media.duration > 0 ? elapsed / media.duration : 0
            let progress = dragProgress ?? settleTarget ?? live
            HStack(spacing: 8) {
                Text(format(dragProgress.map { $0 * media.duration } ?? elapsed))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(hovering || dragProgress != nil ? 0.3 : 0.18))
                        Capsule()
                            .fill(media.accent)
                            .frame(width: geo.size.width * progress)
                            .shadow(color: media.accent.opacity(hovering || dragProgress != nil ? 0.9 : 0),
                                    radius: hovering || dragProgress != nil ? 6 : 0)
                    }
                    .frame(height: (dragProgress == nil && !hovering) ? 4 : 7)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { dragProgress = min(max($0.location.x / geo.size.width, 0), 1) }
                        .onEnded { _ in
                            if let p = dragProgress {
                                settleTarget = p
                                media.seek(to: p * media.duration)
                                Task { @MainActor in
                                    try? await Task.sleep(for: .seconds(1.2))
                                    withAnimation(.easeOut(duration: 0.25)) { settleTarget = nil }
                                }
                            }
                            dragProgress = nil
                        })
                }
                .frame(height: 12)
                .onHover { hovering = $0 }
                .animation(.spring(response: 0.26, dampingFraction: 0.7), value: hovering)
                // Seeking only works where we can actually set a position.
                .allowsHitTesting(media.canSeek)
                Text("-" + format(max(0, media.duration - elapsed)))
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
            .animation(.spring(response: 0.25), value: dragProgress == nil)
        }
    }

    private func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
