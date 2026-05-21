//
//  TracksCardHeaderView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 08..
//

import SwiftUI

struct TracksCardHeaderView: View {
    let title: String
    let artistCredits: [MBArtistCredit]?
    let onSelectArtist: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DeckStyle.headerSpacing) {
            Text(title)
                .font(DeckStyle.releaseHeaderTitleFont.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(3)

            ArtistCreditLinksView(
                artistCredits: artistCredits,
                onSelectArtist: onSelectArtist,
                maxLines: 2
            )
            .font(DeckStyle.releaseHeaderArtistFont)
        }
    }
}
