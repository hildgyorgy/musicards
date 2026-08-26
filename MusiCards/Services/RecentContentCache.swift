//
//  RecentContentCache.swift
//  MusiCards
//

import Foundation

struct RecentReleaseSnapshot: Codable, @unchecked Sendable {
    let savedAt: Date
    let release: MBRelease
    let coverData: Data?
}

struct RecentArtistSnapshot: Codable, @unchecked Sendable {
    let savedAt: Date
    let artist: MBArtistDetail?
    let name: String
    let lifeSpan: String?
    let releaseGroups: [MBReleaseGroupSummary]
    let hasMoreReleaseGroups: Bool
    let wikipediaTitle: String?
    let wikipediaExtract: String?
    let wikipediaLanguageCode: String?
    let wikipediaPageURL: URL?

    init(
        savedAt: Date,
        artist: MBArtistDetail?,
        name: String,
        lifeSpan: String?,
        releaseGroups: [MBReleaseGroupSummary],
        hasMoreReleaseGroups: Bool,
        wikipediaTitle: String?,
        wikipediaExtract: String?,
        wikipediaLanguageCode: String? = nil,
        wikipediaPageURL: URL? = nil
    ) {
        self.savedAt = savedAt
        self.artist = artist
        self.name = name
        self.lifeSpan = lifeSpan
        self.releaseGroups = releaseGroups
        self.hasMoreReleaseGroups = hasMoreReleaseGroups
        self.wikipediaTitle = wikipediaTitle
        self.wikipediaExtract = wikipediaExtract
        self.wikipediaLanguageCode = wikipediaLanguageCode
        self.wikipediaPageURL = wikipediaPageURL
    }
}

actor RecentContentCache {
    static let shared = RecentContentCache()

    private struct Store: Codable {
        var version = 1
        var releases: [String: RecentReleaseSnapshot] = [:]
        var artists: [String: RecentArtistSnapshot] = [:]
    }

    private let fileURL: URL
    private var store = Store()
    private var hasLoaded = false

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let cachesURL = FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.fileURL = cachesURL
                .appendingPathComponent("MusiCards", isDirectory: true)
                .appendingPathComponent("RecentContent-v1.json")
        }
    }

    func release(for id: String) -> RecentReleaseSnapshot? {
        loadIfNeeded()
        return store.releases[id]
    }

    func artist(for id: String) -> RecentArtistSnapshot? {
        loadIfNeeded()
        return store.artists[id]
    }

    func save(_ snapshot: RecentReleaseSnapshot, for id: String) {
        loadIfNeeded()
        store.releases[id] = snapshot
        persist()
    }

    func save(_ snapshot: RecentArtistSnapshot, for id: String) {
        loadIfNeeded()
        store.artists[id] = snapshot
        persist()
    }

    func retain(artistIDs: Set<String>, releaseIDs: Set<String>) {
        loadIfNeeded()
        let oldArtistCount = store.artists.count
        let oldReleaseCount = store.releases.count
        store.artists = store.artists.filter { artistIDs.contains($0.key) }
        store.releases = store.releases.filter { releaseIDs.contains($0.key) }
        if store.artists.count != oldArtistCount
            || store.releases.count != oldReleaseCount {
            persist()
        }
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Store.self, from: data),
              decoded.version == 1 else {
            return
        }
        store = decoded
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(store)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // The cache is best-effort; a later network load still supplies data.
        }
    }
}
