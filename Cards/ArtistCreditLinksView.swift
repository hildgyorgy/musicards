//
//  ArtistCreditLinksView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 08..
//

import SwiftUI

struct ArtistCreditLinksView: View {
    let artistCredits: [MBArtistCredit]?
    let onSelectArtist: (String) -> Void

    var body: some View {
        if let artistCredits, !artistCredits.isEmpty {
            Text(attributedArtistCredits(from: artistCredits))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == "musicards",
                          url.host == "artist" else {
                        return .systemAction
                    }

                    let artistID = url.lastPathComponent
                    onSelectArtist(artistID)
                    return .handled
                })
        } else {
            EmptyView()
        }
    }

    private func attributedArtistCredits(from credits: [MBArtistCredit]) -> AttributedString {
        var result = AttributedString()

        for (index, credit) in credits.enumerated() {
            var artistText = AttributedString(credit.name)

            if let artistID = credit.artist?.id,
               let url = URL(string: "musicards://artist/\(artistID)") {
                artistText.link = url
                artistText.foregroundColor = .blue
            } else {
                artistText.foregroundColor = .primary
            }

            result += artistText

            if index < credits.count - 1 {
                let join = credit.joinPhrase?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                var joinText = AttributedString(join.isEmpty ? ", " : join)
                joinText.foregroundColor = .primary
                result += joinText
            }
        }

        return result
    }
}
