//
//  DeckCard.swift
//  Cards
//
//  Created by Hild György on 2026. 04. 05..
//

import Foundation

struct DeckCard<ID: Hashable>: Identifiable {
    let id: ID
    let index: Int
    let cardLabel: String
    let title: String
    let subtitle: String
}
