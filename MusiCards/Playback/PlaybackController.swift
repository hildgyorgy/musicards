//
//  PlaybackController.swift
//  MusiCards
//

import Combine
import Foundation
#if os(iOS)
import AVFAudio
#endif
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
    @Published private(set) var preparedAudioFormat: PlaybackAudioFormat?
    @Published private(set) var outputRoute = AudioOutputRouteInspector.current()
    @Published private(set) var externalOutputDisplayName: String?
    @Published private(set) var outputVolumeState: PlaybackVolumeState?
    @Published private(set) var outputVolumeErrorMessage: String?

    private let engine: PlaybackEngine
    private let assetResolver: (any PlaybackAssetResolving)?
    private var preparedItemID: PlaybackQueueItem.ID?
    private var pendingOutputResumePosition: TimeInterval?
    private var playbackGeneration: UInt64 = 0
    private var outputVolumeGeneration: UInt64 = 0
    private var outputRouteObservation: AnyCancellable?
    #if os(macOS)
    private var macOutputRouteObserver: MacOutputRouteObserver?
    #endif

    init(
        engine: PlaybackEngine,
        assetResolver: (any PlaybackAssetResolving)? = nil
    ) {
        self.engine = engine
        self.assetResolver = assetResolver
        engine.eventHandler = { [weak self] event in
            self?.handle(event)
        }
        #if os(iOS)
        outputRouteObservation = NotificationCenter.default.publisher(
            for: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        ).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshOutputRoute()
            }
        }
        #elseif os(macOS)
        macOutputRouteObserver = MacOutputRouteObserver { [weak self] in
            self?.refreshOutputRoute()
        }
        if macOutputRouteObserver?.hasSystemListener == false {
            // Retain the previous fallback only when Core Audio cannot install
            // its default-device notification.
            outputRouteObservation = Timer.publish(
                every: 2,
                on: .main,
                in: .common
            ).autoconnect().sink { [weak self] _ in
                self?.refreshOutputRoute()
            }
        }
        #endif
    }

    var currentItem: PlaybackQueueItem? {
        guard let currentIndex, queue.indices.contains(currentIndex) else {
            return nil
        }
        return queue[currentIndex]
    }

    var canAdoptRendererPlayback: Bool {
        switch status {
        case .idle:
            queue.isEmpty
        case .stopped, .failed:
            true
        case .loading, .ready, .playing, .paused:
            false
        }
    }

    var outputDisplayName: String {
        externalOutputDisplayName ?? outputRoute.detailDisplayName
    }

    var outputSampleRateText: String? {
        externalOutputDisplayName == nil ? outputRoute.sampleRateText : nil
    }

    var canControlOutputVolume: Bool {
        (engine as? any PlaybackVolumeControlling)?.canControlVolume == true
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
        pendingOutputResumePosition = nil
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
        preparedAudioFormat = nil
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
        pendingOutputResumePosition = nil
        position = 0
        preparedDuration = nil
        preparedAudioFormat = nil

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
                if pendingOutputResumePosition == nil {
                    position = 0
                }
                preparedDuration = currentItem.track.duration
                preparedAudioFormat = nil
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
            if let resumePosition = pendingOutputResumePosition {
                pendingOutputResumePosition = nil
                if engine.canSeek, resumePosition > 0 {
                    do {
                        try await engine.seek(to: resumePosition)
                    } catch {
                        await engine.stop()
                        throw error
                    }
                    guard isCurrent(generation: generation, itemID: itemID),
                          !Task.isCancelled else {
                        await engine.stop()
                        return
                    }
                    position = resumePosition
                } else {
                    position = 0
                }
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
        pendingOutputResumePosition = nil
        position = 0
        preparedAudioFormat = nil
        status = queue.isEmpty ? .idle : .stopped
        await engine.stop()
        engine.restoreOutputConfiguration()
    }

    func restoreOutputConfiguration() {
        engine.restoreOutputConfiguration()
    }

    func setExternalOutputDisplayName(_ name: String?) {
        externalOutputDisplayName = name
        if name == nil {
            outputVolumeState = nil
            outputVolumeErrorMessage = nil
        }
    }

    func refreshOutputVolume() async {
        guard let controller = engine as? any PlaybackVolumeControlling,
              controller.canControlVolume else {
            outputVolumeState = nil
            outputVolumeErrorMessage = nil
            return
        }
        do {
            outputVolumeState = try await controller.outputVolumeState()
            outputVolumeErrorMessage = nil
        } catch {
            outputVolumeErrorMessage = error.localizedDescription
        }
    }

    func setOutputVolume(_ level: Double) async {
        guard let controller = engine as? any PlaybackVolumeControlling else {
            return
        }
        outputVolumeGeneration &+= 1
        let generation = outputVolumeGeneration
        let clampedLevel = min(max(level, 0), 1)
        outputVolumeState = PlaybackVolumeState(
            level: clampedLevel,
            isMuted: outputVolumeState?.isMuted ?? false
        )
        do {
            let confirmedState = try await controller.setOutputVolume(
                clampedLevel
            )
            guard generation == outputVolumeGeneration else { return }
            if let confirmedState {
                outputVolumeState = confirmedState
            }
            outputVolumeErrorMessage = nil
        } catch {
            guard generation == outputVolumeGeneration,
                  !(error is CancellationError) else { return }
            outputVolumeErrorMessage = error.localizedDescription
        }
    }

    func setOutputMuted(_ isMuted: Bool) async {
        guard let controller = engine as? any PlaybackVolumeControlling else {
            return
        }
        do {
            outputVolumeState = try await controller.setOutputMuted(isMuted)
            outputVolumeErrorMessage = nil
        } catch {
            outputVolumeErrorMessage = error.localizedDescription
        }
    }

    /// Stops the previous route and prepares the current item again on the
    /// newly committed output. A playing queue continues automatically;
    /// paused and stopped queues wait for the next explicit Play command.
    func outputSelectionDidChange() async {
        let shouldResume = status.isPlaying
        let previousPosition = position
        let generation = advancePlaybackGeneration()
        await engine.stop()
        guard generation == playbackGeneration else { return }

        preparedItemID = nil
        pendingOutputResumePosition = previousPosition > 0
            ? previousPosition : nil
        position = previousPosition
        preparedAudioFormat = nil
        status = queue.isEmpty ? .idle : .stopped

        await refreshOutputVolume()
        guard generation == playbackGeneration else { return }

        if shouldResume {
            await play()
        }
    }

    func rendererSnapshot() async throws -> AVTransportSnapshot? {
        guard let renderer = engine as? any RendererPlaybackSessionControlling
        else { return nil }
        return try await renderer.rendererSnapshot()
    }

    func adoptRendererPlayback(
        queue newQueue: ReleasePlaybackQueue,
        snapshot: AVTransportSnapshot
    ) async throws {
        guard let renderer = engine as? any RendererPlaybackSessionControlling,
              newQueue.items.indices.contains(newQueue.selectedIndex) else {
            return
        }
        _ = advancePlaybackGeneration()
        pendingOutputResumePosition = nil
        queue = newQueue.items
        currentIndex = newQueue.selectedIndex
        let item = newQueue.items[newQueue.selectedIndex]
        preparedItemID = item.id
        position = snapshot.position.relativeTime ?? 0
        preparedDuration = snapshot.position.duration ?? item.track.duration
        preparedAudioFormat = item.track.audioFormat
        status = .ready
        do {
            let resolved = try await resolvedItem(item)
            try await renderer.adoptRendererSession(
                item: resolved,
                snapshot: snapshot
            )
        } catch {
            queue = []
            currentIndex = nil
            preparedItemID = nil
            position = 0
            preparedDuration = nil
            preparedAudioFormat = nil
            status = .idle
            throw error
        }
    }

    func resolvedNextItemForRenderer() async throws -> PlaybackQueueItem? {
        guard let currentIndex else { return nil }
        let nextIndex = currentIndex + 1
        guard queue.indices.contains(nextIndex) else { return nil }
        return try await resolvedItem(queue[nextIndex])
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
            preparedAudioFormat = nil
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
        pendingOutputResumePosition = nil
        position = 0
        preparedDuration = queue[index].track.duration
        preparedAudioFormat = nil
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
        case .prepared(let duration, let audioFormat):
            refreshOutputRoute()
            preparedDuration = duration ?? currentItem?.track.duration
            preparedAudioFormat = audioFormat
        case .started:
            refreshOutputRoute()
            status = .playing
        case .paused:
            status = .paused
        case .positionChanged(let position):
            self.position = max(position, 0)
        case let .advancedToNext(itemID, duration, audioFormat, position):
            guard let currentIndex else { return }
            let nextIndex = currentIndex + 1
            guard queue.indices.contains(nextIndex),
                  queue[nextIndex].id == itemID else { return }
            self.currentIndex = nextIndex
            preparedItemID = itemID
            preparedDuration = duration ?? queue[nextIndex].track.duration
            preparedAudioFormat = audioFormat
            self.position = max(position, 0)
            status = .playing
        case .volumeChanged(let state):
            outputVolumeState = state
            outputVolumeErrorMessage = nil
        case .outputConfigurationChanged:
            refreshOutputRoute()
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
            preparedAudioFormat = nil
            status = .failed(failure)
        }
    }

    private func refreshOutputRoute() {
        let currentRoute = AudioOutputRouteInspector.current()
        if outputRoute != currentRoute {
            outputRoute = currentRoute
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
