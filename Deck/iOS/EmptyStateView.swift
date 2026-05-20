//
//  EmptyStateView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 18..
//

import SwiftUI

struct EmptyStateView: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.callout)

            Text(subtitle)
                .font(.callout)
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

extension EmptyStateView {
    static let release = EmptyStateView(
        title: "No release yet",
        subtitle: "Find one on the SEARCH card"
    )

    static let tracks = EmptyStateView(
        title: "No tracks to show",
        subtitle: "Pick a release first on the SEARCH card"
    )

    static let artist = EmptyStateView(
        title: "No artist selected",
        subtitle: "Go to SEARCH or tap an artist"
    )
    
    static let searchNoResults = EmptyStateView(
        title: "No matches found",
        subtitle: "Try a different artist or release"
    )
}
