import SwiftUI

struct ExpandedView: View {
    let model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: model.notchSize.height)
            Group {
                switch model.tab {
                case .home:
                    HomeTab(model: model)
                        .transition(Self.tabIn)
                case .shelf:
                    ShelfTab(model: model)
                        .transition(Self.tabIn)
                }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: model.tab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 22)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .padding(.horizontal, Metrics.expandedTopRadius)
        .foregroundStyle(.white)
    }

    /// Switching tabs slides the new page up from just below the notch while the old one fades.
    private static let tabIn = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .offset(y: -10)).combined(with: .scale(scale: 0.985, anchor: .top)),
        removal: .opacity.combined(with: .offset(y: 6)))

    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(ExpandedTab.allCases) { tab in
                    TabButton(tab: tab, isSelected: model.tab == tab) { model.tab = tab }
                }
            }
            // Fixed rather than flexible: the source strip needs the room more than the tabs do.
            .frame(width: 64, alignment: .leading)

            Color.clear.frame(width: model.notchSize.width + 10)

            // The strip's own trailing padding already separates it from the gear, so the stack
            // spacing can be minimal: this is what shifts the strip right without moving the gear.
            HStack(spacing: 1) {
                if model.media.sources.count > 1 {
                    // A strip that stays three chips wide: past that it scrolls with a two-finger
                    // swipe instead of squeezing the row into the notch.
                    SourceStrip(count: model.media.sources.count,
                                selectedID: model.media.selected?.id) {
                        HStack(spacing: 3) {
                            ForEach(model.media.sources) { source in
                                SourceChip(source: source,
                                           selected: source.id == model.media.selected?.id,
                                           icon: model.media.icon(for: source.bundleID)) {
                                    model.media.select(source.id)
                                    // Picking a player from the header should show it, wherever we are.
                                    model.tab = .home
                                }
                            }
                        }
                    }
                }
                IconButton(symbol: "gearshape.fill", size: 12, help: "Settings") {
                    model.onOpenSettings?()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
    }
}

private struct TabButton: View {
    let tab: ExpandedTab
    let isSelected: Bool
    let action: () -> Void

    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.5))
                .frame(width: 30, height: 22)
                .background(Capsule().fill(.white.opacity(isSelected ? 0.16 : (hovering ? 0.08 : 0))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}


/// One session in the header switcher. Dimmed until it is the one being shown.
private struct SourceChip: View {
    let source: MediaSource
    let selected: Bool
    let icon: NSImage
    let action: () -> Void

    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            // No plate behind the icon: it only ever got clipped by the notch. Size and glow carry
            // the states instead.
            Image(nsImage: icon)
                .resizable()
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .opacity(selected ? 1 : (hovering ? 0.8 : 0.45))
                .padding(2)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        // Size and brightness only: a glow spills past the icon and gets clipped by the panel
        // edge and the scroll viewport.
        .scaleEffect(selected ? 1.18 : (hovering ? 1.1 : 1))
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: selected)
        .animation(.spring(response: 0.28, dampingFraction: 0.62), value: hovering)
        .onHover { hovering = $0 }
        .help(source.displayName)
    }
}

/// Three chips are always visible; more than that scrolls horizontally under a two-finger swipe,
/// with soft edges hinting there is more to the side.
private struct SourceStrip<Content: View>: View {
    let count: Int
    let selectedID: String?
    @ViewBuilder var content: Content

    private var chipWidth: CGFloat { 20 }
    private var spacing: CGFloat { 3 }
    private var visible: Int { min(count, 3) }

    var body: some View {
        // Cell width, gaps, and 4pt of slack so the 1.18× selected icon is not clipped.
        let width = CGFloat(visible) * chipWidth + CGFloat(max(0, visible - 1)) * spacing + 4
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                content
                    .scrollTargetLayout()
                    .padding(.leading, 4)
                    .padding(.trailing, 4)
                    .padding(.vertical, 2)
            }
            .frame(width: width)
            // Rest on a chip, never half way across one: a partly scrolled chip used to read as if
            // the notch were covering it.
            .scrollTargetBehavior(.viewAligned)
            .mask(edgeFade)
            .help(count > 3 ? "Swipe sideways to see \(count) players" : "")
            // Picking a player brings it to the middle of the strip, so the current session is
            // never half hidden at an edge.
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onAppear {
                guard let id = selectedID else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    /// A soft right edge hints that more players are waiting; the left edge stays solid so the
    /// first chip is never partially faded.
    private var edgeFade: some View {
        HStack(spacing: 0) {
            Rectangle()
            if count > 3 {
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 7)
            }
        }
    }
}
