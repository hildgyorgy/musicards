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
    @State private var isHoveringAppleMusic = false
    @Environment(\.openURL) private var openURL
    
    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.headerSpacing) {
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
            
            if let release = release {
                Text(release.title)
                    .font(AppStyle.primaryHeaderFont.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .padding(.top, 6)
                
                ArtistCreditLinksView(
                    artistCredits: release.artistCredit,
                    onSelectArtist: onSelectArtist,
                )
                .font(AppStyle.secondaryHeaderFont)
                
                if let appleMusicURL = release.appleMusicURL {
                    HStack(spacing: 12) {
                        Button {
                            openURL(appleMusicURL)
                        } label: {
                            Image("apple_music_logo")
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
#if os(iOS)
                                .frame(width: 20, height: 20)
#else
                                .frame(width: 18, height: 18)
#endif
                                .foregroundStyle(
                                    isHoveringAppleMusic ? Color.blue : .primary
                                )
                        }
                        .buttonStyle(.plain)
#if os(macOS)
                        .onHover { hovering in
                            isHoveringAppleMusic = hovering
                        }
#endif
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
#if os(iOS)
                    .padding(.top, 6)
                    .padding(.bottom, -10)
#else
                    .padding(.top, 0)
                    .padding(.bottom, -10)
#endif
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
