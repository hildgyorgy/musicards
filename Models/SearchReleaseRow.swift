//
//  SearchReleaseRow.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 07..
//

import Foundation

struct SearchReleaseRow: Identifiable, Codable {
    let id: String
    let title: String
    let artistLine: String
    let metaLine: String
    let disambiguation: String
    let hasCoverArt: Bool
}
