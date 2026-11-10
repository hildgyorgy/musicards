#if os(iOS)
import SwiftUI

/// Detects a phone layout with a dedicated system rail or folding display.
enum SideMeterDeviceLayout {

    static func supportsSideRail(in viewport: GeometryProxy) -> Bool {
        if viewport.safeAreaInsets.trailing >= 48 { return true }
        if #available(iOS 27.1, *) {
            // A fold remains identifiable on the open display even when its
            // division is inactive. Ordinary phones have no such region.
            return !viewport.reservedRegions(kind: .division, options: .includeInactive).isEmpty
        }
        return false
    }
}

struct SideMeterDeckLayout<Content: View>: View {
    let controller: PlaybackController
    var systemInsets: EdgeInsets = EdgeInsets()
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let isTablet = UIDevice.current.userInterfaceIdiom == .pad
            let isOpen = !isTablet && systemInsets.trailing < 48
            let topInset: CGFloat = isTablet ? 32 : (isOpen ? 8 : 12)
            let leftInset = isTablet ? max(systemInsets.leading, min(60, proxy.size.width * 0.065)) : systemInsets.leading
            // The rail reuses the system's side inset below its reserved
            // regions, instead of reserving another strip inside the safe area.
            let railWidth = max(isTablet ? 100 : 48, systemInsets.trailing, proxy.size.width * 0.16)
            let deckWidth = max(0, proxy.size.width - leftInset - railWidth)
            let width = leftInset + deckWidth + railWidth
            let leading = (proxy.size.width - width) / 2
            let rail = CGRect(x: leading + leftInset + deckWidth,
                              y: 0, width: railWidth, height: proxy.size.height)
            let reservedRegions = occlusions(in: proxy).filter { $0.intersects(rail) }
            let reservedBottom = reservedRegions
                .filter { $0.midY < proxy.size.height / 2 }
                .map(\.maxY).max() ?? 0
            let meterTop = max(reservedBottom + 20, DeckStyle.peek * 4 + DeckStyle.cardLabelHitHeight + 36)
            // iPad's bottom-right resize handle also occupies the rail. It
            // limits the bottom, rather than pushing the meter below the screen.
            let reservedTop = reservedRegions
                .filter { $0.midY >= proxy.size.height / 2 }
                .map(\.minY).min() ?? proxy.size.height
            let meterBottom = max(meterTop, min(proxy.size.height - 32, reservedTop - 20))
            let cardFrame = CGRect(
                x: leading + leftInset + 8,
                y: topInset,
                width: max(0, deckWidth - 16),
                height: max(0, proxy.size.height - topInset - DeckStyle.cardBottomInset)
            )
            HStack(spacing: 0) {
                content()
                    .padding(.top, topInset)
                    .padding(.bottom, isTablet ? 24 : 0)
                    .environment(\.deckCornerRadiusOverride,
                                 isOpen ? cornerRadius(in: proxy, cardFrame: cardFrame) : nil)
                    .frame(width: deckWidth)
                VStack(spacing: 0) {
                    if meterBottom > meterTop {
                        SideSignalMeter(controller: controller, showsChannelLabels: isTablet)
                            .frame(width: isTablet ? 70 : 18, height: meterBottom - meterTop)
                            .padding(.top, meterTop)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: railWidth, height: proxy.size.height, alignment: .top)
            }
            .padding(.leading, leftInset)
            .frame(width: width, height: proxy.size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.usesSideSignalMeter, true)
        }
    }

    private func cornerRadius(in proxy: GeometryProxy, cardFrame: CGRect) -> CGFloat? {
        if #available(iOS 27.0, *),
           let radii = proxy.concentricCornerRadii(in: cardFrame), radii.topLeading > 0 {
            // The system accounts for the card's inset from the display edge.
            return radii.topLeading
        }
        return nil
    }

    private func occlusions(in proxy: GeometryProxy) -> [CGRect] {
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .occlusion)
                .filter { $0.isActive }
                .map(\.frame)
                // A container-sized bounding frame cannot locate a small
                // control within it. Only localized obstructions bound the rail.
                .filter { $0.height < proxy.size.height / 2 }
        }
        return []
    }
}

private struct SideSignalMeter: View {
    @ObservedObject var controller: PlaybackController
    var showsChannelLabels = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var observerID = UUID()

    var body: some View {
        ZStack {
            // Keep a mounted view before the first measurement arrives, so
            // onAppear can acquire metering even without opening Player first.
            Color.clear
            if !reduceMotion, controller.externalOutputDisplayName == nil,
               let levels = controller.signalLevels {
                VStack(spacing: 10) {
                    PlaybackSignalMeter(
                        left: PlaybackSignalLevels.displayFraction(levels.left),
                        right: PlaybackSignalLevels.displayFraction(levels.right),
                        axis: .vertical
                    )
                    .frame(width: showsChannelLabels ? 28 : 18)
                    .frame(maxHeight: .infinity)
                    .animation(.linear(duration: 0.1), value: levels)
                    if showsChannelLabels {
                        HStack {
                            Text("L")
                            Spacer()
                            Text("R")
                        }
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { updateMetering() }
        .onDisappear { controller.setSignalMeteringActive(false, observerID: observerID) }
        .onChange(of: scenePhase) { _, _ in updateMetering() }
        .onChange(of: reduceMotion) { _, _ in updateMetering() }
        .onChange(of: controller.externalOutputDisplayName) { _, _ in updateMetering() }
    }

    private func updateMetering() {
        controller.setSignalMeteringActive(
            scenePhase == .active && !reduceMotion && controller.externalOutputDisplayName == nil,
            observerID: observerID
        )
    }
}
#endif
