//
//  PlaybackEngineFactory.swift
//  MusiCards
//

@MainActor
enum PlaybackEngineFactory {
    static func makeDefault() -> PlaybackEngine {
        #if os(macOS)
            MacSystemPlaybackEngine()
        #elseif os(iOS)
            IOSSystemPlaybackEngine()
        #else
            PendingPlaybackEngine()
        #endif
    }
}
