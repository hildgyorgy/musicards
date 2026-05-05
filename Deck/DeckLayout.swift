//
//  DeckLayout.swift
//  Cards
//
//  Created by Hild György on 2026. 04. 05..
//

import CoreGraphics

enum DeckLayout {
    static func yPosition(
        index: Int,
        activeIndex: Int,
        totalCards: Int,
        containerHeight: CGFloat,
        cardHeight: CGFloat
    ) -> CGFloat {
        if index <= activeIndex {
            // Expanded stack
            return DeckStyle.expandedTop + CGFloat(index - 1) * DeckStyle.peek
        } else {
            // Collapsed stack: only visible peeks matter, not full card height
            let collapsedBaseY =
                containerHeight
                - DeckStyle.collapsedBottomPadding
                - (CGFloat(totalCards) + DeckStyle.collapsedExtraPeekCount) * DeckStyle.peek

            return collapsedBaseY + CGFloat(index - 1) * DeckStyle.peek
        }
    }

    static func zIndex(for index: Int) -> Double {
        Double(index)
    }
}
