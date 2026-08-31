//
//  SearchMode.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 08..
//

import Foundation

enum SearchMode: Equatable {
    case search
    case releaseGroupResults(releaseGroupID: String)

    nonisolated var cardLabel: String {
        switch self {
        case .search:
            return "Search"
        case .releaseGroupResults:
            return "Release Versions"
        }
    }
}

/// Controls whether search stops at playable library results or continues
/// with the global MusicBrainz search.
enum SearchScope: String, Codable, Equatable, Sendable {
    case libraryOnly
    case libraryAndMusicBrainz
}

/// Rollback switch for the scoped-search UX.
enum SearchBehavior: Equatable, Sendable {
    case legacy
    case scoped
}
