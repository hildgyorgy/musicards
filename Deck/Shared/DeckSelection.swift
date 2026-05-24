//
//  DeckSelection.swift
//

import Foundation

struct DeckSelection<ID: Hashable> {
    var activeID: ID?
    var activeSlotIndex: Int

    mutating func selectSlot(_ slotIndex: Int) {
        activeSlotIndex = slotIndex
    }
    
    mutating func selectID(_ id: ID, in cards: [DeckCard<ID>]) {
        guard let card = cards.first(where: { $0.id == id }) else { return }
        selectCard(card)
    }

    mutating func selectCard(_ card: DeckCard<ID>) {
        activeID = card.id
        activeSlotIndex = card.slotIndex
    }
    
    init(activeID: ID?, activeSlotIndex: Int) {
        self.activeID = activeID
        self.activeSlotIndex = activeSlotIndex
    }
}
