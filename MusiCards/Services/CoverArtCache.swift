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

    private let cache = NSCache<NSString, PlatformImage>()
    private var inFlight: [String: Task<PlatformImage?, Never>] = [:]

    private init() {
        cache.countLimit = 160
        cache.totalCostLimit = 96 * 1_024 * 1_024
    }

    func image(for releaseID: String, size: CoverArtSize = .thumbnail) async -> PlatformImage? {
        let key = "\(releaseID)-\(size.urlSuffix)"

        if let cached = cache.object(forKey: key as NSString) {
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
            cache.setObject(
                result,
                forKey: key as NSString,
                cost: estimatedMemoryCost(of: result)
            )
        }

        return result
    }

    private func estimatedMemoryCost(of image: PlatformImage) -> Int {
        #if canImport(UIKit)
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
        #else
        return image.representations.reduce(0) { cost, representation in
            max(cost, representation.pixelsWide * representation.pixelsHigh * 4)
        }
        #endif
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
