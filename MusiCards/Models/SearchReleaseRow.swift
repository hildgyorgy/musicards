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

extension SearchReleaseRow {
    func enriched(with release: MBRelease) -> SearchReleaseRow {
        SearchReleaseRow(
            id: id,
            title: release.title,
            artistLine: MBTextFormatter.artistLine(
                from: release.artistCredit
            ),
            metaLine: MBTextFormatter.releaseMetaLine(
                year: MBTextFormatter.year(from: release.date),
                country: release.country,
                label: release.labelInfo?.compactMap { $0.label?.name }.first,
                format: release.media?.compactMap { $0.format }.first
            ),
            disambiguation: release.disambiguation ?? "",
            hasCoverArt: hasCoverArt
        )
    }
}
