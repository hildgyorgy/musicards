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
        VStack(alignment: .leading, spacing: AppStyle.headerSpacing) {
            Text(title)
                .font(AppStyle.primaryHeaderFont.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(3)

            ArtistCreditLinksView(
                artistCredits: artistCredits,
                onSelectArtist: onSelectArtist,
            )
            .font(AppStyle.secondaryHeaderFont)
        }
    }
}
