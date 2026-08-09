//
//  LocalAudioMetadataLoader.swift
//  MusiCards
//

import AVFoundation
import Foundation

nonisolated enum LocalAudioMetadataLoader {
    static func artworkData(from url: URL) async -> Data? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let asset = AVURLAsset(url: url)
            let metadata = try await asset.load(.commonMetadata)
            let artworkItems = AVMetadataItem.metadataItems(
                from: metadata,
                filteredByIdentifier: .commonIdentifierArtwork
            )
            guard let artworkItem = artworkItems.first else { return nil }
            return try await artworkItem.load(.dataValue)
        } catch {
            return nil
        }
    }
}
