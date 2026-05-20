//
//  DeckCard.swift
//  Cards
//
//  Created by Hild György on 2026. 04. 05..
//

import SwiftUI

enum DeckCardID: Int, CaseIterable, Identifiable {
    case home = 0
    case search = 1
    case release = 2
    case tracks = 3
    case artist = 4

    var id: Int { rawValue }
    var activeIndex: Int { rawValue }
}

struct DeckCard: Identifiable {
    let kind: DeckCardID
    let cardLabel: String
    let title: String
    let subtitle: String

    var id: Int { kind.rawValue }
}
