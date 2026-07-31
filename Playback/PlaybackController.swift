//
//  PlaybackController.swift
//  MusiCards
//

import Combine
import Foundation

@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var queue: [PlaybackQueueItem] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var status: PlaybackStatus = .idle
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var preparedDuration: TimeInterval?

    private let engine: PlaybackEngine
    private var preparedItemID: PlaybackQueueItem.ID?

    init(engine: PlaybackEngine) {
        self.engine = engine
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

    func replaceQueue(
        with items: [PlaybackQueueItem],
        startingAt requestedIndex: Int = 0
    ) async {
        await engine.stop()

        queue = items
        preparedItemID = nil
        position = 0
        preparedDuration = nil

        guard !items.isEmpty else {
            currentIndex = nil
            status = .idle
            return
        }

        currentIndex = min(max(requestedIndex, 0), items.count - 1)
        status = .idle
    }

    func clearQueue() async {
        await replaceQueue(with: [])
    }

    func play() async {
        guard let currentItem else { return }

        do {
            if preparedItemID != currentItem.id {
                status = .loading
                position = 0
                preparedDuration = currentItem.track.duration
                try await engine.prepare(currentItem)
                preparedItemID = currentItem.id
                status = .ready
            }

            try await engine.play()
            status = .playing
        } catch {
            fail(with: error)
        }
    }

    func pause() async {
        guard status.isPlaying else { return }
        await engine.pause()
        status = .paused
    }

    func togglePlayback() async {
        if status.isPlaying {
            await pause()
        } else {
            await play()
        }
    }

    func stop() async {
        await engine.stop()
        position = 0
        status = queue.isEmpty ? .idle : .stopped
    }

    func seek(to requestedPosition: TimeInterval) async {
        guard currentItem != nil else { return }

        let upperBound = preparedDuration ?? currentItem?.track.duration
        let position = min(max(requestedPosition, 0), upperBound ?? requestedPosition)

        do {
            try await engine.seek(to: position)
            self.position = position
        } catch {
            fail(with: error)
        }
    }

    func selectItem(at index: Int, autoplay: Bool = false) async {
        guard queue.indices.contains(index) else { return }

        await engine.stop()
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
            status = .ready
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
            status = .failed(failure)
        }
    }

    private func fail(with error: Error) {
        status = .failed(PlaybackFailure(error))
    }
}
