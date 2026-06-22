//
//  DeckView.swift
//

#if os(macOS)
import SwiftUI

struct DeckView<ID: Hashable, HeaderContent: View, CardContent: View>: View {
    let cards: [DeckCard<ID>]
    @Binding var selection: DeckSelection<ID>
    private var activeSlotIndex: Int {
        selection.activeSlotIndex
    }
    private func setActiveSlotIndex(_ newValue: Int) {
        selection.selectSlot(newValue)
    }
    let headerProvider: (DeckCard<ID>) -> HeaderContent
    let contentProvider: (DeckCard<ID>) -> CardContent

    @AppStorage("glassTransparent") private var glassTransparent = false

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
            let titlebarOverlap: CGFloat = 65
            let availableHeight = proxy.size.height - DeckStyle.topInset * 2 + titlebarOverlap
            let expandedHeight = max(
                collapsedHeight,
                availableHeight - collapsedHeight * CGFloat(cards.count - 1)
            )

            VStack(spacing: 0) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { visualIndex, card in
                    let isActive = card.slotIndex == activeSlotIndex

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
        }
    }

    private func handleTap(on visualIndex: Int) {
        withAnimation(DeckStyle.animation) {
            if visualIndex == activeSlotIndex {
                setActiveSlotIndex(max(activeSlotIndex - 1, 0))
            } else {
                selection.selectCard(cards[visualIndex])
            }
        }
    }
}
#endif
