//
//  DeckCardView.swift
//

#if os(iOS)
import SwiftUI

struct DeckCardView<ID: Hashable, CollapsedHeaderContent: View, HeaderContent: View, CardContent: View>: View {
    let card: DeckCard<ID>
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let bottomCornerRadius: CGFloat
    let isActive: Bool
    let showsCollapsedHeader: Bool
    let onTap: () -> Void
    let isPanEnabled: Bool
    let onPanBegan: (() -> Void)?
    let onPanChanged: (CGFloat) -> Void
    let onPanEnded: (_ translationY: CGFloat, _ velocityY: CGFloat) -> Void

    let collapsedHeader: CollapsedHeaderContent
    let header: HeaderContent
    let content: CardContent

    init(
        card: DeckCard<ID>,
        cardWidth: CGFloat,
        cardHeight: CGFloat,
        bottomCornerRadius: CGFloat,
        isActive: Bool,
        showsCollapsedHeader: Bool,
        onTap: @escaping () -> Void,
        isPanEnabled: Bool,
        onPanBegan: (() -> Void)? = nil,
        onPanChanged: @escaping (CGFloat) -> Void,
        onPanEnded: @escaping (_ translationY: CGFloat, _ velocityY: CGFloat) -> Void,
        @ViewBuilder collapsedHeader: () -> CollapsedHeaderContent,
        @ViewBuilder header: () -> HeaderContent,
        @ViewBuilder content: () -> CardContent
    ) {
        self.card = card
        self.cardWidth = cardWidth
        self.cardHeight = cardHeight
        self.bottomCornerRadius = bottomCornerRadius
        self.isActive = isActive
        self.showsCollapsedHeader = showsCollapsedHeader
        self.onTap = onTap
        self.isPanEnabled = isPanEnabled
        self.onPanBegan = onPanBegan
        self.onPanChanged = onPanChanged
        self.onPanEnded = onPanEnded
        self.collapsedHeader = collapsedHeader()
        self.header = header()
        self.content = content()
    }

    @Environment(\.colorScheme) private var colorScheme

    var cardBackground: Color {
        colorScheme == .dark
            ? DeckStyle.darkCardBackgroundColor
            : DeckStyle.lightCardBackgroundColor
    }

    var strokeColor: Color {
        colorScheme == .dark
            ? DeckStyle.strokeDark
            : DeckStyle.strokeLight
    }

    private var cardShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: DeckStyle.topCornerRadius,
            bottomLeadingRadius: bottomCornerRadius,
            bottomTrailingRadius: bottomCornerRadius,
            topTrailingRadius: DeckStyle.topCornerRadius,
            style: .continuous
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            cardContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(
            width: cardWidth,
            height: cardHeight,
            alignment: .top
        )
        .background(cardBackground)
        .clipShape(cardShape)
        .overlay(
            cardShape
                .stroke(strokeColor, lineWidth: DeckStyle.strokeWidth)
        )
        .overlay {
            if colorScheme == .dark && isActive {
                ZStack {
                    cardShape
                        .stroke(
                            LinearGradient(
                                colors: [
                                    DeckStyle.glassEdgeHighlight,
                                    DeckStyle.glassEdgeBlue.opacity(
                                        DeckStyle.activeGlassEdgeStrength
                                    ),
                                    DeckStyle.glassEdgeBlue.opacity(0.24)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: DeckStyle.neonCoreWidth
                        )
                        .shadow(
                            color: DeckStyle.glassEdgeBlue.opacity(0.28),
                            radius: 5
                        )

                    cardShape
                        .stroke(
                            DeckStyle.glassEdgeBlue.opacity(
                                DeckStyle.activeTopEdgeStrength
                            ),
                            lineWidth: DeckStyle.neonCoreWidth
                        )
                        .mask(alignment: .top) {
                            Color.white
                                .frame(
                                    height: DeckStyle.topCornerRadius
                                        + DeckStyle.neonCoreWidth
                                )
                        }
                        .shadow(
                            color: DeckStyle.glassEdgeBlue.opacity(
                                DeckStyle.activeGlassGlowStrength
                            ),
                            radius: DeckStyle.activeGlassGlowRadius
                        )
                }
                .allowsHitTesting(false)
            }
        }
        .shadow(
            color: DeckStyle.shadowColor,
            radius: DeckStyle.shadowRadius,
            y: DeckStyle.shadowYOffset
        )
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBarView

            if !isShowingCollapsedHeader {
                Spacer().frame(height: DeckStyle.headerTopSpacing)

                header

                Spacer().frame(height: DeckStyle.contentTopSpacing)

                content
            }
        }
        .padding(.horizontal, DeckStyle.contentHorizontalPadding)
    }

    private var topBarView: some View {
        ZStack(alignment: .topTrailing) {
            PanHandleView(
                isTapEnabled: true,
                isPanEnabled: isPanEnabled,
                onTap: onTap,
                onBegan: onPanBegan,
                onChanged: onPanChanged,
                onEnded: onPanEnded
            )
            .frame(height: topBarHeight)

            if isShowingCollapsedHeader {
                collapsedHeader
                    .frame(
                        maxWidth: .infinity,
                        minHeight: DeckStyle.topCornerRadius * 2,
                        maxHeight: DeckStyle.topCornerRadius * 2
                    )
                    .transition(.opacity)
            } else {
                Text(card.cardLabel)
                    .font(DeckStyle.cardLabelFont)
                    .tracking(DeckStyle.cardLabelTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(
                        colorScheme == .dark && isActive
                            ? DeckStyle.activeCardLabelColor
                            : DeckStyle.cardLabelColor
                    )
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, DeckStyle.cardLabelTopPadding)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: topBarHeight, alignment: .top)
        .animation(DeckStyle.animation, value: isShowingCollapsedHeader)
    }

    private var isShowingCollapsedHeader: Bool {
        !isActive && showsCollapsedHeader
    }

    private var topBarHeight: CGFloat {
        isShowingCollapsedHeader
            ? DeckStyle.collapsedPlayerHeight
            : DeckStyle.cardLabelHitHeight
    }
}
#endif
