//
//  DeckCardView.swift
//  MusiCards Release Viewer
//
//  Created by Hild György on 2026. 05. 19..
//

import SwiftUI

struct DeckCardView<HeaderContent: View, CardContent: View>: View {
    let card: DeckCard
    let isActive: Bool
    let onTap: () -> Void
    let header: HeaderContent
    let content: CardContent

    init(
        card: DeckCard,
        isActive: Bool,
        onTap: @escaping () -> Void,
        @ViewBuilder header: () -> HeaderContent,
        @ViewBuilder content: () -> CardContent
    ) {
        self.card = card
        self.isActive = isActive
        self.onTap = onTap
        self.header = header()
        self.content = content()
    }

    @Environment(\.colorScheme) private var colorScheme

    var cardBackground: Color {
        DeckStyle.cardBackgroundColor
    }

    var contentBackground: Color {
        DeckStyle.contentBackgroundColor
    }

    var strokeColor: Color {
        DeckStyle.strokeColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader

            if isActive {
                cardExpandedContent
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(cardBackground)
        .overlay(
            Rectangle()
                .frame(height: DeckStyle.strokeWidth)
                .foregroundStyle(strokeColor),
            alignment: .bottom
        )
    }
    
    private var cardHeader: some View {
        ZStack {
            Text(card.cardLabel.uppercased())
                .font(.system(size: DeckStyle.cardLabelFontSize, weight: DeckStyle.cardLabelFontWeight))
                .tracking(DeckStyle.cardLabelTracking)
                .foregroundStyle(DeckStyle.cardLabelColor)
                .frame(maxWidth: .infinity, alignment: .center)

            PanHandleView(
                isEnabled: true,
                onTap: onTap,
                onBegan: nil,
                onChanged: { _ in },
                onEnded: { _, _ in }
            )
        }
        .frame(height: DeckStyle.cardLabelHitHeight)
    }

    private var cardExpandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: DeckStyle.headerTopSpacing)
            header
                .padding(.horizontal, DeckStyle.contentHorizontalPadding)
            Spacer().frame(height: DeckStyle.contentTopSpacing)
            content
                .padding(.horizontal, DeckStyle.contentHorizontalPadding)
        }
    }
}
