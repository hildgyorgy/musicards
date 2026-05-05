//
//  ArtistCardContentView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 08..
//

import SwiftUI

struct ArtistCardContentView: View {
    let artist: MBArtistDetail?
    let releaseGroups: [MBReleaseGroupSummary]
    let wikipedia: (title: String, extract: String)?
    let onSelectReleaseGroup: (MBReleaseGroupSummary) -> Void
    let isLoadingWikipedia: Bool
    let artistError: Error?
    let onRetryArtist: () -> Void

    // Pagination
    let isLoadingMore: Bool
    let onLoadMoreIfNeeded: (MBReleaseGroupSummary) -> Void

    @State private var isShowingWikipedia = false
    @Environment(\.colorScheme) private var colorScheme

    private var cardBackground: Color {
        colorScheme == .dark
            ? DeckStyle.darkCardBackgroundColor
            : DeckStyle.lightCardBackgroundColor
    }

    private var hasArtistContent: Bool {
        artist != nil
    }

    var body: some View {
        Group {
            if hasArtistContent {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {

                        // Wikipedia excerpt
                        VStack(alignment: .leading, spacing: 8) {
                            if isLoadingWikipedia {
                                ProgressView()
                                    .padding(.top, 8)
                                    .padding(.bottom, 16)
                            } else if let wikipedia {
                                Text(
                                    "\(Text(displayExcerpt(for: wikipedia.extract)).foregroundStyle(.primary))\(Text(" Read more →").foregroundStyle(Color(uiColor: .link)))"
                                )
                                .font(.callout)
                                .onTapGesture {
                                    isShowingWikipedia = true
                                }
                                .padding(.top, 8)
                                .padding(.bottom, 16)
                            }
                        }

                        // Discography sections
                        ForEach(groupedDiscographySections(from: releaseGroups)) { section in
                            Section {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(section.items) { group in
                                        Button {
                                            UIApplication.shared.sendAction(
                                                #selector(UIResponder.resignFirstResponder),
                                                to: nil,
                                                from: nil,
                                                for: nil
                                            )
                                            onSelectReleaseGroup(group)
                                        } label: {
                                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                                Text(MBDateTextFormatter.year(from: group.firstReleaseDate))
                                                    .font(.callout)
                                                    .foregroundStyle(.secondary)
                                                    .frame(width: 40, alignment: .leading)

                                                Text(group.title)
                                                    .font(.callout)
                                                    .foregroundStyle(Color(uiColor: .link))
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
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

                        // Loading indicator at the bottom
                        if isLoadingMore {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                    }
                }
            } else if artistError != nil {
                ErrorStateView.artistRetry {
                    onRetryArtist()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView.artist
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 0)
            }
        }
        .sheet(isPresented: $isShowingWikipedia) {
            if let wikipedia,
               let url = wikipediaURL(for: wikipedia.title) {
                SafariView(url: url)
                    .presentationDetents([.fraction(0.885)])
            }
        }
    }

    // MARK: - Helpers

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
        ZStack {
            cardBackground

            HStack {
                Text(title.uppercased())
                    .font(DeckStyle.cardLabelFont)
                    .tracking(DeckStyle.cardLabelTracking)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .zIndex(1)
    }
}
