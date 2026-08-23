//
//  SearchCardContentView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 06..
//

import SwiftUI

struct SearchCardContentView: View {
    @ObservedObject var viewModel: SearchViewModel
    @ObservedObject var libraryManager: LibraryManager

    let recentArtists: [SearchArtistRow]
    let recentReleases: [SearchReleaseRow]
    let nowPlayingRelease: SearchReleaseRow?

    let onSelectRelease: (SearchReleaseRow) -> Void
    let onSelectArtist: (SearchArtistRow) -> Void
    let onSelectRecentArtist: (SearchArtistRow) -> Void
    let onSelectRecentRelease: (SearchReleaseRow) -> Void
    let onSelectNowPlayingRelease: () -> Void

    private var isReleaseGroupMode: Bool {
        if case .releaseGroupResults = viewModel.mode { return true }
        return false
    }

    var body: some View {
        ScrollView {
            contentView
                .frame(maxWidth: .infinity, minHeight: 1, alignment: .leading)
                .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if isReleaseGroupMode {
            if viewModel.isSearching {
                MusiCardsSpinner()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 24)
            } else if viewModel.searchError != nil {
                ErrorStateView.searchRetry(for: viewModel.searchError!) {
                    viewModel.retrySearch()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.releaseResults.isEmpty {
                EmptyStateView.searchNoResults
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                releaseVersionsList
            }
        } else {
            if viewModel.isSearching {
                MusiCardsSpinner()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 24)
            } else if viewModel.searchError != nil {
                ErrorStateView.searchRetry(for: viewModel.searchError!) {
                    viewModel.retrySearch()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch viewModel.contentState {
                case .idle:
                    recentContent

                case .artistResults:
                    if viewModel.artistRows.isEmpty {
                        EmptyStateView.searchNoResults
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        artistList
                    }

                case .releaseResults:
                    if viewModel.releaseResults.isEmpty {
                        EmptyStateView.searchNoResults
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        releaseList(sectionLabel: "RELEASES")
                    }
                }
            }
        }
    }

    // MARK: - Release-group versions list (now paginated)

    private var releaseVersionsList: some View {
        LazyVStack(alignment: .leading, spacing: 15) {

            ForEach(viewModel.releaseResults) { release in
                Button {
                    dismissKeyboard()
                    onSelectRelease(release)
                } label: {
                    releaseRow(release)
                }
                .buttonStyle(.plain)
                .onAppear {
                    viewModel.loadMoreIfNeededForReleaseVersion(currentItem: release)
                }
            }

            // Loading indicator at the bottom when fetching next page
            if viewModel.isLoadingMoreVersions {
                MusiCardsSpinner()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Search results

    private func releaseList(sectionLabel label: String) -> some View {
        LazyVStack(alignment: .leading, spacing: 15) {
            sectionLabel(label)

            ForEach(viewModel.releaseResults) { release in
                Button {
                    dismissKeyboard()
                    onSelectRelease(release)
                } label: {
                    releaseRow(release)
                }
                .buttonStyle(.plain)
                .onAppear {
                    viewModel.loadMoreIfNeededForRelease(currentItem: release)
                }
            }

            if viewModel.isLoadingMore {
                MusiCardsSpinner()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
    }

    private var artistList: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            sectionLabel("ARTISTS")

            ForEach(viewModel.artistRows) { artist in
                Button {
                    dismissKeyboard()
                    onSelectArtist(artist)
                } label: {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(artist.name)
                                .font(.body)
                                .foregroundStyle(Color.blue)
                                .lineLimit(1)
                            if !artist.lifeSpan.isEmpty {
                                Text(artist.lifeSpan)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if libraryManager.containsArtist(named: artist.name) {
                            playableIndicator(label: "Artist available in music library")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onAppear {
                    viewModel.loadMoreIfNeededForArtist(currentItem: artist)
                }
            }

            if viewModel.isLoadingMore {
                MusiCardsSpinner()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Shared row / helpers

    private func releaseRow(_ release: SearchReleaseRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ReleaseThumbnailView(
                releaseID: release.id,
                hasCoverArt: release.hasCoverArt,
                isPlayable: libraryManager.containsRelease(release.id)
            )
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(release.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(release.artistLine)
                    .font(.subheadline)
                    .foregroundStyle(Color.blue)
                    .lineLimit(1)
                if !release.metaLine.isEmpty {
                    Text(release.metaLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !release.disambiguation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(release.disambiguation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            if libraryManager.containsRelease(release.id) {
                playableIndicator(label: "Release available in music library")
            }
        }
    }

    private var recentContent: some View {
        LazyVStack(alignment: .leading, spacing: 0) {

            if let nowPlayingRelease {
                VStack(alignment: .leading, spacing: 8) {

                    HStack(spacing: 8) {
                        sectionLabel("NOW PLAYING in Apple Music")
                        LiveWaveformIcon()
                            .padding(.bottom, 2)
                    }

                    Button {
                        dismissKeyboard()
                        onSelectNowPlayingRelease()
                    } label: {
                        releaseRow(nowPlayingRelease)
                    }
                    .buttonStyle(.plain)
                }

                Spacer().frame(height: 20)
            }

            if !recentArtists.isEmpty {
                VStack(alignment: .leading, spacing: 8) {

                    sectionLabel("RECENT ARTISTS")

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(recentArtists) { artist in
                            Button {
                                dismissKeyboard()
                                onSelectRecentArtist(artist)
                            } label: {
                                artistRow(artist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer().frame(height: 20)
            }

            if !recentReleases.isEmpty {
                VStack(alignment: .leading, spacing: 8) {

                    sectionLabel("RECENT RELEASES")

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(recentReleases) { release in
                            Button {
                                dismissKeyboard()
                                onSelectRecentRelease(release)
                            } label: {
                                releaseRow(release)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func artistRow(_ artist: SearchArtistRow) -> some View {
        HStack(spacing: 8) {
            Text(artist.name)
                .font(.body)
                .foregroundStyle(Color.blue)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if libraryManager.containsArtist(named: artist.name) {
                playableIndicator(label: "Artist available in music library")
            }
        }
        .padding(.vertical, 0)
    }

    private func playableIndicator(label: String) -> some View {
        Image(systemName: "play.fill")
            .font(.caption2)
            .foregroundStyle(Color.blue)
            .accessibilityLabel(label)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(AppStyle.cardLabelFont)
            .tracking(AppStyle.cardLabelTracking)
            .foregroundStyle(.secondary)
            .padding(.bottom, -2)
    }

    private func dismissKeyboard() {
#if os(iOS)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
#endif
    }

    private struct LiveWaveformIcon: View {
        @State private var isAnimating = false

        var body: some View {
            HStack(spacing: 2) {
                bar(height: isAnimating ? 5 : 11)
                bar(height: isAnimating ? 12 : 6)
                bar(height: isAnimating ? 7 : 13)
            }
            .frame(height: 14)
            .foregroundStyle(.secondary)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.7)
                    .repeatForever(autoreverses: true)
                ) {
                    isAnimating = true
                }
            }
        }

        private func bar(height: CGFloat) -> some View {
            Capsule()
                .fill(.secondary)
                .frame(width: 2, height: height)
        }
    }
} 
