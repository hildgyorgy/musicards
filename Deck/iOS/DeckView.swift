//
//  DeckView.swift
//

import SwiftUI

struct DeckView<ID: Hashable, HeaderContent: View, CardContent: View>: View {
    let cards: [DeckCard<ID>]
    @Binding var selection: DeckSelection

    private var activeIndex: Int {
        selection.activeSlotIndex
    }
    private func setActiveIndex(_ newValue: Int) {
        selection.activeSlotIndex = newValue
    }
    let headerProvider: (DeckCard<ID>) -> HeaderContent
    let contentProvider: (DeckCard<ID>) -> CardContent

    @State private var dragCardIndex: Int? = nil
    @State private var dragOffset: CGFloat = 0
    
    @State private var nudgeOffset: CGFloat = 0
    @State private var hasNudged: Bool = false
    @State private var nudgeTask: Task<Void, Never>? = nil

    init(
        cards: [DeckCard<ID>],
        selection: Binding<DeckSelection>,
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
            ZStack {
                ForEach(Array(cards.enumerated()), id: \.element.id) { _, card in
                    let index = card.slotIndex

                    let cardHeight = DeckLayout.cardHeight(
                        totalCards: cards.count,
                        containerHeight: proxy.size.height,
                        safeAreaTop: proxy.safeAreaInsets.top
                    )

                    let y = DeckLayout.yPosition(
                        index: index,
                        activeIndex: activeIndex,
                        totalCards: cards.count,
                        containerHeight: proxy.size.height,
                        safeAreaTop: proxy.safeAreaInsets.top,
                        safeAreaBottom: proxy.safeAreaInsets.bottom
                    )

                    DeckCardView(
                        card: card,
                        onTap: {
                            handleTap(on: index)
                        },
                        isPanEnabled: DeckPhysics.dragKind(
                            for: index,
                            activeIndex: activeIndex,
                            cardCount: cards.count
                        ) != nil,
                        onPanBegan: {
                            dragCardIndex = index
                            dragOffset = 0
                            nudgeOffset = 0
                            nudgeTask?.cancel()
                            nudgeTask = nil
                        },
                        onPanChanged: { dy in
                            guard dragCardIndex == index else { return }

                            guard let kind = DeckPhysics.dragKind(
                                for: index,
                                activeIndex: activeIndex,
                                cardCount: cards.count
                            ) else {
                                return
                            }

                            dragOffset = DeckPhysics.previewOffset(
                                for: kind,
                                translationY: dy
                            )
                        },
                        onPanEnded: { dy, vy in
                            guard dragCardIndex == index else { return }

                            guard let kind = DeckPhysics.dragKind(
                                for: index,
                                activeIndex: activeIndex,
                                cardCount: cards.count
                            ) else {
                                return
                            }

                            let decision = DeckPhysics.decision(
                                for: kind,
                                translationY: dy,
                                velocityY: vy
                            )

                            switch decision {
                            case .commit(let delta):
                                withAnimation(DeckStyle.animation) {
                                    setActiveIndex(activeIndex + delta)
                                    dragOffset = 0
                                }

                            case .snapBack:
                                withAnimation(DeckStyle.animation) {
                                    dragOffset = 0
                                }
                            }

                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                                if dragCardIndex == index {
                                    dragCardIndex = nil
                                }
                            }
                        }
                    ) {
                        headerProvider(card)
                    } content: {
                        contentProvider(card)
                    }
                    .frame(
                        width: proxy.size.width - DeckStyle.horizontalInset * 2,
                        height: cardHeight
                    )
                    .offset(
                        y: y + interactiveOffset(for: index) + nudgeOffset(for: index)
                    )
                    .zIndex(DeckLayout.zIndex(for: index))
                }
            }
            .onAppear {

                scheduleInitialNudge()

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
    }

    private func handleTap(on index: Int) {
        if index == activeIndex + 1, activeIndex < cards.count {
            withAnimation(DeckStyle.animation) {
                setActiveIndex(activeIndex + 1)
            }
        } else if index == activeIndex, activeIndex > 0 {
            withAnimation(DeckStyle.animation) {
                setActiveIndex(activeIndex - 1)
            }
        }
    }

    private func interactiveOffset(for index: Int) -> CGFloat {
        guard dragCardIndex == index else { return 0 }

        if index == activeIndex {
            return max(0, dragOffset)
        } else if index == activeIndex + 1 {
            return min(0, dragOffset)
        } else {
            return 0
        }
    }
    
    private func nudgeOffset(for index: Int) -> CGFloat {
        guard index == cards.count - 3 else { return 0 }
        guard dragCardIndex == nil else { return 0 }
        return nudgeOffset
    }

    private func scheduleInitialNudge() {
        guard !hasNudged else { return }
        hasNudged = true

        nudgeTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            guard dragCardIndex == nil else { return }

            await runNudgeSequence()
        }
    }

    @MainActor
    private func runNudgeSequence() async {
        let repetitions = 2

        for _ in 0..<repetitions {
            if Task.isCancelled { return }
            if dragCardIndex != nil { return }

            // move up
            withAnimation(.easeOut(duration: 0.6)) {
                nudgeOffset = -30
            }

            try? await Task.sleep(nanoseconds: 300_000_000)

            if Task.isCancelled { return }

            // move back
            withAnimation(.easeIn(duration: 0.35)) {
                nudgeOffset = 0
            }

            try? await Task.sleep(nanoseconds: 400_000_000) // 0.4s pause between the two repetitions
        }
    }
}
