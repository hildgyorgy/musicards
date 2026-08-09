//
//  ReleaseThumbnailView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 11..
//

import SwiftUI

struct ReleaseThumbnailView: View {
    let releaseID: String
    let hasCoverArt: Bool

    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if hasCoverArt, let image {
                #if canImport(UIKit)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                #else
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                #endif
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.gray.opacity(0.15))
            }
        }
        .task(id: releaseID) {
            guard hasCoverArt else {
                image = nil
                return
            }

            image = await CoverArtCache.shared.image(for: releaseID, size: .thumbnail)
        }
    }
}
