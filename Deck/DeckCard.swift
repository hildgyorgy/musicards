//
//  DeckCard.swift
//

import Foundation

struct DeckCard<ID: Hashable>: Identifiable {
    let id: ID
    let slotIndex: Int
    let cardLabel: String
    let title: String
    let subtitle: String
}
