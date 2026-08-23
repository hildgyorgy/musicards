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
