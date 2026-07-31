//
//  PlaybackEngine.swift
//  MusiCards
//

import Foundation

enum PlaybackEngineEvent: Equatable {
    case prepared(duration: TimeInterval?)
    case started
    case paused
    case positionChanged(TimeInterval)
    case finished
    case failed(PlaybackFailure)
}

/// Main-actor facade for a platform audio implementation.
/// A Core Audio or iOS implementation may keep its realtime work off the main
/// actor, but reports user-facing state through `eventHandler`.
@MainActor
protocol PlaybackEngine: AnyObject {
    var eventHandler: ((PlaybackEngineEvent) -> Void)? { get set }

    func prepare(_ item: PlaybackQueueItem) async throws
    func play() async throws
    func pause() async
    func stop() async
    func seek(to position: TimeInterval) async throws
}

enum PendingPlaybackEngineError: LocalizedError {
    case sourceLoadingNotImplemented

    var errorDescription: String? {
        switch self {
        case .sourceLoadingNotImplemented:
            return "Local audio loading is not connected yet"
        }
    }
}

/// Safe first-stage engine. It makes the architectural boundary real without
/// pretending to play sound before a native audio implementation is attached.
@MainActor
final class PendingPlaybackEngine: PlaybackEngine {
    var eventHandler: ((PlaybackEngineEvent) -> Void)?

    func prepare(_ item: PlaybackQueueItem) async throws {
        throw PendingPlaybackEngineError.sourceLoadingNotImplemented
    }

    func play() async throws {
        throw PendingPlaybackEngineError.sourceLoadingNotImplemented
    }

    func pause() async {}
    func stop() async {}

    func seek(to position: TimeInterval) async throws {
        throw PendingPlaybackEngineError.sourceLoadingNotImplemented
    }
}

