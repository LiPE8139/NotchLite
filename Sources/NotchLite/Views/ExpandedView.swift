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
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear.frame(width: model.notchSize.width + 16)

            HStack(spacing: 8) {
                if model.media.sources.count > 1 {
                    HStack(spacing: 5) {
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
            Image(nsImage: icon)
                .resizable()
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .opacity(selected ? 1 : 0.4)
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(selected ? 0.16 : (hovering ? 0.08 : 0)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        // Hover lifts the chip, and switching sessions grows it in rather than snapping.
        .scaleEffect(selected ? 1.08 : (hovering ? 1.04 : 1))
        .animation(.spring(response: 0.28, dampingFraction: 0.64), value: selected)
        .animation(.spring(response: 0.28, dampingFraction: 0.64), value: hovering)
        .onHover { hovering = $0 }
        .help(source.displayName)
    }
}
