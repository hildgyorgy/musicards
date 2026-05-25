//
//  DeckPhysics.swift
//

#if os(iOS)
import CoreGraphics

enum DeckDragKind {
    case collapseCurrent
    case expandNext
}

enum DeckDragDecision {
    case snapBack
    case commit(delta: Int)
}

struct DeckPhysicsConfiguration {
    let dragThreshold: CGFloat
    let velocityThreshold: CGFloat

    static let `default` = DeckPhysicsConfiguration(
        dragThreshold: 80,
        velocityThreshold: 800
    )
}

enum DeckPhysics {

    static func dragKind(
        for index: Int,
        activeSlotIndex: Int,
        cardCount: Int
    ) -> DeckDragKind? {
        if index == activeSlotIndex, activeSlotIndex > 0 {
            return .collapseCurrent
        }

        if index == activeSlotIndex + 1, activeSlotIndex < cardCount {
            return .expandNext
        }

        return nil
    }

    static func previewOffset(
        for kind: DeckDragKind,
        translationY: CGFloat,
        config: DeckPhysicsConfiguration = .default
    ) -> CGFloat {
        switch kind {
        case .collapseCurrent:
            return max(0, translationY)
        case .expandNext:
            return min(0, translationY)
        }
    }

    static func decision(
        for kind: DeckDragKind,
        translationY: CGFloat,
        velocityY: CGFloat,
        config: DeckPhysicsConfiguration = .default
    ) -> DeckDragDecision {
        let threshold = config.dragThreshold
        let velocity = config.velocityThreshold

        switch kind {
        case .collapseCurrent:
            if translationY > threshold || velocityY > velocity {
                return .commit(delta: -1)
            }

        case .expandNext:
            if translationY < -threshold || velocityY < -velocity {
                return .commit(delta: +1)
            }
        }

        return .snapBack
    }
}
#endif
