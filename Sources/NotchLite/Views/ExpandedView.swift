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
                    SourceStrip(model: model,
                                count: model.media.sources.count,
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

/// Three chips are always visible; more than that slides sideways under a two-finger swipe.
/// The offset is driven from trackpad events (see NotchController) because a SwiftUI ScrollView
/// does not scroll reliably inside this non-activating panel.
private struct SourceStrip<Content: View>: View {
    let model: IslandModel
    let count: Int
    let selectedID: String?
    @ViewBuilder var content: Content

    private var chipWidth: CGFloat { 20 }
    private var spacing: CGFloat { 3 }
    private var visible: Int { min(count, 3) }
    private var contentWidth: CGFloat {
        CGFloat(count) * chipWidth + CGFloat(max(0, count - 1)) * spacing
    }

    var body: some View {
        let width = CGFloat(visible) * chipWidth + CGFloat(max(0, visible - 1)) * spacing + 4

        content
            .fixedSize()
            .offset(x: model.stripScroll)
            .frame(width: width, alignment: .leading)
            .padding(.vertical, 2)
            .clipped()
            .mask(edgeFade)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { sync(viewport: width, frame: geo.frame(in: .global)) }
                        .onChange(of: count) { _, _ in sync(viewport: width, frame: geo.frame(in: .global)) }
                        .onChange(of: selectedID) { _, id in centre(on: id, viewport: width) }
                }
            )
            .help(count > 3 ? "Swipe sideways to see \(count) players" : "")
    }

    private func sync(viewport: CGFloat, frame: CGRect) {
        model.stripFrame = frame
        model.stripMaxScroll = max(0, contentWidth - viewport)
        model.stripScroll = min(0, max(-model.stripMaxScroll, model.stripScroll))
        centre(on: selectedID, viewport: viewport)
    }

    /// Puts the chosen player in the middle of the strip.
    private func centre(on id: String?, viewport: CGFloat) {
        guard let id, let index = model.media.sources.firstIndex(where: { $0.id == id }) else { return }
        let chipCentre = CGFloat(index) * (chipWidth + spacing) + chipWidth / 2
        let target = viewport / 2 - chipCentre
        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
            model.stripScroll = min(0, max(-model.stripMaxScroll, target))
        }
    }

    /// A soft right edge hints that more players are waiting.
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
