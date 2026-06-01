//
//  AboutView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 24..
//

import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 6) {
#if os(iOS)
            Spacer()
#endif
            Text("Data provided by MusicBrainz")
                .font(.headline)

            Link("musicbrainz.org", destination: URL(string: "https://musicbrainz.org")!)

            Text("MusicBrainz data is available under the CC0 license.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("Cover art is provided by the Cover Art Archive.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            HStack(spacing: 4) {
                Link("Support", destination: URL(string: "https://hildgyorgy.github.io/mb-release-viewer/support.html")!)

                Text("•")

                Link("Privacy", destination: URL(string: "https://hildgyorgy.github.io/mb-release-viewer/support.html#privacy")!)
                
                Text(" | ")
                
                Text("György Hild")
                
                Text("•")
                
                Text("2026")

            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        }
        .padding(28)
#if os(iOS)
.presentationDetents([.height(152)])
.presentationDragIndicator(.visible)
#endif
    }
}
