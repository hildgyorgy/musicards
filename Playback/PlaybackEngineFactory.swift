//
//  PlaybackEngineFactory.swift
//  MusiCards
//

@MainActor
enum PlaybackEngineFactory {
    static func makeDefault() -> PlaybackEngine {
        #if os(macOS)
            MacSystemPlaybackEngine()
        #else
            PendingPlaybackEngine()
        #endif
    }
}

