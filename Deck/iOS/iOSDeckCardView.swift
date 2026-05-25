//
//  DeckCardView.swift
//

#if os(iOS)
import SwiftUI

struct DeckCardView<ID: Hashable, HeaderContent: View, CardContent: View>: View {
    let card: DeckCard<ID>
    let onTap: () -> Void
    let isPanEnabled: Bool
    let onPanBegan: (() -> Void)?
    let onPanChanged: (CGFloat) -> Void
    let onPanEnded: (_ translationY: CGFloat, _ velocityY: CGFloat) -> Void

    let header: HeaderContent
    let content: CardContent

    init(
        card: DeckCard<ID>,
        onTap: @escaping () -> Void,
        isPanEnabled: Bool,
        onPanBegan: (() -> Void)? = nil,
        onPanChanged: @escaping (CGFloat) -> Void,
        onPanEnded: @escaping (_ translationY: CGFloat, _ velocityY: CGFloat) -> Void,
        @ViewBuilder header: () -> HeaderContent,
        @ViewBuilder content: () -> CardContent
    ) {
        self.card = card
        self.onTap = onTap
        self.isPanEnabled = isPanEnabled
        self.onPanBegan = onPanBegan
        self.onPanChanged = onPanChanged
        self.onPanEnded = onPanEnded
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

    var body: some View {
        ZStack(alignment: .top) {
            cardContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(cardBackground)
        .clipShape(
            RoundedRectangle(cornerRadius: DeckStyle.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DeckStyle.cornerRadius, style: .continuous)
                .strokeBorder(strokeColor, lineWidth: DeckStyle.strokeWidth)
        )
        .shadow(
            color: DeckStyle.shadowColor,
            radius: DeckStyle.shadowRadius,
            y: DeckStyle.shadowYOffset
        )
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBarView

            Spacer().frame(height: DeckStyle.headerTopSpacing)

            header

            Spacer().frame(height: DeckStyle.contentTopSpacing)

            content
        }
        .padding(.horizontal, DeckStyle.contentHorizontalPadding)
    }

    private var topBarView: some View {
        ZStack(alignment: .topTrailing) {
            Text(card.cardLabel)
                .font(DeckStyle.cardLabelFont)
                .tracking(DeckStyle.cardLabelTracking)
                .textCase(.uppercase)
                .foregroundStyle(DeckStyle.cardLabelColor)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, DeckStyle.cardLabelTopPadding)

            PanHandleView(
                isEnabled: isPanEnabled,
                onTap: onTap,
                onBegan: onPanBegan,
                onChanged: onPanChanged,
                onEnded: onPanEnded
            )
            .frame(height: DeckStyle.cardLabelHitHeight)
        }
    }
}
#endif
