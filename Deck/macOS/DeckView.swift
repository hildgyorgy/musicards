//
//  DeckView.swift
//  MusiCards Release Viewer
//
//  Created by Hild György on 2026. 05. 19..
//

import SwiftUI

struct DeckView<HeaderContent: View, CardContent: View>: View {
    let cards: [DeckCard]
    @Binding var activeIndex: Int
    let headerProvider: (DeckCard) -> HeaderContent
    let contentProvider: (DeckCard) -> CardContent

    init(
        cards: [DeckCard],
        activeIndex: Binding<Int>,
        @ViewBuilder headerProvider: @escaping (DeckCard) -> HeaderContent,
        @ViewBuilder contentProvider: @escaping (DeckCard) -> CardContent
    ) {
        self.cards = cards
        self._activeIndex = activeIndex
        self.headerProvider = headerProvider
        self.contentProvider = contentProvider
    }

    var body: some View {
        GeometryReader { proxy in
            let collapsedHeight = DeckStyle.collapsedCardHeight
            let availableHeight = proxy.size.height - DeckStyle.topInset * 2
            let expandedHeight = max(
                collapsedHeight,
                availableHeight - collapsedHeight * CGFloat(cards.count - 1)
            )

            VStack(spacing: 0) {
                DeckBackgroundView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                
                ForEach(Array(cards.enumerated()), id: \.element.id) { visualIndex, card in
                    let isActive = visualIndex == activeIndex

                    DeckCardView(
                        card: card,
                        isActive: isActive,
                        onTap: { handleTap(on: visualIndex) },
                        header: { headerProvider(card) },
                        content: { contentProvider(card) }
                    )
                    .frame(height: isActive ? expandedHeight : collapsedHeight)
                    .clipped()
                }
            }
            .frame(
                width: proxy.size.width - DeckStyle.horizontalInset * 2,
                height: availableHeight,
                alignment: .top
            )
            .background(
                GlassCardBackground()
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: DeckStyle.cornerRadius,
                    style: .continuous
                )
            )
            .padding(.horizontal, DeckStyle.horizontalInset)
            .padding(.top, DeckStyle.topInset)
            .animation(DeckStyle.animation, value: activeIndex)
        }
    }

    private func handleTap(on visualIndex: Int) {
        withAnimation(DeckStyle.animation) {
            if visualIndex == activeIndex {
                activeIndex = max(activeIndex - 1, 0)
            } else {
                activeIndex = visualIndex
            }
        }
    }
}
