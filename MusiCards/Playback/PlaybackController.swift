//
//  PlaybackController.swift
//  MusiCards
//

import Combine
import Foundation
#if DEBUG
import OSLog
#endif

struct PlaybackQueueRequest: Equatable, Sendable {
    fileprivate let generation: UInt64
}

@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var queue: [PlaybackQueueItem] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var status: PlaybackStatus = .idle
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var preparedDuration: TimeInterval?

    private let engine: PlaybackEngine
    private let assetResolver: (any PlaybackAssetResolving)?
    private var preparedItemID: PlaybackQueueItem.ID?
    private var playbackGeneration: UInt64 = 0

    init(
        engine: PlaybackEngine,
        assetResolver: (any PlaybackAssetResolving)? = nil
    ) {
        self.engine = engine
        self.assetResolver = assetResolver
        engine.eventHandler = { [weak self] event in
            self?.handle(event)
        }
    }

    var currentItem: PlaybackQueueItem? {
        guard let currentIndex, queue.indices.contains(currentIndex) else {
            return nil
        }
        return queue[currentIndex]
    }

    var hasPrevious: Bool {
        guard let currentIndex else { return false }
        return currentIndex > queue.startIndex
    }

    var hasNext: Bool {
        guard let currentIndex else { return false }
        return currentIndex < queue.index(before: queue.endIndex)
    }

    var canSeek: Bool {
        if let preparedItemID, preparedItemID == currentItem?.id {
            return engine.canSeek
        }
        return currentItem?.source.seekCapability.isSupported == true
    }

    func beginQueueRequest() -> PlaybackQueueRequest {
        let generation = advancePlaybackGeneration()
        status = .loading
        return PlaybackQueueRequest(generation: generation)
    }

    @discardableResult
    func prepareForQueueReplacement(
        _ request: PlaybackQueueRequest
    ) async -> Bool {
        guard isCurrent(request) else { return false }
        await engine.stop()
        guard isCurrent(request) else { return false }
        preparedItemID = nil
        position = 0
        preparedDuration = nil
        return true
    }

    func abandonQueueRequest(_ request: PlaybackQueueRequest) {
        guard isCurrent(request) else { return }
        status = queue.isEmpty ? .idle : .stopped
    }

    @discardableResult
    func replaceQueue(
        with items: [PlaybackQueueItem],
        startingAt requestedIndex: Int = 0,
        request: PlaybackQueueRequest? = nil
    ) async -> Bool {
        let generation: UInt64
        if let request {
            guard isCurrent(request) else { return false }
            generation = request.generation
        } else {
            generation = advancePlaybackGeneration()
        }

        await engine.stop()
        guard generation == playbackGeneration else { return false }

        queue = items
        preparedItemID = nil
        position = 0
        preparedDuration = nil

        guard !items.isEmpty else {
            currentIndex = nil
            status = .idle
            return true
        }

        currentIndex = min(max(requestedIndex, 0), items.count - 1)
        status = .idle
        return true
    }

    func clearQueue() async {
        await replaceQueue(with: [])
        engine.restoreOutputConfiguration()
    }

    func play() async {
        guard status != .loading, let currentItem else { return }
        let generation = playbackGeneration
        let itemID = currentItem.id

        do {
            if preparedItemID != itemID {
                status = .loading
                position = 0
                preparedDuration = currentItem.track.duration
                let resolvedItem = try await resolvedItem(currentItem)
                guard isCurrent(generation: generation, itemID: itemID),
                      !Task.isCancelled else {
                    return
                }
                try await engine.prepare(resolvedItem)
                guard isCurrent(generation: generation, itemID: itemID),
                      !Task.isCancelled else {
                    await engine.stop()
                    return
                }
                preparedItemID = itemID
                status = .ready
            }

            try await engine.play()
            guard isCurrent(generation: generation, itemID: itemID),
                  !Task.isCancelled else {
                await engine.stop()
                return
            }
            status = .playing
        } catch {
            guard isCurrent(generation: generation, itemID: itemID),
                  !(error is CancellationError) else {
                return
            }
            fail(with: error)
        }
    }

    func pause() async {
        guard status.isPlaying else { return }
        await engine.pause()
        status = .paused
    }

    func togglePlayback() async {
        guard status != .loading else { return }
        if status.isPlaying {
            await pause()
        } else {
            await play()
        }
    }

    func stop() async {
        _ = advancePlaybackGeneration()
        preparedItemID = nil
        position = 0
        status = queue.isEmpty ? .idle : .stopped
        await engine.stop()
        engine.restoreOutputConfiguration()
    }

    func restoreOutputConfiguration() {
        engine.restoreOutputConfiguration()
    }

    func seek(to requestedPosition: TimeInterval) async {
        guard currentItem != nil else { return }
        guard canSeek else {
            #if DEBUG
            RemotePlaybackDiagnostics.logger.notice(
                "Remote seek rejected before decoder mutation capability=unsupported"
            )
            #endif
            return
        }

        let upperBound = preparedDuration ?? currentItem?.track.duration
        let position = min(max(requestedPosition, 0), upperBound ?? requestedPosition)

        do {
            try await engine.seek(to: position)
            self.position = position
        } catch {
            preparedItemID = nil
            fail(with: error)
        }
    }

    func selectItem(at index: Int, autoplay: Bool = false) async {
        guard queue.indices.contains(index) else { return }
        let generation = advancePlaybackGeneration()

        await engine.stop()
        guard generation == playbackGeneration else { return }
        currentIndex = index
        preparedItemID = nil
        position = 0
        preparedDuration = queue[index].track.duration
        status = .idle

        if autoplay {
            await play()
        }
    }

    func selectNext(autoplay: Bool? = nil) async {
        guard hasNext, let currentIndex else { return }
        let shouldAutoplay = autoplay ?? status.isPlaying
        await selectItem(at: currentIndex + 1, autoplay: shouldAutoplay)
    }

    func selectPrevious(autoplay: Bool? = nil) async {
        guard hasPrevious, let currentIndex else { return }
        let shouldAutoplay = autoplay ?? status.isPlaying
        await selectItem(at: currentIndex - 1, autoplay: shouldAutoplay)
    }

    private func handle(_ event: PlaybackEngineEvent) {
        switch event {
        case .prepared(let duration):
            preparedDuration = duration ?? currentItem?.track.duration
        case .started:
            status = .playing
        case .paused:
            status = .paused
        case .positionChanged(let position):
            self.position = max(position, 0)
        case .finished:
            Task {
                if hasNext {
                    await selectNext(autoplay: true)
                } else {
                    await stop()
                }
            }
        case .failed(let failure):
            preparedItemID = nil
            status = .failed(failure)
        }
    }

    private func fail(with error: Error) {
        status = .failed(PlaybackFailure(error))
    }

    private func resolvedItem(
        _ item: PlaybackQueueItem
    ) async throws -> PlaybackQueueItem {
        switch item.source {
        case .localFile, .remoteAudio:
            return item
        case .libraryAsset(let reference):
            guard let assetResolver else {
                throw PlaybackAssetResolutionError.providerUnavailable(
                    reference.source
                )
            }
            let source = try await assetResolver.resolvePlaybackAsset(reference)
            switch source {
            case .localFile, .remoteAudio:
                return item.replacingSource(source)
            case .libraryAsset:
                throw PlaybackAssetResolutionError.assetUnavailable
            }
        }
    }

    @discardableResult
    private func advancePlaybackGeneration() -> UInt64 {
        playbackGeneration &+= 1
        return playbackGeneration
    }

    private func isCurrent(_ request: PlaybackQueueRequest) -> Bool {
        request.generation == playbackGeneration
    }

    private func isCurrent(
        generation: UInt64,
        itemID: PlaybackQueueItem.ID
    ) -> Bool {
        generation == playbackGeneration && currentItem?.id == itemID
    }
}
