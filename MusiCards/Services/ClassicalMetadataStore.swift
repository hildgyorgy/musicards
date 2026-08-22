//
//  ClassicalMetadataStore.swift
//  MusiCards
//
//  Ported from MBViewer. Adapted to MusiCards' MusicBrainzService init pattern.
//

import Foundation
import Combine
import OSLog

@MainActor
final class ClassicalMetadataStore: ObservableObject {
    nonisolated private static let logger = Logger(
        subsystem: "com.hildgyorgy.MusiCards",
        category: "ClassicalMetadata"
    )

    // MARK: - Published state

    /// Maps recordingID → composer name. Updates trigger view re-render.
    @Published private(set) var composerNames: [String: String] = [:]

    // MARK: - Private

    private let service: MusicBrainzService
    private var recordingToWorkID: [String: String] = [:]
    private var loadingRecordings: Set<String> = []
    private var loadingWorks: Set<String> = []

    // MARK: - Init

    init(service: MusicBrainzService) {
        self.service = service
    }

    // MARK: - Public interface

    func composerName(for recordingID: String?) -> String? {
        guard let recordingID else { return nil }
        return composerNames[recordingID]
    }

    func preload(for tracks: [MBTrack]) async {
        for track in tracks {
            await loadComposerMetadata(for: track)
        }
    }

    // MARK: - Private loading

    private func loadComposerMetadata(for track: MBTrack) async {
        guard let recordingID = track.recording?.id else { return }

        guard composerNames[recordingID] == nil else { return }
        guard recordingToWorkID[recordingID] == nil else { return }
        guard !loadingRecordings.contains(recordingID) else { return }

        loadingRecordings.insert(recordingID)
        defer { loadingRecordings.remove(recordingID) }

        do {
            let recording = try await service.fetchRecording(id: recordingID)

            guard let workRef = firstWorkReference(in: recording.relations) else { return }

            let workID = workRef.id
            recordingToWorkID[recordingID] = workID

            guard !loadingWorks.contains(workID) else { return }

            loadingWorks.insert(workID)
            defer { loadingWorks.remove(workID) }

            let work = try await service.fetchWork(id: workID)

            if let name = composerName(from: work.relations) {
                composerNames[recordingID] = name
            }
        } catch {
            let nsError = error as NSError
            Self.logger.error(
                "Classical metadata load failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) detail=\(nsError.localizedDescription, privacy: .private)"
            )
        }
    }

    private func firstWorkReference(in relations: [MBRelation]?) -> MBWorkReference? {
        relations?.first(where: { $0.work != nil })?.work
    }

    private func composerName(from relations: [MBRelation]?) -> String? {
        relations?
            .first(where: { ($0.type ?? "").lowercased() == "composer" })?
            .artist?
            .name
    }
}
