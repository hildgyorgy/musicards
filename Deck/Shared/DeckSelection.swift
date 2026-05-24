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

    mutating func selectID(_ id: ID) {
        activeID = id
    }
}
