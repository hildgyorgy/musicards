//
//  ArtistCardHeaderView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 13..
//

import SwiftUI

struct ArtistCardHeaderView: View {
    let artist: MBArtistDetail?

    var body: some View {
        VStack(alignment: .leading, spacing: DeckStyle.headerSpacing) {
            if let artist {
                Text(artist.name)
                    .font(.title.weight(.bold))
                    .foregroundStyle(.primary)

                if let lifeSpan = MBTextFormatter.lifeSpanText(from: artist.lifeSpan) {
                    Text(lifeSpan)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
