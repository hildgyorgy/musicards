//
//  ReleaseThumbnailView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 11..
//

import SwiftUI
import UIKit

struct ReleaseThumbnailView: View {
    let releaseID: String
    let hasCoverArt: Bool

    @State private var image: UIImage?

    var body: some View {
        Group {
            if hasCoverArt, let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
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
