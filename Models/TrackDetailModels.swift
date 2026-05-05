//
//  TrackDetailModels.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 10..
//

import Foundation

struct TrackDetailData: Hashable {
    let recordingID: String
    let performers: [LinkedArtistGroup]
    let creators: [LinkedArtistGroup]
    let workHierarchy: [String]
    let technical: [TrackDetailGroup]
    let notes: [String]
}

struct LinkedArtist: Identifiable, Hashable {
    let id: String
    let name: String
}

struct LinkedArtistGroup: Hashable {
    let role: String
    let artists: [LinkedArtist]
}

struct TrackDetailGroup: Hashable {
    let role: String
    let names: [String]
}

enum RelationBucket {
    case creator
    case performer
    case technical
}

enum RelationClassifier {
    static func bucket(for relation: MBRelation) -> RelationBucket? {
        let type = (relation.type ?? "").lowercased()

        if creatorTypes.contains(type) {
            return .creator
        }

        if performerTypes.contains(type) {
            return .performer
        }

        if technicalTypes.contains(type) {
            return .technical
        }

        return nil
    }

    static func displayRole(for relation: MBRelation) -> String {
        let type = (relation.type ?? "").lowercased()

        if type == "instrument" || type == "vocal" {
            if let firstAttribute = relation.attributes?.first,
               !firstAttribute.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return firstAttribute
            }
            return type == "vocal" ? "vocals" : "performer"
        }

        if type == "recorded at" {
            return "recorded at"
        }

        return type
    }

    private static let creatorTypes: Set<String> = [
        "composer",
        "writer",
        "lyricist",
        "librettist",
        "revised by",
        "translator",
        "arranger",
        "orchestrator",
        "instrument arranger",
        "vocal arranger"
    ]

    private static let performerTypes: Set<String> = [
        "instrument",
        "vocal",
        "performing orchestra",
        "conductor",
        "chorus master"
    ]

    private static let technicalTypes: Set<String> = [
        "engineer",
        "producer",
        "recording",
        "mix",
        "mastering",
        "editing",
        "balance",
        "recorded at"
    ]
}
