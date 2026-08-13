//
//  LocalLibraryModels.swift
//  MusiCards
//

import Foundation
import SwiftData

@Model
final class LocalLibraryRootRecord {
    @Attribute(.unique) var id: String
    var displayName: String
    var bookmarkData: Data
    var lastScanDate: Date?
    var identifiedAlbumCount: Int?
    var totalAlbumCount: Int?

    init(
        id: String = UUID().uuidString,
        displayName: String,
        bookmarkData: Data,
        lastScanDate: Date? = nil,
        identifiedAlbumCount: Int? = nil,
        totalAlbumCount: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.lastScanDate = lastScanDate
        self.identifiedAlbumCount = identifiedAlbumCount
        self.totalAlbumCount = totalAlbumCount
    }
}

@Model
final class LocalAudioFileRecord {
    @Attribute(.unique) var id: String
    var rootID: String
    var relativePath: String
    var fileSize: Int64
    var modificationDate: Date

    var title: String
    var artist: String
    var albumTitle: String
    var releaseMBID: String?
    var recordingMBID: String?
    var releaseTrackMBID: String?

    var codec: String
    var bitDepth: Int?
    var sampleRate: Double
    var bitrate: Double?
    var channelCount: Int
    var duration: TimeInterval?

    init(rootID: String, scanned: ScannedAudioFile) {
        self.id = Self.makeID(rootID: rootID, relativePath: scanned.relativePath)
        self.rootID = rootID
        self.relativePath = scanned.relativePath
        self.fileSize = scanned.fileSize
        self.modificationDate = scanned.modificationDate
        self.title = scanned.title
        self.artist = scanned.artist
        self.albumTitle = scanned.albumTitle
        self.releaseMBID = scanned.releaseMBID
        self.recordingMBID = scanned.recordingMBID
        self.releaseTrackMBID = scanned.releaseTrackMBID
        self.codec = scanned.codec
        self.bitDepth = scanned.bitDepth
        self.sampleRate = scanned.sampleRate
        self.bitrate = scanned.bitrate
        self.channelCount = scanned.channelCount
        self.duration = scanned.duration
    }

    func update(from scanned: ScannedAudioFile) {
        relativePath = scanned.relativePath
        fileSize = scanned.fileSize
        modificationDate = scanned.modificationDate
        title = scanned.title
        artist = scanned.artist
        albumTitle = scanned.albumTitle
        releaseMBID = scanned.releaseMBID
        recordingMBID = scanned.recordingMBID
        releaseTrackMBID = scanned.releaseTrackMBID
        codec = scanned.codec
        bitDepth = scanned.bitDepth
        sampleRate = scanned.sampleRate
        bitrate = scanned.bitrate
        channelCount = scanned.channelCount
        duration = scanned.duration
    }

    static func makeID(rootID: String, relativePath: String) -> String {
        "\(rootID)::\(relativePath)"
    }
}

nonisolated struct LocalAudioFileSnapshot: Identifiable, Sendable {
    let id: String
    let rootID: String
    let relativePath: String
    let title: String
    let artist: String
    let albumTitle: String
    let releaseMBID: String?
    let recordingMBID: String?
    let releaseTrackMBID: String?
    let codec: String
    let bitDepth: Int?
    let sampleRate: Double
    let bitrate: Double?
    let channelCount: Int
    let duration: TimeInterval?

    init(_ record: LocalAudioFileRecord) {
        id = record.id
        rootID = record.rootID
        relativePath = record.relativePath
        title = record.title
        artist = record.artist
        albumTitle = record.albumTitle
        releaseMBID = record.releaseMBID
        recordingMBID = record.recordingMBID
        releaseTrackMBID = record.releaseTrackMBID
        codec = record.codec
        bitDepth = record.bitDepth
        sampleRate = record.sampleRate
        bitrate = record.bitrate
        channelCount = record.channelCount
        duration = record.duration
    }
}

nonisolated struct LocalLibrarySummary: Equatable, Sendable {
    var folderCount = 0
    var releaseCount = 0
    var trackCount = 0
    var identifiedAlbumCount = 0
    var totalAlbumCount: Int?
}
