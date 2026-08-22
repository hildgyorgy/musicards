//
//  TrackDetailStore.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 10..
//

import Foundation
import Combine
import OSLog

@MainActor
final class TrackDetailStore: ObservableObject {
    nonisolated private static let logger = Logger(
        subsystem: "com.hildgyorgy.MusiCards",
        category: "TrackDetails"
    )

    @Published private(set) var cache: [String: TrackDetailData] = [:]
    @Published private(set) var loadingIDs: Set<String> = []
    @Published private(set) var failedIDs: Set<String> = []

    private let service: MusicBrainzService

    init(service: MusicBrainzService) {
        self.service = service
    }

    func data(for recordingID: String?) -> TrackDetailData? {
        guard let recordingID else { return nil }
        return cache[recordingID]
    }

    func isLoading(_ recordingID: String?) -> Bool {
        guard let recordingID else { return false }
        return loadingIDs.contains(recordingID)
    }

    func didFail(_ recordingID: String?) -> Bool {
        guard let recordingID else { return false }
        return failedIDs.contains(recordingID)
    }

    func fetchIfNeeded(recordingID: String) {
        guard cache[recordingID] == nil else { return }
        guard !loadingIDs.contains(recordingID) else { return }

        loadingIDs.insert(recordingID)
        failedIDs.remove(recordingID)

        Task {
            do {
                let recording = try await service.fetchRecording(id: recordingID)
                let recordingRelations = recording.relations ?? []

                let performers = buildLinkedArtistGroups(
                    from: recordingRelations,
                    bucket: .performer
                )

                var technical = buildGroups(
                    from: recordingRelations,
                    bucket: .technical
                )
                technical.append(contentsOf: buildRecordingInfo(from: recordingRelations))

                let workRef = firstWorkReference(in: recordingRelations)

                var creators: [LinkedArtistGroup] = []
                var workHierarchy: [String] = []

                if let workRef {
                    let work = try await service.fetchWork(id: workRef.id)

                    workHierarchy = buildSimpleWorkHierarchy(from: work)
                    creators = buildLinkedArtistGroups(
                        from: work.relations ?? [],
                        bucket: .creator
                    )
                }

                var notes: [String] = []
                if let disambiguation = recording.disambiguation?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !disambiguation.isEmpty {
                    notes.append(disambiguation)
                }

                let detailData = TrackDetailData(
                    recordingID: recordingID,
                    performers: performers,
                    creators: creators,
                    workHierarchy: workHierarchy,
                    technical: technical,
                    notes: notes
                )

                cache[recordingID] = detailData
                loadingIDs.remove(recordingID)
                failedIDs.remove(recordingID)

            } catch {
                loadingIDs.remove(recordingID)
                failedIDs.insert(recordingID)
                let nsError = error as NSError
                Self.logger.error(
                    "Track detail load failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) detail=\(nsError.localizedDescription, privacy: .private)"
                )
            }
        }
    }

    private func firstWorkReference(in relations: [MBRelation]) -> MBWorkReference? {
        relations.first(where: { $0.work != nil })?.work
    }

    private func buildSimpleWorkHierarchy(from work: MBWork) -> [String] {
        let title = work.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return [] }
        return [title]
    }

    private func buildGroups(
        from relations: [MBRelation],
        bucket: RelationBucket
    ) -> [TrackDetailGroup] {
        var groups: [String: [String]] = [:]

        for relation in relations {
            guard RelationClassifier.bucket(for: relation) == bucket else { continue }
            guard let artist = relation.artist else { continue }

            let artistName = artist.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artistName.isEmpty else { continue }

            let role = RelationClassifier.displayRole(for: relation)

            if groups[role] == nil {
                groups[role] = []
            }

            if !(groups[role]?.contains(artistName) ?? false) {
                groups[role]?.append(artistName)
            }
        }

        let sortedRoles = groups.keys.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }

        return sortedRoles.map { role in
            let sortedNames = (groups[role] ?? []).sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            return TrackDetailGroup(role: role, names: sortedNames)
        }
    }

    private func buildLinkedArtistGroups(
        from relations: [MBRelation],
        bucket: RelationBucket
    ) -> [LinkedArtistGroup] {
        var groups: [String: [LinkedArtist]] = [:]

        for relation in relations {
            guard RelationClassifier.bucket(for: relation) == bucket else { continue }
            guard let artist = relation.artist else { continue }

            let artistName = artist.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artistName.isEmpty else { continue }

            let role = RelationClassifier.displayRole(for: relation)

            if groups[role] == nil {
                groups[role] = []
            }

            let linkedArtist = LinkedArtist(
                id: artist.id,
                name: artist.name
            )

            if !(groups[role]?.contains(linkedArtist) ?? false) {
                groups[role]?.append(linkedArtist)
            }
        }

        let sortedRoles = groups.keys.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }

        return sortedRoles.map { role in
            let sortedArtists = (groups[role] ?? []).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return LinkedArtistGroup(role: role, artists: sortedArtists)
        }
    }

    private func buildRecordingInfo(from relations: [MBRelation]) -> [TrackDetailGroup] {
        var results: [TrackDetailGroup] = []

        let places = relations
            .filter { ($0.type ?? "").lowercased() == "recorded at" }
            .compactMap { $0.place?.name }
            .filter { !$0.isEmpty }

        if !places.isEmpty {
            results.append(
                TrackDetailGroup(
                    role: "recorded at",
                    names: places
                )
            )
        }

        let dates = relations
            .filter { ($0.type ?? "").lowercased() == "recorded at" }
            .compactMap { relation -> String? in
                let begin = relation.begin
                let end = relation.end

                switch (begin, end) {
                case let (b?, e?) where b != e:
                    return "\(b) – \(e)"
                case let (b?, _):
                    return b
                case let (_, e?):
                    return e
                default:
                    return nil
                }
            }

        if !dates.isEmpty {
            results.append(
                TrackDetailGroup(
                    role: "recorded",
                    names: dates
                )
            )
        }

        return results
    }
}
