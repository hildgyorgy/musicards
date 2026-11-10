#if os(iOS) && DEBUG
import SwiftUI

/// Opt-in development experiment; Release builds keep the shipping deck.
enum SideMeterDeckPreview {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MUSICARDS_SIDE_METER_PREVIEW"] == "1"
    }

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
            let isOpen = systemInsets.trailing < 48
            let topInset: CGFloat = isOpen ? DeckStyle.horizontalInset : 12
            // The rail reuses the system's side inset below its reserved
            // regions, instead of reserving another strip inside the safe area.
            let railWidth = max(48, systemInsets.trailing, proxy.size.width * 0.16)
            let deckWidth = max(0, proxy.size.width - systemInsets.leading - railWidth)
            let width = systemInsets.leading + deckWidth + railWidth
            let leading = (proxy.size.width - width) / 2
            let rail = CGRect(x: leading + systemInsets.leading + deckWidth,
                              y: 0, width: railWidth, height: proxy.size.height)
            let reservedBottom = occlusions(in: proxy)
                .filter { $0.intersects(rail) }
                .map(\.maxY).max() ?? 0
            let meterTop = max(reservedBottom + 20, DeckStyle.peek * 4 + DeckStyle.cardLabelHitHeight + 36)
            let meterBottom = max(meterTop, proxy.size.height - 32)
            let cardFrame = CGRect(
                x: leading + systemInsets.leading + DeckStyle.horizontalInset,
                y: topInset,
                width: max(0, deckWidth - DeckStyle.horizontalInset * 2),
                height: max(0, proxy.size.height - topInset - DeckStyle.cardBottomInset)
            )
            HStack(spacing: 0) {
                content()
                    .padding(.top, topInset)
                    .environment(\.deckCornerRadiusOverride,
                                 isOpen ? cornerRadius(in: proxy, cardFrame: cardFrame) : nil)
                    .frame(width: deckWidth)
                VStack(spacing: 0) {
                    if meterBottom > meterTop {
                        SideSignalMeter(controller: controller)
                            .frame(width: 18, height: meterBottom - meterTop)
                            .padding(.top, meterTop)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: railWidth, height: proxy.size.height, alignment: .top)
            }
            .padding(.leading, systemInsets.leading)
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
            return proxy.reservedRegions(kind: .occlusion).map(\.frame)
        }
        return []
    }
}

private struct SideSignalMeter: View {
    @ObservedObject var controller: PlaybackController
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
                PlaybackSignalMeter(
                    left: PlaybackSignalLevels.displayFraction(levels.left),
                    right: PlaybackSignalLevels.displayFraction(levels.right),
                    axis: .vertical
                )
                .animation(.linear(duration: 0.1), value: levels)
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
