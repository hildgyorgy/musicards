//
//  DeckLayout.swift
//

#if os(iOS)
import CoreGraphics

enum DeckLayout {
    static func expandedTop(safeAreaTop: CGFloat) -> CGFloat {
        safeAreaTop + DeckStyle.expandedTopInset
    }

    static func cardBottom(containerHeight: CGFloat) -> CGFloat {
        containerHeight - DeckStyle.cardBottomInset
    }

    static func cardHeight(
        totalCards: Int,
        top: CGFloat,
        bottom: CGFloat
    ) -> CGFloat {
        max(1, bottom - top)
    }

    static func yPosition(
        index: Int,
        activeSlotIndex: Int,
        totalCards: Int,
        containerHeight: CGFloat,
        safeAreaTop: CGFloat
    ) -> CGFloat {
        if index <= activeSlotIndex {
            return expandedTop(safeAreaTop: safeAreaTop) + CGFloat(index - 1) * DeckStyle.peek
        } else {
            let collapsedBaseY =
                cardBottom(containerHeight: containerHeight)
                - DeckStyle.collapsedPlayerHeight
                - CGFloat(totalCards - 1) * DeckStyle.peek

            return collapsedBaseY + CGFloat(index - 1) * DeckStyle.peek
        }
    }

    static func zIndex(for index: Int) -> Double {
        Double(index)
    }
}
#endif
