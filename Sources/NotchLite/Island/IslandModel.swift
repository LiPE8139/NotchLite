import SwiftUI

enum ExpandedTab: String, CaseIterable, Identifiable {
    case home, shelf

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .shelf: "tray.full.fill"
        }
    }
}

/// Short-lived notifications that pop out of the notch and retract on their own.
enum PeekKind: Equatable {
    case nowPlaying
    case shelfAdded(Int)

    /// Text on the left wing of a banner peek (not used by `.nowPlaying`, which drops down).
    var title: String {
        switch self {
        case .shelfAdded: String(localized: "Added to Shelf")
        case .nowPlaying: ""
        }
    }

    var symbol: String {
        switch self {
        case .shelfAdded: "tray.and.arrow.down.fill"
        case .nowPlaying: "music.note"
        }
    }
}

enum Presentation: Equatable {
    /// Same size as the physical notch: invisible.
    case idle
    /// Live activity: small content on both sides of the camera.
    case wings
    case peek(PeekKind)
    case expanded
}

@Observable @MainActor
final class IslandModel {
    var notchSize = CGSize(width: 185, height: 32)
    var isExpanded = false
    var tab: ExpandedTab = .home
    var isDropTargeted = false
    /// A context menu or settings menu is open, or items are being dragged out: don't collapse underneath them.
    var isMenuOpen = false
    var isDraggingOut = false
    /// True while the pointer rests on the notch and the transport controls should show.
    var isHovering = false
    private(set) var peek: PeekKind?

    let media = NowPlayingService()
    let shelf = ShelfStore()

    @ObservationIgnored var onOpenSettings: (() -> Void)?
    @ObservationIgnored var onTapExpand: (() -> Void)?
    @ObservationIgnored private var peekTask: Task<Void, Never>?
    @ObservationIgnored private var launchDate = Date()

    var presentation: Presentation {
        if isExpanded { return .expanded }
        if let peek { return .peek(peek) }
        // Keep the wings up while hovering a paused track, so the controls stay reachable.
        if media.showsActivity || (isHovering && canShowWings) { return .wings }
        return .idle
    }

    /// Any session can own the wings now, the way the system's own Now Playing panel works.
    var canShowWings: Bool { media.hasMedia }

    /// Widths either side of the notch. The trailing side grows to fit the transport controls;
    /// the leading (cover) side never moves, so the artwork stays where the eye expects it.
    var islandSides: (leading: CGFloat, trailing: CGFloat) {
        let n = notchSize
        let flare = Metrics.compactTopRadius
        switch presentation {
        case .idle:
            return (flare, flare)
        case .wings:
            return (Metrics.wing, isHovering && canShowWings ? Metrics.controlsWing : Metrics.wing)
        case .peek(.nowPlaying):
            let side = (max(n.width + 180, 360) - n.width) / 2
            return (side, side)
        case .peek(let kind):
            let side = peekWingWidth(kind) + flare
            return (side, side)
        case .expanded:
            let side = (Metrics.expandedSize(notch: n).width - n.width) / 2
            return (side, side)
        }
    }

    /// Horizontal shift that keeps the notch itself centred when the two sides differ.
    var islandOffset: CGFloat { (islandSides.trailing - islandSides.leading) / 2 }

    var topRadius: CGFloat {
        presentation == .expanded ? Metrics.expandedTopRadius : Metrics.compactTopRadius
    }

    var bottomRadius: CGFloat {
        switch presentation {
        case .idle, .wings: 10
        case .peek(.nowPlaying): 22
        case .peek: 14
        case .expanded: 30
        }
    }

    var islandSize: CGSize {
        let n = notchSize
        let sides = islandSides
        let height: CGFloat
        switch presentation {
        case .peek(.nowPlaying): height = n.height + 54
        case .expanded: height = Metrics.expandedSize(notch: n).height
        default: height = n.height
        }
        return CGSize(width: sides.leading + n.width + sides.trailing, height: height)
    }

    /// Each side of a banner peek is sized to fit its label, so a longer translation widens
    /// the island instead of wrapping onto a second line.
    private func peekWingWidth(_ kind: PeekKind) -> CGFloat {
        let text = NSAttributedString(string: kind.title, attributes: [.font: NSFont.systemFont(ofSize: Metrics.peekFontSize, weight: .semibold)])
        let label = Metrics.peekIconWidth + Metrics.peekIconSpacing + ceil(text.size().width) + 2
        // Each wing must be wide enough for the label plus whatever WingsLayout insets it by,
        // minus the half of the rounded shoulder that already sits outside the wing.
        return max(label, Metrics.peekTrailingWidth) + Metrics.wingInset - Metrics.compactTopRadius
    }

    func startServices() {
        shelf.onAdded = { [weak self] count in self?.showPeek(.shelfAdded(count), seconds: 2.2) }
        media.onTrackChange = { [weak self] in
            guard let self, Date().timeIntervalSince(self.launchDate) > 3 else { return }
            self.showPeek(.nowPlaying, seconds: 3)
        }
        media.start()
    }

    func showPeek(_ kind: PeekKind, seconds: Double = 2.6) {
        guard !isExpanded else { return }
        // Switching tracks from the hover controls must not pull the controls away.
        if case .nowPlaying = kind, isHovering { return }
        peekTask?.cancel()
        peek = kind
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.peek = nil
        }
    }

    func clearPeek() {
        peekTask?.cancel()
        peek = nil
    }
}
