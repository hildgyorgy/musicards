//
//  TracksCardContentView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 07..
//

import SwiftUI

struct TracksCardContentView: View {
    let release: MBRelease?
    let onSelectArtist: (String) -> Void
    @ObservedObject var detailStore: TrackDetailStore

    @State private var expandedRecordingID: String?
    @State private var selectedPageByRecordingID: [String: Int] = [:]

    @Environment(\.colorScheme) private var colorScheme

    // Classical support — owned here, matching the MBViewer pattern.
    @ObservedObject var classicalMetadataStore: ClassicalMetadataStore

    // MARK: - Derived colours

    private var cardBackground: Color {
            colorScheme == .dark
                ? AppStyle.darkCardBackgroundColor
                : AppStyle.lightCardBackgroundColor
        }

    // MARK: - Classical detection
    //
    // We detect on title structure alone (no API data needed) so the decision
    // is available immediately and never flips mid-render. A release is
    // considered classical when the formatter produces at least one
    // .composerHeader or .workHeader row across any medium.

    private func isClassicalRelease(_ release: MBRelease) -> Bool {
        for medium in release.media ?? [] {
            let rows = ClassicalTrackFormatter.buildRows(
                from: medium.tracks ?? [],
                composerForTrack: { _ in nil }   // title-only pass
            )
            let hasStructure = rows.contains {
                if case .composerHeader = $0 { return true }
                if case .workHeader     = $0 { return true }
                return false
            }
            if hasStructure { return true }
        }
        return false
    }

    // MARK: - Body

    var body: some View {
        if let release {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if isClassicalRelease(release) {
                        classicalSections(for: release)
                    } else {
                        flatSections(for: release)
                    }
                    releaseLinerNotes(for: release)
                }
            }
            .task(id: release.id) {
                // Preload composer metadata for all tracks so composer headers
                // can appear as the view renders.
                for medium in release.media ?? [] {
                    await classicalMetadataStore.preload(for: medium.tracks ?? [])
                }
            }
        }  else {
            EmptyStateView.tracks
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 0)
        }
    }

    // MARK: - Flat layout

    @ViewBuilder
    private func flatSections(for release: MBRelease) -> some View {
        let sections = trackSections(from: release)

        ForEach(sections) { section in
            Section {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(section.rows) { row in
                        expandableTrackRow(row)
                    }
                }
                .padding(.bottom, 24)
            } header: {
                mediumHeader(section.title)
            }
        }
    }

    // MARK: - Classical layout

    @ViewBuilder
    private func classicalSections(for release: MBRelease) -> some View {
        ForEach(Array((release.media ?? []).enumerated()), id: \.offset) { index, medium in
            let tracks = medium.tracks ?? []
            let rows = ClassicalTrackFormatter.buildRows(
                from: tracks,
                composerForTrack: { track in
                    classicalMetadataStore.composerName(for: track.recording?.id)
                }
            )
            let sectionTitle = mediumSummaryString(
                medium: medium,
                index: index,
                trackCount: tracks.count
            )

            Section {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, displayRow in
                        switch displayRow {
                        case .composerHeader(let name):
                            classicalComposerHeaderRow(name)

                        case .workHeader(let title):
                            classicalWorkHeaderRow(title)

                        case .track(let position, let title, let length, let recordingID, let isMovement):
                            // Reconstruct the TrackRow that the shared row
                            // renderer expects, sourcing from the original track.
                            let trackRow = TrackRow(
                                recordingID: recordingID,
                                number: position,
                                title: title,
                                subtitle: length ?? "",
                                mediumIndex: index,
                                isMovement: isMovement
                            )
                            expandableTrackRow(trackRow)
                        }
                    }
                }
                .padding(.bottom, 24)
            } header: {
                mediumHeader(sectionTitle)
            }
        }
    }

    // MARK: - Classical header rows

    private func classicalComposerHeaderRow(_ name: String) -> some View {
        Text(name.uppercased())
            .font(.footnote)
            .tracking(1.0)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, classicalHeaderLeadingInset)
            .padding(.trailing, 12)
            .padding(.top, 12)
            .padding(.bottom, 2)
    }

    private func classicalWorkHeaderRow(_ title: String) -> some View {
        Text(title)
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, classicalHeaderLeadingInset)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .foregroundStyle(.primary)
    }

    /// Leading inset that aligns classical headers with the track title text.
    /// Matches: trackNumber width (20) + spacing (10) + leading padding (12).
    private var classicalHeaderLeadingInset: CGFloat { 0 }

    // MARK: - Shared expandable track row

    @ViewBuilder
    private func expandableTrackRow(_ row: TrackRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(AppStyle.animation) {
                    toggleExpanded(for: row)
                }
            } label: {
                trackRowView(row)
            }
            .buttonStyle(.plain)
            .zIndex(isExpanded(row) ? 10 : 0)

            if isExpanded(row) {
                if detailStore.isLoading(row.recordingID) {
                    MusiCardsSpinner()
                        .padding()
                } else {
                    TrackDetailPagerView(
                        selectedPage: bindingForSelectedPage(recordingID: row.recordingID),
                        recordingID: row.recordingID,
                        detailStore: detailStore,
                        onSelectArtist: onSelectArtist
                    )
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    // MARK: - Track row visual (shared between flat and classical)

    private func trackRowView(_ row: TrackRow) -> some View {
        ZStack {
            if isExpanded(row) {
                Capsule(style: .continuous)
                    .fill(Color.gray.opacity(0.15))
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(row.number.map(String.init) ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .leading)
                    .monospacedDigit()

                Text(row.title)
                    .font(.callout.weight(isExpanded(row) ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.leading, row.isMovement ? 0 : 0)

                Spacer(minLength: 10)

                Text(row.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .padding(.vertical, 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    // MARK: - Release-level liner notes

    @ViewBuilder
    private func releaseLinerNotes(for release: MBRelease) -> some View {
        let credits = releaseLevelCreditRows(from: release)
        let annotation = cleanedAnnotation(release.annotation)

        if !credits.isEmpty || annotation != nil {
            VStack(alignment: .leading, spacing: 12) {
                if !credits.isEmpty {
                    releaseCreditsSection(credits)
                }

                if let annotation {
                    releaseAnnotationSection(annotation)
                }
            }
            .padding(.horizontal, 0)
            .padding(.top, 4)
            .padding(.bottom, 36)
        }
    }

    private func releaseCreditsSection(_ rows: [ReleaseCreditRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            mediumHeader("RELEASE-LEVEL CREDITS")

            VStack(alignment: .leading, spacing: 5) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.role)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(width: 120, alignment: .leading)

                        Text(row.name)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 12)
        }
    }

    private func releaseAnnotationSection(_ annotation: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            mediumHeader("ANNOTATION")

            Text(annotation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .padding(.trailing, 12)
        }
    }
    
    private func releaseLevelCreditRows(from release: MBRelease) -> [ReleaseCreditRow] {
        let ignoredURLTypes: Set<String> = [
            "discogs",
            "allmusic",
            "amazon asin",
            "purchase for download",
            "purchase for mail-order",
            "streaming",
            "free streaming",
            "download for free",
            "license"
        ]

        return (release.relations ?? [])
            .compactMap { relation -> ReleaseCreditRow? in
                // We only want true release-level relationships here,
                // not generic external URL relationships.
                if relation.url != nil { return nil }

                guard let rawType = relation.type?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !rawType.isEmpty
                else {
                    return nil
                }

                let loweredType = rawType.lowercased()
                if ignoredURLTypes.contains(loweredType) {
                    return nil
                }

                let name =
                    relation.artist?.name ??
                    relation.label?.name ??
                    relation.place?.name ??
                    relation.work?.title

                guard let name,
                      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    return nil
                }

                let role = formattedReleaseRelationRole(rawType, attributes: relation.attributes)

                return ReleaseCreditRow(
                    role: role,
                    name: name
                )
            }
    }

    private func formattedReleaseRelationRole(_ type: String, attributes: [String]?) -> String {
        let role = type
            .replacingOccurrences(of: "_", with: " ")
            .capitalized

        let cleanAttributes =
            (attributes ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

        if cleanAttributes.isEmpty {
            return role
        } else {
            return "\(role) (\(cleanAttributes.joined(separator: ", ")))"
        }
    }

    private func cleanedAnnotation(_ annotation: String?) -> String? {
        guard let annotation else { return nil }

        let cleaned = annotation
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Medium header

    @ViewBuilder
    private func mediumHeader(_ title: String) -> some View {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .background {
                    #if os(macOS)
                    Rectangle().fill(.ultraThinMaterial)
                    #else
                    Rectangle().fill(cardBackground)
                    #endif
                }
        }

    // MARK: - Expand / collapse

    private func isExpanded(_ row: TrackRow) -> Bool {
        expandedRecordingID == row.recordingID
    }

    private func toggleExpanded(for row: TrackRow) {
        if expandedRecordingID == row.recordingID {
            expandedRecordingID = nil
        } else {
            expandedRecordingID = row.recordingID

            if let id = row.recordingID {
                detailStore.fetchIfNeeded(recordingID: id)
            }
        }
    }

    private func bindingForSelectedPage(recordingID: String?) -> Binding<Int> {
        let key = recordingID ?? "no-recording-id"

        return Binding(
            get: { selectedPageByRecordingID[key] ?? 1 },
            set: { selectedPageByRecordingID[key] = $0 }
        )
    }

    // MARK: - Data helpers (flat layout)

    private func trackSections(from release: MBRelease) -> [TrackSection] {
        var sections: [TrackSection] = []

        for (index, medium) in (release.media ?? []).enumerated() {
            let tracks = medium.tracks ?? []

            let rows: [TrackRow] = tracks.map { track in
                TrackRow(
                    recordingID: track.recording?.id,
                    number: track.position,
                    title: track.title,
                    subtitle: track.length.map(formatMilliseconds) ?? "",
                    mediumIndex: index
                )
            }

            let title = mediumSummaryString(
                medium: medium,
                index: index,
                trackCount: tracks.count
            )

            sections.append(
                TrackSection(
                    id: "\(index)",
                    title: title,
                    rows: rows
                )
            )
        }

        return sections
    }

    private func mediumSummaryString(
        medium: MBMedium,
        index: Int,
        trackCount: Int
    ) -> String {
        let mediumName = medium.format ?? "CD \(index + 1)"
        let countText = "\(trackCount) \(trackCount == 1 ? "TRACK" : "TRACKS")"

        let totalMilliseconds =
            (medium.tracks ?? [])
                .compactMap { $0.length }
                .reduce(0, +)

        let durationText =
            totalMilliseconds > 0
            ? formatMilliseconds(totalMilliseconds)
            : ""

        let parts = [mediumName, countText, durationText]
            .filter { !$0.isEmpty }

        return parts.joined(separator: " • ")
    }

    private func formatMilliseconds(_ milliseconds: Int) -> String {
        let totalSeconds = milliseconds / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Private models

private struct TrackRow: Identifiable {
    let recordingID: String?
    let number: Int?
    let title: String
    let subtitle: String
    let mediumIndex: Int
    var isMovement: Bool = false

    var id: String {
        if let recordingID {
            return recordingID
        } else {
            return "\(mediumIndex)-\(number ?? 0)-\(title)"
        }
    }
}

private struct TrackSection: Identifiable {
    let id: String
    let title: String
    let rows: [TrackRow]
}

private struct ReleaseCreditRow: Identifiable {
    let id = UUID()
    let role: String
    let name: String
}
