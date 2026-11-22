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
    /// The cover's edge length; the text column is pinned to the same height.
    static let coverSize: CGFloat = 112

    let media: NowPlayingService
    @ViewState private var artworkHovering = false
    /// The cover actually on screen, and the incoming one while a change is loading.
    @ViewState private var shownArtwork: NSImage?
    @ViewState private var incomingArtwork: NSImage?
    @ViewState private var incomingOpacity: Double = 0
    /// Scale of the tile: shrinks the moment the user asks for another track.
    @ViewState private var coverScale: CGFloat = 1
    /// True from the click until the new cover has been swapped in.
    @ViewState private var awaitingCover = false
    /// Gentle pulse while the new cover is loading, so the wait never looks frozen.
    @ViewState private var breathing = false

    var body: some View {
        if media.hasMedia {
            HStack(alignment: .top, spacing: 16) {
                artwork
                // Fixed to the cover's height and top-aligned with it, so the two columns share one
                // baseline at both ends instead of each centring itself.
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
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
                        }

                    // Same treatment as the cover: a new identity per track cross-fades the text.
                    .id(media.trackIdentity)
                    .transition(.opacity)
                    // Breathing room between the text and the timeline.
                    Spacer(minLength: 6)
                    ScrubBar(media: media)
                    // Snug against the timeline: the controls belong to it.
                    controls
                        .padding(.top, 6)
                }
                .frame(height: MediaCard.coverSize, alignment: .top)
                .animation(.easeInOut(duration: 0.45), value: media.trackIdentity)
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

    /// Called the instant the user asks for another track: the tile reacts immediately instead of
    /// waiting for the artwork to arrive.
    private func beginCoverLoad() {
        guard !awaitingCover else { return }
        awaitingCover = true
        withAnimation(.easeIn(duration: 0.14)) { coverScale = 0.86 }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { breathing = true }
        // Nothing arrived (a player with no artwork): go back to full size.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard awaitingCover else { return }
            finishCoverSwap(with: nil)
        }
    }

    /// Dissolves the old cover into the new one while the tile is small, then grows it back.
    /// The grow starts just before the dissolve ends, so the two motions overlap instead of
    /// queueing up.
    private func swapIn(_ next: NSImage?) {
        withAnimation(.easeOut(duration: 0.18)) { breathing = false }
        incomingArtwork = next
        incomingOpacity = 0
        // Next turn, so the incoming tile is laid out at 0 before it fades in.
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.32)) { incomingOpacity = 1 }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(280))
                withAnimation(.spring(response: 0.34, dampingFraction: 0.68)) { coverScale = 1 }
                try? await Task.sleep(for: .milliseconds(60))
                finishCoverSwap(with: next)
            }
        }
    }

    private func finishCoverSwap(with next: NSImage?) {
        withAnimation(.easeOut(duration: 0.18)) { breathing = false }
        if let next { shownArtwork = next }
        incomingArtwork = nil
        incomingOpacity = 0
        awaitingCover = false
        if coverScale != 1 {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.68)) { coverScale = 1 }
        }
    }

    private var artwork: some View {
        ZStack {
            ArtworkView(image: shownArtwork ?? media.artwork, size: MediaCard.coverSize, corner: 22)
            if let incoming = incomingArtwork {
                ArtworkView(image: incoming, size: MediaCard.coverSize, corner: 22)
                    .opacity(incomingOpacity)
            }
        }
        .scaleEffect(coverScale * (breathing ? 1.023 : 1))
        .onChange(of: media.artworkIdentity) { _, _ in
            // No click involved (the track ended by itself): start the same sequence now.
            if !awaitingCover { beginCoverLoad() }
            swapIn(media.artwork)
        }
        .onAppear { shownArtwork = media.artwork }
            // Hovering lifts the cover and glows in the album's own colour.
            .shadow(color: media.accent.opacity(artworkHovering ? 0.85 : 0.55),
                    radius: artworkHovering ? 26 : 16)
            .overlay(alignment: .bottomTrailing) {
                if let icon = media.playerIcon {
                    Image(nsImage: icon).resizable().frame(width: 26, height: 26).offset(x: 7, y: 7)
                }
            }
            // Only the hover lift scales the cover now: tying it to playback state made it shrink
            // a second time whenever a track change briefly reported "paused".
            .scaleEffect(artworkHovering ? 1.1 : 1)
            .onHover { artworkHovering = $0 }
            .animation(MediaMotion.spring, value: artworkHovering)
            .onTapGesture { media.openPlayerApp() }
            // Two-finger style swipe over the cover cycles the sessions that are playing.
            .gesture(DragGesture(minimumDistance: 24).onEnded { value in
                if value.translation.height < -24 { media.selectNext() }
                else if value.translation.height > 24 { media.selectPrevious() }
            })
            .help("Open the playing app")
    }

    private var controls: some View {
        HStack(spacing: 22) {
            IconButton(symbol: "backward.fill", size: 15) { beginCoverLoad(); media.previous() }
            IconButton(symbol: media.isPlaying ? "pause.fill" : "play.fill", size: 22) { media.togglePlayPause() }
                .contentTransition(.symbolEffect(.replace))
            IconButton(symbol: "forward.fill", size: 15) { beginCoverLoad(); media.next() }
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
