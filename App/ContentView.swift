//
//  ContentView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 05..
//

import SwiftUI

struct ContentView: View {

    private var cards: [DeckCard<MusiCardID>] {

        let releaseTitle = appModel.selectedRelease?.title ?? "Release"

        let releaseSubtitle =
            appModel.selectedRelease?.artistCredit?
            .compactMap { $0.name }
            .joined(separator: ", ") ?? ""

        let artistTitle = appModel.selectedArtist?.name ?? "Artist"

        let artistSubtitle = MBTextFormatter.lifeSpanTextOrEmpty(
            from: appModel.selectedArtist?.lifeSpan
        )

        var result: [DeckCard<MusiCardID>] = []
        #if os(macOS)
            result.append(
                DeckCard(
                    id: .home,
                    slotIndex: MusiCardID.home.slotIndex,
                    cardLabel: "MusiCards",
                    title: "...",
                    subtitle: "..."
                )
            )
        #endif
        result.append(contentsOf: [
            DeckCard(
                id: .search,
                slotIndex: MusiCardID.search.slotIndex,
                cardLabel: "Search",
                title: "",
                subtitle: ""
            ),
            DeckCard(
                id: .release,
                slotIndex: MusiCardID.release.slotIndex,
                cardLabel: "Release",
                title: releaseTitle,
                subtitle: releaseSubtitle
            ),
            DeckCard(
                id: .tracks,
                slotIndex: MusiCardID.tracks.slotIndex,
                cardLabel: "Tracks",
                title: releaseTitle,
                subtitle: releaseSubtitle
            ),
            DeckCard(
                id: .artist,
                slotIndex: MusiCardID.artist.slotIndex,
                cardLabel: "Artist & Discography",
                title: artistTitle,
                subtitle: artistSubtitle
            ),
            DeckCard(
                id: .player,
                slotIndex: MusiCardID.player.slotIndex,
                cardLabel: "Player",
                title: "",
                subtitle: ""
            ),
        ])
        return result
    }

    @StateObject private var appModel = MusiCardsAppModel()

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    var boxBackground: Color {
        colorScheme == .dark
            ? AppStyle.boxBackgroundDark
            : AppStyle.boxBackgroundLight
    }

    @ViewBuilder private func headerContent(_ card: DeckCard<MusiCardID>)
        -> some View
    {

        switch card.id {
        case .home:
            EmptyView()
        case .search:
            SearchCardHeaderView(
                viewModel: appModel.searchViewModel,
                isShazamListening: appModel.isShazamListening,
                onShazamTapped: {
                    appModel.startShazamSearch()
                },
                onTapCurrentArtist: {
                    withAnimation(AppStyle.animation) {
                        appModel.deckSelection.selectID(.artist, in: cards)
                    }
                },
                onBarcodeScanned: { code in
                    appModel.searchViewModel.searchByBarcode(code)
                },
                shazamStatusMessage: appModel.shazamStatusMessage
            )
        case .release:
            if appModel.isLoadingRelease {
                VStack(alignment: .leading, spacing: 12) {
                    MusiCardsSpinner()
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
        case .player:
            PlayerCardContentView(
                controller: appModel.playbackController,
                localLibrary: appModel.localLibrary,
                onSelectLocalFile: { url in
                    appModel.playLocalFile(url)
                },
                onSelectMusicFolder: { url in
                    appModel.selectMusicFolder(url)
                },
                onRefreshLibrary: {
                    appModel.refreshLocalLibrary()
                },
                detailStore: appModel.trackDetailStore,
                onSelectArtist: { artistID in
                    appModel.selectArtist(id: artistID)
                }
            )
        }
    }

    @ViewBuilder private func cardContent(_ card: DeckCard<MusiCardID>)
        -> some View
    {
        switch card.id {
        case .home:
            DeckBackgroundView()
        case .search:
            SearchCardContentView(
                viewModel: appModel.searchViewModel,
                localLibrary: appModel.localLibrary,
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
                    #if os(iOS)
                        appModel.openNowPlayingVersions()
                    #endif
                }
            )
        case .release:
            if appModel.isLoadingRelease {
                MusiCardsSpinner()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let release = appModel.selectedRelease {
                ReleaseCardContentView(
                    release: release,
                    onShowVersions: {
                        guard let groupID = release.releaseGroup?.id else {
                            return
                        }
                        let artist =
                            release.artistCredit?
                            .compactMap { $0.name }
                            .joined(separator: ", ") ?? ""
                        appModel.searchViewModel.loadReleaseGroupResults(
                            releaseGroupID: groupID,
                            releaseTitle: release.title,
                            artistName: artist
                        )
                        withAnimation(AppStyle.animation) {
                            appModel.deckSelection.selectID(.search, in: cards)
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
                localLibrary: appModel.localLibrary,
                playbackController: appModel.playbackController,
                onPlayTrack: { releaseTrackID, recordingID in
                    appModel.playIndexedTrack(
                        releaseTrackID: releaseTrackID,
                        recordingID: recordingID
                    )
                },
                detailStore: appModel.trackDetailStore,
                classicalMetadataStore: appModel.classicalMetadataStore
            )
        case .artist:
            if appModel.isLoadingArtistHeader {
                MusiCardsSpinner()
            } else {
                ArtistCardContentView(
                    artist: appModel.selectedArtist,
                    releaseGroups: appModel.artistReleaseGroups,
                    wikipedia: appModel.artistWikipedia,
                    onSelectReleaseGroup: { group in
                        appModel.selectReleaseGroup(group)
                    },
                    isLoadingWikipedia: appModel.isLoadingArtistWikipedia,
                    artistError: appModel.artistError,
                    onRetryArtist: { appModel.retryArtist() },
                    isLoadingMore: appModel.isLoadingMoreReleaseGroups,
                    onLoadMoreIfNeeded: { group in
                        appModel.loadMoreReleaseGroupsIfNeeded(
                            currentItem: group
                        )
                    }
                )
            }
        case .player:
            EmptyView()
        }
    }

    @ViewBuilder private func collapsedHeaderContent(
        _ card: DeckCard<MusiCardID>
    ) -> some View {
        if card.id == .player {
            CollapsedPlayerBar(controller: appModel.playbackController)
        } else {
            EmptyView()
        }
    }

    var body: some View {
        ZStack {
            #if os(macOS)
                DeckView(
                    cards: cards,
                    selection: $appModel.deckSelection,
                    showsCollapsedHeader: { card in
                        card.id == .player && appModel.hasCurrentPlaybackItem
                    },
                    collapsedHeaderProvider: { card in
                        collapsedHeaderContent(card)
                    },
                    headerProvider: { card in
                        headerContent(card)
                    },
                    contentProvider: { card in
                        cardContent(card)
                    }
                )
            #else
                GeometryReader { viewportProxy in
                    DeckView(
                        cards: cards,
                        viewportSafeAreaTop: viewportProxy.safeAreaInsets.top,
                        viewportSafeAreaBottom: viewportProxy.safeAreaInsets.bottom,
                        selection: $appModel.deckSelection,
                        showsCollapsedHeader: { card in
                            card.id == .player && appModel.hasCurrentPlaybackItem
                        },
                        collapsedHeaderProvider: { card in
                            collapsedHeaderContent(card)
                        },
                        headerProvider: { card in
                            headerContent(card)
                        },
                        contentProvider: { card in
                            cardContent(card)
                        },
                        background: {
                            ZStack {
                                boxBackground
                                DeckBackgroundView()
                            }
                        }
                    )
                    .ignoresSafeArea()
                }
            #endif

            #if os(iOS)
                if appModel.isBlockingNavigationLoad {
                    ZStack {
                        MusiCardsSpinner()
                    }
                    .zIndex(999)
                    .transition(.opacity)
                }
            #endif
        }
        .animation(
            .easeInOut(duration: 0.15),
            value: appModel.isBlockingNavigationLoad
        )
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                appModel.localLibrary.refreshIfNeeded()
            }
        }
    }
}
