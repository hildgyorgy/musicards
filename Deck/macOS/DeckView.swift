//
//  DeckView.swift
//

import SwiftUI

struct DeckView<ID: Hashable, HeaderContent: View, CardContent: View>: View {
    let cards: [DeckCard<ID>]
    @Binding var selection: DeckSelection<ID>
    private var activeIndex: Int {
        selection.activeSlotIndex
    }
    private func setActiveIndex(_ newValue: Int) {
        selection.selectSlot(newValue)
    }
    let headerProvider: (DeckCard<ID>) -> HeaderContent
    let contentProvider: (DeckCard<ID>) -> CardContent

    init(
        cards: [DeckCard<ID>],
        selection: Binding<DeckSelection<ID>>,
        @ViewBuilder headerProvider: @escaping (DeckCard<ID>) -> HeaderContent,
        @ViewBuilder contentProvider: @escaping (DeckCard<ID>) -> CardContent
    ) {
        self.cards = cards
        self._selection = selection
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
                setActiveIndex(max(activeIndex - 1, 0))
            } else {
                setActiveIndex(visualIndex)
            }
        }
    }
}
