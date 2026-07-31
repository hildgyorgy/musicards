//
//  PlayerCardContentView.swift
//  MusiCards
//

import SwiftUI

struct PlayerCardContentView: View {
    @ObservedObject var controller: PlaybackController

    var body: some View {
        Group {
            if let item = controller.currentItem {
                VStack(spacing: 8) {
                    Text(item.track.title)
                        .font(.headline)

                    Text(item.track.artist)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                EmptyStateView(
                    title: "Playback foundation ready",
                    subtitle: "Local track selection comes next"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

