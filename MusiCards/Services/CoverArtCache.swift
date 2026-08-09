//
//  CoverArtCache.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 11..
//


#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

enum CoverArtSize: Sendable {
    case thumbnail
    case full

    nonisolated var urlSuffix: String {
        switch self {
        case .thumbnail: return "front-250"
        case .full:      return "front-500"
        }
    }
}

actor CoverArtCache {
    static let shared = CoverArtCache()

    private var cache: [String: PlatformImage] = [:]
    private var inFlight: [String: Task<PlatformImage?, Never>] = [:]

    private init() {}

    func image(for releaseID: String, size: CoverArtSize = .thumbnail) async -> PlatformImage? {
        let key = "\(releaseID)-\(size.urlSuffix)"

        if let cached = cache[key] {
            return cached
        }

        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<PlatformImage?, Never> {
            await fetchCover(releaseID: releaseID, size: size)
        }

        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)

        if let result {
            cache[key] = result
        }

        return result
    }

    private func fetchCover(releaseID: String, size: CoverArtSize) async -> PlatformImage? {
        guard let url = URL(
            string: "https://coverartarchive.org/release/\(releaseID)/\(size.urlSuffix)"
        ) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                return nil
            }

            #if canImport(UIKit)
            return UIImage(data: data)
            #else
            return NSImage(data: data)
            #endif
        } catch {
            return nil
        }
    }
}
