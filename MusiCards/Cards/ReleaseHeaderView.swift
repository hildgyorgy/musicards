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
    let isPlayable: Bool
    let onPlayRelease: () -> Void
    let onSelectArtist: (String) -> Void
    
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredService: String?
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
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: AppStyle.headerSpacing) {
                        Text(release.title)
                            .font(AppStyle.primaryHeaderFont.weight(.bold))
                            .foregroundStyle(.primary)
                            .lineLimit(3)

                        ArtistCreditLinksView(
                            artistCredits: release.artistCredit,
                            onSelectArtist: onSelectArtist,
                        )
                        .font(AppStyle.secondaryHeaderFont)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if isPlayable {
                        Button(action: onPlayRelease) {
                            Image(systemName: "play.fill")
                                .font(.title3)
                                .foregroundStyle(.blue)
                                .padding(.top, 3)
                                .frame(width: 44, height: 44, alignment: .top)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play release")
                    }
                }
                .padding(.top, 6)
                
                if [
                    release.appleMusicURL,
                    release.spotifyURL,
                    release.tidalURL,
                    release.qobuzURL,
                    release.discogsURL
                ].contains(where: { $0 != nil }) {
                    HStack(spacing: 12) {
                        if let url = release.appleMusicURL {
                            externalLinkButton(
                                url: url,
                                imageName: "apple_music_logo"
                            )
                        }

                        if let url = release.spotifyURL {
                            externalLinkButton(
                                url: url,
                                imageName: "spotify_logo"
                            )
                        }

                        if let url = release.tidalURL {
                            externalLinkButton(
                                url: url,
                                imageName: "tidal_logo"
                            )
                        }

                        if let url = release.qobuzURL {
                            externalLinkButton(
                                url: url,
                                imageName: "qobuz_logo"
                            )
                        }

                        if let url = release.discogsURL {
                            externalLinkButton(
                                url: url,
                                imageName: "discogs_logo"
                            )
                        }
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
    private func externalLinkButton(
        url: URL,
        imageName: String
    ) -> some View {
        Button {
            openURL(url)
        } label: {
            Image(imageName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
    #if os(iOS)
                .frame(width: 20, height: 20)
    #else
                .frame(width: 18, height: 18)
    #endif
                .foregroundStyle(
                    hoveredService == imageName ? Color.blue : .primary
                )
        }
        .buttonStyle(.plain)
    #if os(macOS)
        .onHover { hovering in
            hoveredService = hovering ? imageName : nil
        }
    #endif
    }
}
