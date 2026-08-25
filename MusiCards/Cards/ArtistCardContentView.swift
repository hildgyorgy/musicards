//
//  ArtistCardContentView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 08..
//

import SwiftUI

struct ArtistCardContentView: View {
    @ObservedObject var libraryManager: LibraryManager
    let artist: MBArtistDetail?
    let artistName: String
    let releaseGroups: [MBReleaseGroupSummary]
    let wikipedia: (title: String, extract: String)?
    let discographyError: Error?
    let onSelectReleaseGroup: (MBReleaseGroupSummary) -> Void
    let onRetryDiscography: () -> Void
    let isLoadingWikipedia: Bool
    let artistError: Error?
    let onRetryArtist: () -> Void

    // Pagination
    let isLoadingMore: Bool
    let onLoadMoreIfNeeded: (MBReleaseGroupSummary) -> Void
#if os(iOS)
    @Environment(\.deckContentBottomInset) private var deckContentBottomInset
#endif

    @State private var isShowingWikipedia = false
    @State private var wikipediaURL_: URL? = nil
    @State private var wikipediaPresentationURL: URL? = nil
    @Environment(\.colorScheme) private var colorScheme

    private var cardBackground: Color {
            colorScheme == .dark
                ? AppStyle.darkCardBackgroundColor
                : AppStyle.lightCardBackgroundColor
        }

    private var hasArtistContent: Bool {
        artist != nil || !artistName.isEmpty || !releaseGroups.isEmpty
    }

    var body: some View {
        Group {
            if artistError != nil && !MusiCardsAppModel.hasUsableArtistHeader(
                artist: artist,
                name: artistName
            ) {
                ErrorStateView.artistRetry {
                    onRetryArtist()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hasArtistContent {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {

                        // Wikipedia excerpt stays above Discography in the stable card layout.
                        wikipediaSection

                        if let discographyError, releaseGroups.isEmpty {
                            ErrorStateView.discographyRetry(for: discographyError) {
                                onRetryDiscography()
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                        } else {
                            // Discography sections
                            ForEach(groupedDiscographySections(from: releaseGroups)) { section in
                                Section {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(section.items) { group in
                                            Button {
#if os(iOS)
                                                UIApplication.shared.sendAction(
                                                    #selector(UIResponder.resignFirstResponder),
                                                    to: nil,
                                                    from: nil,
                                                    for: nil
                                                )
#endif
                                                onSelectReleaseGroup(group)
                                            } label: {
                                                HStack(alignment: .firstTextBaseline, spacing: 16) {
                                                    Text(MBTextFormatter.year(from: group.firstReleaseDate))
                                                        .font(.callout)
                                                        .foregroundStyle(.secondary)
#if os(iOS)
                                                        .frame(width: 40, alignment: .leading)
                                                #else
                                                        .frame(width: 35, alignment: .leading)
#endif
                                                    Text(group.title)
                                                        .font(.callout)
                                                        .foregroundStyle(Color.blue)
                                                        .frame(maxWidth: .infinity, alignment: .leading)

                                                    if isPlayable(group) {
                                                        Image(systemName: "play.fill")
                                                            .font(.caption2)
                                                            .foregroundStyle(Color.blue)
                                                            .accessibilityLabel(
                                                                "Release group available in music library"
                                                            )
                                                    }
                                                }
#if os(macOS)
                                                .padding(.leading, 10)
#endif
                                                .padding(.vertical, 4)
                                            }
                                            .buttonStyle(.plain)
                                            .onAppear {
                                                onLoadMoreIfNeeded(group)
                                            }
                                        }
                                    }
                                    .padding(.bottom, 24)
                                } header: {
                                    typeSectionHeader(section.title)
                                }
                            }
                        }

                        // Loading indicator at the bottom
                        if isLoadingMore {
                            MusiCardsSpinner()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }

#if os(iOS)
                        Color.clear
                            .frame(height: deckContentBottomInset)
#endif

                    }
                }
                .padding(.bottom, 36)
            
            } else {
                EmptyStateView.artist
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 0)
            }
        }
#if os(iOS)
        .sheet(isPresented: $isShowingWikipedia) {
            if let url = wikipediaPresentationURL {
                SafariView(url: url)
                    .presentationDetents([.fraction(0.83)])
            }
        }
#else
        .overlay {
            if wikipediaURL_ != nil {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        wikipediaURL_ = nil
                    }
            }
        }
        .overlay(alignment: .bottom) {
            if let url = wikipediaURL_ {
                WikipediaSheetView(url: url, onDismiss: {
                    wikipediaURL_ = nil
                })
                .padding(5)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { }  // swallow taps so they don't fall through to dismiss
            }
        }
        .animation(.spring(duration: 0.35), value: wikipediaURL_)
        .onKeyPress(.escape) {
            if wikipediaURL_ != nil {
                wikipediaURL_ = nil
                return .handled
            }
            return .ignored
        }
#endif
    }

    // MARK: - Helpers

    @ViewBuilder
    private var wikipediaSection: some View {
        if isLoadingWikipedia {
            MusiCardsSpinner()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .padding(.bottom, 16)
        } else if let wikipedia {
            VStack(alignment: .leading, spacing: 6) {
                Text(displayExcerpt(for: wikipedia.extract))
                    .font(.callout)
                    .foregroundStyle(.primary)

                Button("Read more →") {
                    openWikipedia(wikipedia)
                }
                .font(.callout)
                .foregroundStyle(Color.blue)
                .buttonStyle(.plain)
            }
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
    }

    private func openWikipedia(_ wikipedia: (title: String, extract: String)) {
        guard let canonicalURL = wikipediaURL(for: wikipedia.title) else { return }
        let url = WikipediaURLPresentation.url(
            canonicalURL,
            isDark: colorScheme == .dark
        )
        #if os(macOS)
        wikipediaURL_ = url
        #else
        wikipediaPresentationURL = url
        isShowingWikipedia = true
        #endif
    }

    private func isPlayable(_ group: MBReleaseGroupSummary) -> Bool {
        let artistName = artist?.name ?? self.artistName
        guard !artistName.isEmpty else { return false }
        return libraryManager.containsReleaseGroup(
            title: group.title,
            artistName: artistName
        )
    }

    private func displayExcerpt(for text: String, limit: Int = 150) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }

        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: limit)
        let base = String(trimmed[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        return base + "..."
    }

    private func wikipediaURL(for title: String) -> URL? {
        let underscored = title.replacingOccurrences(of: " ", with: "_")
        let encoded = underscored.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        return encoded.flatMap {
            URL(string: "https://en.wikipedia.org/wiki/\($0)")
        }
    }

    private func typeSectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.footnote)
            .tracking(AppStyle.cardLabelTracking)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
            .background {
                #if os(macOS)
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                #else
                Rectangle().fill(cardBackground)
                #endif
            }
            .padding(.horizontal, 0)
            .padding(.bottom, 6)
            .zIndex(1)
    }
}

enum WikipediaURLPresentation {
    private static let vectorNightMode = "vectornightmode"
    private static let minervaNightMode = "minervanightmode"

    /// Wikimedia-provided night-mode parameters, isolated because their
    /// temporary forcing/debug status may change in a future Wikimedia release.
    static func url(_ canonicalURL: URL, isDark: Bool) -> URL {
        guard isDark,
              var components = URLComponents(
                url: canonicalURL,
                resolvingAgainstBaseURL: false
              ) else {
            return canonicalURL
        }

        let nightModeNames = [vectorNightMode, minervaNightMode]
        let existingItems = components.queryItems ?? []
        components.queryItems = existingItems.filter {
            !nightModeNames.contains($0.name.lowercased())
        } + [
            URLQueryItem(name: vectorNightMode, value: "1"),
            URLQueryItem(name: minervaNightMode, value: "1")
        ]

        return components.url ?? canonicalURL
    }
}
