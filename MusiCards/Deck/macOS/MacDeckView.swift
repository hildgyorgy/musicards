//
//  DeckView.swift
//

#if os(macOS)
import SwiftUI

struct DeckView<ID: Hashable, CollapsedHeaderContent: View, HeaderContent: View, CardContent: View>: View {
    let cards: [DeckCard<ID>]
    @Binding var selection: DeckSelection<ID>
    private var activeSlotIndex: Int {
        selection.activeSlotIndex
    }

    private func setActiveSlotIndex(_ newValue: Int) {
        if let card = cards.first(where: { $0.slotIndex == newValue }) {
            selection.selectCard(card)
        } else {
            selection = DeckSelection(
                activeID: nil,
                activeSlotIndex: newValue
            )
        }
    }
    let headerProvider: (DeckCard<ID>) -> HeaderContent
    let contentProvider: (DeckCard<ID>) -> CardContent
    let collapsedHeaderProvider: (DeckCard<ID>) -> CollapsedHeaderContent
    let showsCollapsedHeader: (DeckCard<ID>) -> Bool

    @AppStorage("glassTransparent") private var glassTransparent = false

    init(
        cards: [DeckCard<ID>],
        selection: Binding<DeckSelection<ID>>,
        showsCollapsedHeader: @escaping (DeckCard<ID>) -> Bool,
        @ViewBuilder collapsedHeaderProvider: @escaping (DeckCard<ID>) -> CollapsedHeaderContent,
        @ViewBuilder headerProvider: @escaping (DeckCard<ID>) -> HeaderContent,
        @ViewBuilder contentProvider: @escaping (DeckCard<ID>) -> CardContent
    ) {
        self.cards = cards
        self._selection = selection
        self.showsCollapsedHeader = showsCollapsedHeader
        self.collapsedHeaderProvider = collapsedHeaderProvider
        self.headerProvider = headerProvider
        self.contentProvider = contentProvider
    }

    var body: some View {
        GeometryReader { proxy in
            let titlebarOverlap = DeckStyle.titlebarHeight
            let availableHeight = proxy.size.height - DeckStyle.topInset * 2 + titlebarOverlap
            let collapsedHeightTotal = cards.reduce(CGFloat.zero) { result, card in
                guard card.slotIndex != activeSlotIndex else { return result }
                return result + collapsedHeight(for: card)
            }
            let expandedHeight = max(
                DeckStyle.collapsedCardHeight,
                availableHeight - collapsedHeightTotal
            )

            VStack(spacing: 0) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { visualIndex, card in
                    let isActive = card.slotIndex == activeSlotIndex

                    DeckCardView(
                        card: card,
                        isActive: isActive,
                        showsCollapsedHeader: showsCollapsedHeader(card),
                        onTap: { handleTap(on: visualIndex) },
                        collapsedHeader: { collapsedHeaderProvider(card) },
                        header: { headerProvider(card) },
                        content: { contentProvider(card) }
                    )
                    .frame(
                        height: isActive
                            ? expandedHeight
                            : collapsedHeight(for: card)
                    )
                    .clipped()
                }
            }
            .frame(
                width: proxy.size.width - DeckStyle.horizontalInset * 2,
                height: availableHeight,
                alignment: .top
            )
            .background {
                if #available(macOS 26.0, *) {
                    let effect: Glass = glassTransparent
                        ? .clear.interactive()
                        : .regular.interactive()
                    Color.clear
                        .glassEffect(
                            effect,
                            in: RoundedRectangle(
                                cornerRadius: DeckStyle.cornerRadius,
                                style: .continuous
                            )
                        )
                } else {
                    GlassCardBackground()
                }
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: DeckStyle.cornerRadius,
                    style: .continuous
                )
            )
            .padding(.horizontal, DeckStyle.horizontalInset)
            .padding(.top, DeckStyle.topInset - titlebarOverlap)
            .animation(DeckStyle.animation, value: activeSlotIndex)
            .animation(DeckStyle.animation, value: collapsedHeightTotal)
        }
    }

    private func collapsedHeight(for card: DeckCard<ID>) -> CGFloat {
        showsCollapsedHeader(card)
            ? DeckStyle.collapsedPlayerHeight
            : DeckStyle.collapsedCardHeight
    }

    private func handleTap(on visualIndex: Int) {
        withAnimation(DeckStyle.animation) {
            let card = cards[visualIndex]

            if card.slotIndex == activeSlotIndex {
                let previousIndex = max(visualIndex - 1, 0)
                setActiveSlotIndex(cards[previousIndex].slotIndex)
            } else {
                selection.selectCard(card)
            }
        }
    }
}
#endif
