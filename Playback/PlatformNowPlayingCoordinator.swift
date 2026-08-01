//
//  PlatformNowPlayingCoordinator.swift
//  MusiCards
//

#if os(iOS) || os(macOS)
import Combine
import Foundation
import MediaPlayer
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
final class PlatformNowPlayingCoordinator {
    private struct PublishedSnapshot: Equatable {
        let itemID: String
        let title: String
        let artist: String
        let albumTitle: String
        let duration: TimeInterval?
        let elapsedSecond: Int
        let status: PlaybackStatus
    }

    private weak var controller: PlaybackController?
    private var cancellables: Set<AnyCancellable> = []
    private var commandTargets: [(command: MPRemoteCommand, target: Any)] = []
    private var lastPublishedSnapshot: PublishedSnapshot?
    private var cachedArtworkItemID: String?
    private var cachedArtwork: MPMediaItemArtwork?

    init(controller: PlaybackController) {
        self.controller = controller
        configureRemoteCommands()
        observePlayback(controller)
    }

    deinit {
        for registration in commandTargets {
            registration.command.removeTarget(registration.target)
        }
    }

    private func observePlayback(_ controller: PlaybackController) {
        Publishers.CombineLatest4(
            controller.$queue,
            controller.$currentIndex,
            controller.$status,
            controller.$position
        )
        .combineLatest(controller.$preparedDuration)
        .sink { [weak self] playback, preparedDuration in
            let (queue, currentIndex, status, position) = playback
            self?.publish(
                queue: queue,
                currentIndex: currentIndex,
                status: status,
                position: position,
                preparedDuration: preparedDuration
            )
        }
        .store(in: &cancellables)
    }

    private func publish(
        queue: [PlaybackQueueItem],
        currentIndex: Int?,
        status: PlaybackStatus,
        position: TimeInterval,
        preparedDuration: TimeInterval?
    ) {
        guard let currentIndex, queue.indices.contains(currentIndex) else {
            clearNowPlayingInfo()
            updateRemoteCommandAvailability(
                hasItem: false,
                canSeek: false,
                status: status
            )
            return
        }

        let item = queue[currentIndex]
        let duration = preparedDuration ?? item.track.duration
        let snapshot = PublishedSnapshot(
            itemID: item.id,
            title: item.track.title,
            artist: item.track.artist,
            albumTitle: item.track.albumTitle,
            duration: duration,
            elapsedSecond: max(Int(position.rounded(.down)), 0),
            status: status
        )

        updateRemoteCommandAvailability(
            hasItem: true,
            canSeek: duration != nil,
            status: status
        )
        guard snapshot != lastPublishedSnapshot else { return }
        lastPublishedSnapshot = snapshot

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPMediaItemPropertyArtist: snapshot.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: status.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType:
                MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyExcludeFromSuggestions: true
        ]

        if !snapshot.albumTitle.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = snapshot.albumTitle
        }
        if let duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork = artwork(for: item) {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        let infoCenter = MPNowPlayingInfoCenter.default()
        infoCenter.nowPlayingInfo = info
        #if os(macOS)
        infoCenter.playbackState = macPlaybackState(for: status)
        #endif
    }

    private func clearNowPlayingInfo() {
        guard lastPublishedSnapshot != nil else { return }
        lastPublishedSnapshot = nil
        cachedArtworkItemID = nil
        cachedArtwork = nil
        let infoCenter = MPNowPlayingInfoCenter.default()
        infoCenter.nowPlayingInfo = nil
        #if os(macOS)
        infoCenter.playbackState = .stopped
        #endif
    }

    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        addTarget(to: commandCenter.playCommand) { [weak self] in
            guard let controller = self?.controller else { return }
            await controller.play()
        }
        addTarget(to: commandCenter.pauseCommand) { [weak self] in
            guard let controller = self?.controller else { return }
            await controller.pause()
        }
        addTarget(to: commandCenter.togglePlayPauseCommand) { [weak self] in
            guard let controller = self?.controller else { return }
            await controller.togglePlayback()
        }
        addTarget(to: commandCenter.stopCommand) { [weak self] in
            guard let controller = self?.controller else { return }
            await controller.stop()
        }

        let positionTarget = commandCenter.changePlaybackPositionCommand
            .addTarget { [weak self] event in
                guard let positionEvent =
                        event as? MPChangePlaybackPositionCommandEvent
                else {
                    return .commandFailed
                }

                let position = positionEvent.positionTime
                Task { @MainActor [weak self] in
                    guard let controller = self?.controller else { return }
                    await controller.seek(to: position)
                }
                return .success
            }
        commandTargets.append((
            commandCenter.changePlaybackPositionCommand,
            positionTarget
        ))

        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.changePlaybackRateCommand.isEnabled = false
        commandCenter.likeCommand.isEnabled = false
        commandCenter.dislikeCommand.isEnabled = false
        commandCenter.bookmarkCommand.isEnabled = false

        updateRemoteCommandAvailability(
            hasItem: false,
            canSeek: false,
            status: .idle
        )
    }

    private func artwork(
        for item: PlaybackQueueItem
    ) -> MPMediaItemArtwork? {
        if cachedArtworkItemID == item.id {
            return cachedArtwork
        }

        cachedArtworkItemID = item.id

        #if os(iOS)
        guard let data = item.track.artworkData,
              let image = UIImage(data: data) else {
            cachedArtwork = nil
            return nil
        }
        #elseif os(macOS)
        guard let data = item.track.artworkData,
              let image = NSImage(data: data) else {
            cachedArtwork = nil
            return nil
        }
        #endif

        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        cachedArtwork = artwork
        return artwork
    }

    private func addTarget(
        to command: MPRemoteCommand,
        action: @escaping @MainActor () async -> Void
    ) {
        let target = command.addTarget { _ in
            Task { @MainActor in
                await action()
            }
            return .success
        }
        commandTargets.append((command, target))
    }

    private func updateRemoteCommandAvailability(
        hasItem: Bool,
        canSeek: Bool,
        status: PlaybackStatus
    ) {
        let commandCenter = MPRemoteCommandCenter.shared()
        let isLoading = status == .loading
        commandCenter.playCommand.isEnabled = hasItem
            && !status.isPlaying
            && !isLoading
        commandCenter.pauseCommand.isEnabled = status.isPlaying
        commandCenter.togglePlayPauseCommand.isEnabled = hasItem && !isLoading
        commandCenter.stopCommand.isEnabled = hasItem
        commandCenter.changePlaybackPositionCommand.isEnabled = hasItem
            && canSeek
    }

    #if os(macOS)
    private func macPlaybackState(
        for status: PlaybackStatus
    ) -> MPNowPlayingPlaybackState {
        switch status {
        case .playing:
            return .playing
        case .paused, .ready, .loading:
            return .paused
        case .idle, .stopped, .failed:
            return .stopped
        }
    }
    #endif
}
#endif
