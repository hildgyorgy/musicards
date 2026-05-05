//
//  CoverArtCache.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 11..
//

import UIKit

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

    private var cache: [String: UIImage] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {}

    func image(for releaseID: String, size: CoverArtSize = .thumbnail) async -> UIImage? {
        let key = "\(releaseID)-\(size.urlSuffix)"

        if let cached = cache[key] {
            return cached
        }

        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<UIImage?, Never> {
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

    private func fetchCover(releaseID: String, size: CoverArtSize) async -> UIImage? {
        guard let url = URL(
            string: "https://coverartarchive.org/release/\(releaseID)/\(size.urlSuffix)"
        ) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                return nil
            }

            return UIImage(data: data)
        } catch {
            return nil
        }
    }
}
