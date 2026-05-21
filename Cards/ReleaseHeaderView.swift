//
//  ReleaseHeaderView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 08..
//

import SwiftUI

struct ReleaseHeaderView: View {
    let release: MBRelease?
    let coverImage: PlatformImage?
    let onSelectArtist: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: DeckStyle.headerSpacing) {
            if let coverImage {
                #if canImport(UIKit)
                Image(uiImage: coverImage)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .cornerRadius(12)
                    .shadow(
                        color: colorScheme == .dark
                            ? Color.white.opacity(0.18)
                            : Color.black.opacity(0.18),
                        radius: 12,
                        y: 6
                    )
                    .padding(.top, -36)
                #else
                Image(nsImage: coverImage)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .cornerRadius(12)
                    .shadow(
                        color: colorScheme == .dark
                            ? Color.white.opacity(0.18)
                            : Color.black.opacity(0.18),
                        radius: 12,
                        y: 6
                    )
                    .padding(.top, -20)
                #endif
            }

            if let release {
                Text(release.title)
                    .font(DeckStyle.releaseHeaderTitleFont.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .padding(.top, 6)

                ArtistCreditLinksView(
                    artistCredits: release.artistCredit,
                    onSelectArtist: onSelectArtist,
                    maxLines: 2
                )
                .font(DeckStyle.releaseHeaderArtistFont)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
