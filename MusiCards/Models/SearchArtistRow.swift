//
//  SearchArtistRow.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 08..
//

import Foundation

struct SearchArtistRow: Identifiable, Codable {
    let id: String
    let name: String
    let lifeSpan: String
    /// The artist query that produced a library credit, which may name several artists.
    let librarySearchTerm: String?

    nonisolated init(id: String, name: String, lifeSpan: String, librarySearchTerm: String? = nil) {
        self.id = id
        self.name = name
        self.lifeSpan = lifeSpan
        self.librarySearchTerm = librarySearchTerm
    }
}
