//
//  Models.swift
//  MBViewer
//
//  Created by Hild György on 2026. 03. 06..
//

import Foundation

struct MBRelease: Decodable {
    let id: String
    let title: String
    let artistCredit: [MBArtistCredit]?
    let date: String?
    let country: String?
    let barcode: String?
    let disambiguation: String?
    let labelInfo: [MBLabelInfo]?
    let media: [MBMedium]?
    let releaseGroup: MBReleaseGroupRef?
    let relations: [MBRelation]?
    let annotation: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case artistCredit = "artist-credit"
        case date
        case country
        case barcode
        case disambiguation
        case labelInfo = "label-info"
        case media
        case releaseGroup = "release-group"
        case relations
        case annotation
    }
}
extension MBRelease {
    /// Recording MBIDs identify the musical recording, not a particular
    /// appearance of it on a release. Falling back to a recording match is
    /// therefore safe only when that recording occurs exactly once across
    /// every medium/layer of this release.
    func hasUniqueOccurrence(ofRecordingID recordingID: String?) -> Bool {
        guard let recordingID = recordingID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !recordingID.isEmpty else {
            return false
        }

        var occurrenceCount = 0
        for medium in media ?? [] {
            for track in medium.tracks ?? [] where
                track.recording?.id.caseInsensitiveCompare(recordingID)
                    == .orderedSame {
                occurrenceCount += 1
                if occurrenceCount > 1 { return false }
            }
        }
        return occurrenceCount == 1
    }

    var appleMusicURL: URL? {
        externalURL(containingAnyOf: [
            "music.apple.com",
            "itunes.apple.com"
        ])
    }

    var spotifyURL: URL? {
        externalURL(containingAnyOf: [
            "open.spotify.com"
        ])
    }

    var tidalURL: URL? {
        externalURL(containingAnyOf: [
            "tidal.com",
            "listen.tidal.com"
        ])
    }

    var qobuzURL: URL? {
        externalURL(containingAnyOf: [
            "qobuz.com",
            "open.qobuz.com"
        ])
    }

    var discogsURL: URL? {
        externalURL(containingAnyOf: [
            "discogs.com"
        ])
    }

    private func externalURL(containingAnyOf domainFragments: [String]) -> URL? {
        relations?
            .compactMap { $0.url?.resource }
            .first { resource in
                domainFragments.contains { fragment in
                    resource.localizedCaseInsensitiveContains(fragment)
                }
            }
            .flatMap(URL.init(string:))
    }
}

struct MBReleaseGroupRef: Decodable {
    let id: String
    let title: String?
}

struct MBReleaseSearchResponse: Decodable {
    let releases: [MBReleaseSearchResult]
}

struct MBReleaseSearchResult: Decodable, Identifiable {

    let id: String
    let title: String
    let date: String?
    let country: String?
    let disambiguation: String?
    let score: Int?

    let artistCredit: [MBArtistCredit]?
    let labelInfo: [MBLabelInfo]?
    let media: [MBMedium]?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case date
        case country
        case disambiguation
        case score
        case artistCredit = "artist-credit"
        case labelInfo = "label-info"
        case media
    }

    nonisolated init(
        id: String,
        title: String,
        date: String? = nil,
        country: String? = nil,
        disambiguation: String? = nil,
        score: Int? = nil,
        artistCredit: [MBArtistCredit]? = nil,
        labelInfo: [MBLabelInfo]? = nil,
        media: [MBMedium]? = nil
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.country = country
        self.disambiguation = disambiguation
        self.score = score
        self.artistCredit = artistCredit
        self.labelInfo = labelInfo
        self.media = media
    }
}

struct MBLabelInfo: Decodable {
    let catalogNumber: String?
    let label: MBLabel?

    enum CodingKeys: String, CodingKey {
        case catalogNumber = "catalog-number"
        case label
    }
}

struct MBLabel: Decodable {
    let name: String?
}

struct MBMedium: Decodable {
    let position: Int?
    let trackCount: Int?
    let format: String?
    let tracks: [MBTrack]?

    enum CodingKeys: String, CodingKey {
        case position
        case trackCount = "track-count"
        case format
        case tracks
    }
}

struct MBTrack: Decodable {
    let id: String?
    let position: Int?
    let title: String
    let length: Int?
    let recording: MBRecording?

    enum CodingKeys: String, CodingKey {
        case id
        case position
        case title
        case length
        case recording
    }

    init(
        id: String? = nil,
        position: Int? = nil,
        title: String,
        length: Int? = nil,
        recording: MBRecording? = nil
    ) {
        self.id = id
        self.position = position
        self.title = title
        self.length = length
        self.recording = recording
    }
}

struct MBRecording: Decodable {
    let id: String
    let disambiguation: String?
    let relations: [MBRelation]?

    enum CodingKeys: String, CodingKey {
        case id
        case disambiguation
        case relations
    }

    init(
        id: String,
        disambiguation: String? = nil,
        relations: [MBRelation]? = nil
    ) {
        self.id = id
        self.disambiguation = disambiguation
        self.relations = relations
    }
}

struct MBPlace: Decodable {
    let id: String?
    let name: String
}

struct MBRelation: Decodable {
    let type: String?
    let artist: MBArtist?
    let label: MBLabel?
    let attributes: [String]?
    let work: MBWorkReference?
    let begin: String?
    let end: String?
    let url: MBRelationURL?
    let place: MBPlace?

    init(
        type: String? = nil,
        artist: MBArtist? = nil,
        label: MBLabel? = nil,
        attributes: [String]? = nil,
        work: MBWorkReference? = nil,
        begin: String? = nil,
        end: String? = nil,
        url: MBRelationURL? = nil,
        place: MBPlace? = nil
    ) {
        self.type = type
        self.artist = artist
        self.label = label
        self.attributes = attributes
        self.work = work
        self.begin = begin
        self.end = end
        self.url = url
        self.place = place
    }
}

struct MBArtistCredit: Decodable {
    let name: String
    let artist: MBArtist?
    let joinPhrase: String?

    enum CodingKeys: String, CodingKey {
        case name
        case artist
        case joinPhrase = "join-phrase"
    }
}

struct MBArtist: Decodable {
    let id: String
    let name: String
    let disambiguation: String?

    init(id: String = "", name: String, disambiguation: String? = nil) {
        self.id = id
        self.name = name
        self.disambiguation = disambiguation
    }
}

struct MBArtistDetail: Decodable {
    let id: String
    let name: String
    let disambiguation: String?
    let country: String?
    let type: String?
    let lifeSpan: MBLifeSpan?
    let beginArea: MBAreaRef?
    let endArea: MBAreaRef?
    let relations: [MBRelation]?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case disambiguation
        case country
        case type
        case lifeSpan = "life-span"
        case beginArea = "begin-area"
        case endArea = "end-area"
        case relations
    }
}

struct MBArtistSearchResponse: Decodable {
    let artists: [MBArtistSearchResult]

    enum CodingKeys: String, CodingKey {
        case artists
    }
}

struct MBArtistSearchResult: Decodable, Identifiable {
    let id: String
    let name: String
    let lifeSpan: MBLifeSpan?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case lifeSpan = "life-span"
    }
}

struct MBRelationURL: Decodable {
    let resource: String?
}

struct MBLifeSpan: Decodable {
    let begin: String?
    let end: String?
    let ended: Bool?
}

struct MBAreaRef: Decodable {
    let name: String?
}

struct MBWorkReference: Decodable {
    let id: String
    let title: String?

    init(id: String, title: String? = nil) {
        self.id = id
        self.title = title
    }
}

struct MBWork: Decodable {
    let id: String
    let title: String
    let disambiguation: String?
    let relations: [MBRelation]?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case disambiguation
        case relations
    }

    init(
        id: String,
        title: String,
        disambiguation: String? = nil,
        relations: [MBRelation]? = nil
    ) {
        self.id = id
        self.title = title
        self.disambiguation = disambiguation
        self.relations = relations
    }
}

// MARK: - Recording search (used for track-title search via comma syntax)

struct MBRecordingSearchResponse: Decodable {
    let recordings: [MBRecordingSearchResult]
}

struct MBRecordingSearchResult: Decodable, Identifiable {
    let id: String
    let title: String
    let artistCredit: [MBArtistCredit]?
    let releases: [MBReleaseSearchResult]?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case artistCredit = "artist-credit"
        case releases
    }
}

struct MBReleaseGroupBrowseResponse: Decodable {
    let count: Int
    let releaseGroups: [MBReleaseGroupSummary]

    enum CodingKeys: String, CodingKey {
        case count = "release-group-count"
        case releaseGroups = "release-groups"
    }
}

struct MBReleaseGroupSummary: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let primaryType: String?
    let secondaryTypes: [String]?
    let firstReleaseDate: String?
    let disambiguation: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case primaryType = "primary-type"
        case secondaryTypes = "secondary-types"
        case firstReleaseDate = "first-release-date"
        case disambiguation
    }
}
