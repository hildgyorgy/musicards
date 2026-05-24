//
//  DeckSelection.swift
//

import Foundation

struct DeckSelection {
    var activeSlotIndex: Int

    mutating func selectSlot(_ slotIndex: Int) {
        activeSlotIndex = slotIndex
    }
}
