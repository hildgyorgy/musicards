//
//  ArtistCardHeaderView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 13..
//

import SwiftUI

struct ArtistCardHeaderView: View {
    let artist: MBArtistDetail?
    let fallbackName: String
    let fallbackLifeSpan: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.headerSpacing) {
            if !(artist?.name ?? fallbackName).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let name = artist?.name ?? fallbackName
                Text(name)
                    .font(.title.weight(.bold))
                    .foregroundStyle(.primary)

                if let lifeSpan = MBTextFormatter.lifeSpanText(from: artist?.lifeSpan) ?? fallbackLifeSpan {
                    Text(lifeSpan)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
