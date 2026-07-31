//
//  PlaybackModels.swift
//  MusiCards
//

import Foundation

/// MusicBrainz-facing identity and display metadata for one playable track.
/// The audio file remains a separate value so viewer data and local files do
/// not become the same source of truth.
struct PlaybackTrack: Identifiable, Equatable {
    let id: String
    let recordingID: String?
    let releaseID: String?
    let title: String
    let artist: String
    let albumTitle: String
    let duration: TimeInterval?
}

/// A concrete asset the playback engine can open.
enum PlaybackSource: Equatable {
    case localFile(URL)
}

/// A queue entry deliberately couples metadata with one playable asset.
struct PlaybackQueueItem: Identifiable, Equatable {
    let id: String
    let track: PlaybackTrack
    let source: PlaybackSource

    init(
        id: String? = nil,
        track: PlaybackTrack,
        source: PlaybackSource
    ) {
        self.id = id ?? track.id
        self.track = track
        self.source = source
    }
}

struct PlaybackFailure: Error, Equatable, LocalizedError {
    let message: String

    init(message: String) {
        self.message = message
    }

    init(_ error: Error) {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            message = description
        } else {
            message = error.localizedDescription
        }
    }

    var errorDescription: String? { message }
}

enum PlaybackStatus: Equatable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case stopped
    case failed(PlaybackFailure)

    var isPlaying: Bool {
        self == .playing
    }
}

