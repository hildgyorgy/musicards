//
//  DeckCard.swift
//

import Foundation

struct DeckCard<ID: Hashable>: Identifiable {
    let id: ID
    let index: Int
    let cardLabel: String
    let title: String
    let subtitle: String
}
