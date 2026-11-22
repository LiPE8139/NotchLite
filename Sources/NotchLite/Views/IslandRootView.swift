import SwiftUI

struct IslandRootView: View {
    let model: IslandModel

    /// Geometry moves on a smooth curve rather than a spring: any overshoot swings the shape's
    /// bottom edge past its resting place, which reads as the notch edge flickering.
    private let geometry = Animation.smooth(duration: 0.3)
    /// Content still gets a little life.
    private let content = Animation.spring(response: 0.4, dampingFraction: 0.85)

    /// How far the content travels while collapsing.
    static let collapseSlide: CGFloat = 16

    var body: some View {
        let presentation = model.presentation
        let shape = NotchShape(topRadius: model.topRadius, bottomRadius: model.bottomRadius)

        let expanded = presentation == .expanded

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // The shadow hangs off the plain black shape, not the content, so scrolling text
                // or a ticking timer doesn't force the blur to be recomputed every frame.
                shape.fill(Color.black)
                    .shadow(color: .black.opacity(0.55), radius: expanded ? 18 : 0, y: expanded ? 8 : 0)
                    // The island opens on a click, not on hover. Only the panel's background takes
                    // the tap, so the transport buttons in the wing keep their own clicks.
                    .onTapGesture { model.onTapExpand?() }
                content(for: presentation)
                    .frame(width: model.islandSize.width, height: model.islandSize.height, alignment: .top)
                    // Collapsing slides the content down and out through the shrinking shape, so the
                    // eye follows the content into the notch instead of watching the bottom edge
                    // travel across it.
                    .offset(y: expanded ? 0 : IslandRootView.collapseSlide)
                    .clipShape(shape)
            }
            .frame(width: model.islandSize.width, height: model.islandSize.height)
            // The island grows to the trailing side only, so shift it to keep the notch centred.
            .offset(x: model.islandOffset)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .animation(geometry, value: presentation)
        .animation(geometry, value: model.islandSize)
        .animation(geometry, value: model.islandOffset)
        .animation(content, value: model.tab)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func content(for presentation: Presentation) -> some View {
        switch presentation {
        case .idle:
            EmptyView()
        case .wings:
            CompactWingsView(model: model).transition(.island)
        case .peek(let kind):
            PeekView(kind: kind, model: model).transition(.island)
        case .expanded:
            ExpandedView(model: model).transition(.island)
        }
    }
}

private struct BlurModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

extension AnyTransition {
    /// Content melts in and out of the black like on the iPhone.
    static var island: AnyTransition {
        AnyTransition.modifier(active: BlurModifier(radius: 10), identity: BlurModifier(radius: 0))
            .combined(with: .opacity)
            .combined(with: .scale(scale: 0.88, anchor: .top))
    }
}

/// Lays content out on both sides of the camera housing.
struct WingsLayout<Leading: View, Trailing: View>: View {
    let notchWidth: CGFloat
    let height: CGFloat
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 0) {
            leading.frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: notchWidth)
            trailing.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, Metrics.wingInset)
        .frame(height: height)
    }
}
