//
//  DeckLayout.swift
//

import CoreGraphics

enum DeckLayout {
    static func expandedTop(safeAreaTop: CGFloat) -> CGFloat {
        safeAreaTop + DeckStyle.expandedTopOffset
    }

    static func collapsedBottomPadding(safeAreaBottom: CGFloat) -> CGFloat {
        safeAreaBottom + DeckStyle.collapsedBottomOffset
    }

    static func cardHeight(
        totalCards: Int,
        containerHeight: CGFloat,
        safeAreaTop: CGFloat
    ) -> CGFloat {
        max(
            DeckStyle.minimumCardHeight,
            containerHeight
            - expandedTop(safeAreaTop: safeAreaTop)
            - DeckStyle.expandedBottomPadding
            - CGFloat(totalCards - 1) * DeckStyle.peek
        )
    }

    static func yPosition(
        index: Int,
        activeIndex: Int,
        totalCards: Int,
        containerHeight: CGFloat,
        safeAreaTop: CGFloat,
        safeAreaBottom: CGFloat
    ) -> CGFloat {
        if index <= activeIndex {
            return expandedTop(safeAreaTop: safeAreaTop) + CGFloat(index - 1) * DeckStyle.peek
        } else {
            let collapsedBaseY =
                containerHeight
                - collapsedBottomPadding(safeAreaBottom: safeAreaBottom)
                - (CGFloat(totalCards) + DeckStyle.collapsedExtraPeekCount) * DeckStyle.peek

            return collapsedBaseY + CGFloat(index - 1) * DeckStyle.peek
        }
    }

    static func zIndex(for index: Int) -> Double {
        Double(index)
    }
}
