//
//  ContentView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 05..
//

import SwiftUI

struct ContentView: View {
    
    private var cards: [DeckCard] {

        let releaseTitle = appModel.selectedRelease?.title ?? "Release"

        let releaseSubtitle =
            appModel.selectedRelease?.artistCredit?
                .compactMap { $0.name }
                .joined(separator: ", ") ?? ""

        let artistTitle = appModel.selectedArtist?.name ?? "Artist"

        let artistSubtitle = MBDateTextFormatter.lifeSpanTextOrEmpty(
            from: appModel.selectedArtist?.lifeSpan
        )

        return [
            DeckCard(
                kind: .search,
                cardLabel: "Search",
                title: "",
                subtitle: "",
            ),
            DeckCard(
                kind: .release,
                cardLabel: "Release",
                title: releaseTitle,
                subtitle: releaseSubtitle,
            ),
            DeckCard(
                kind: .tracks,
                cardLabel: "Tracks",
                title: releaseTitle,
                subtitle: releaseSubtitle,
            ),
            DeckCard(
                kind: .artist,
                cardLabel: "Artist & Discography",
                title: artistTitle,
                subtitle: artistSubtitle,
            )
        ]
    }

    @StateObject private var appModel = MusiCardsAppModel()
    
    @Environment(\.colorScheme) private var colorScheme

    var boxBackground: Color {
        colorScheme == .dark
            ? DeckStyle.boxBackgroundDark
            : DeckStyle.boxBackgroundLight
    }

    var body: some View {
        ZStack {
        DeckView(
            cards: cards,
            activeIndex: $appModel.activeIndex
        ) { card in
            switch card.kind {
            case .search:
                SearchCardHeaderView(
                    viewModel: appModel.searchViewModel,
                    onTapCurrentArtist: {
                        withAnimation(DeckStyle.animation) {
                            appModel.activeIndex = DeckCardID.artist.activeIndex
                        }
                    },
                    onBarcodeScanned: { code in
                        appModel.searchViewModel.searchByBarcode(code)
                    }
                )

            case .release:
                if appModel.isLoadingRelease {
                    VStack(alignment: .leading, spacing: 12) {
                        ProgressView()
                            .padding(.top, 8)
                    }
                } else {
                    ReleaseHeaderView(
                        release: appModel.selectedRelease,
                        coverImage: appModel.selectedReleaseCover,
                        onSelectArtist: { artistID in
                            appModel.selectArtist(id: artistID)
                        }
                    )
                }

            case .tracks:
                if let release = appModel.selectedRelease {
                    TracksCardHeaderView(
                        title: release.title,
                        artistCredits: release.artistCredit,
                        onSelectArtist: { artistID in
                            appModel.selectArtist(id: artistID)
                        }
                    )
                } else {
                    EmptyView()
                }

            case .artist:
                ArtistCardHeaderView(
                    artist: appModel.selectedArtist
                )
            }
        } contentProvider: { card in
            switch card.kind {
            case .search:
                SearchCardContentView(
                    viewModel: appModel.searchViewModel,

                    recentArtists: appModel.recentArtists,
                    recentReleases: appModel.recentReleases,
                    nowPlayingRelease: appModel.nowPlayingRelease,

                    onSelectRelease: { row in
                        appModel.selectRelease(row)
                        appModel.addRecentRelease(row)
                    },

                    onSelectArtist: { artist in
                        appModel.selectArtist(artist)
                        appModel.addRecentArtist(artist)
                    },

                    onSelectRecentArtist: { artist in
                        appModel.selectArtist(artist)
                        appModel.addRecentArtist(artist)
                    },

                    onSelectRecentRelease: { release in
                        appModel.selectRelease(release)
                        appModel.addRecentRelease(release)
                    },
                    
                    onSelectNowPlayingRelease: {
                        appModel.openNowPlayingVersions()
                    }
                )

            case .release:
                if appModel.isLoadingRelease {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                } else if let release = appModel.selectedRelease {
                    ReleaseCardContentView(
                        release: release,
                        onShowVersions: {
                            guard let groupID = release.releaseGroup?.id else { return }

                            let artist = release.artistCredit?
                                .compactMap { $0.name }
                                .joined(separator: ", ") ?? ""

                            appModel.searchViewModel.loadReleaseGroupResults(
                                releaseGroupID: groupID,
                                releaseTitle: release.title,
                                artistName: artist
                            )

                            withAnimation(DeckStyle.animation) {
                                appModel.activeIndex = DeckCardID.search.activeIndex
                            }
                        }
                    )

                } else if appModel.releaseError != nil {
                    ErrorStateView.releaseRetry {
                        appModel.retryRelease()
                    }

                } else {
                    EmptyStateView.release
                }

            case .tracks:
                TracksCardContentView(
                    release: appModel.selectedRelease,
                    onSelectArtist: { artistID in
                        appModel.selectArtist(id: artistID)
                    },
                    detailStore: appModel.trackDetailStore,
                    classicalMetadataStore: appModel.classicalMetadataStore
                )

            case .artist:
                if appModel.isLoadingArtistHeader {
                    ProgressView()
                } else {
                    ArtistCardContentView(
                        artist: appModel.selectedArtist,
                        releaseGroups: appModel.artistReleaseGroups,
                        wikipedia: appModel.artistWikipedia,
                        onSelectReleaseGroup: { group in appModel.selectReleaseGroup(group) },
                        isLoadingWikipedia: appModel.isLoadingArtistWikipedia,
                        artistError: appModel.artistError,
                        onRetryArtist: { appModel.retryArtist() },
                        isLoadingMore: appModel.isLoadingMoreReleaseGroups,        // new
                        onLoadMoreIfNeeded: { group in                             // new
                            appModel.loadMoreReleaseGroupsIfNeeded(currentItem: group)
                        }
                    )
                }
            }
        }
        
        .background(
            ZStack {
                boxBackground
                DeckBackgroundView()
            }
        )
        .ignoresSafeArea()
            
        if appModel.isBlockingNavigationLoad {
            ZStack {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()

                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.2)
            }
            .zIndex(999)
            .transition(.opacity)
        }
    }
    .animation(.easeInOut(duration: 0.15), value: appModel.isBlockingNavigationLoad)
    }
    }
