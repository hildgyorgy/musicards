//
//  FastAudioMetadataReader.swift
//  MusiCards
//

import Foundation

/// Reads only container headers and textual tags. Audio payloads and embedded
/// artwork are skipped with seeks, so indexing never decodes a track.
nonisolated enum FastAudioMetadataReader {
    static func read(_ candidate: LocalAudioFileCandidate) throws -> ScannedAudioFile {
        switch candidate.url.pathExtension.lowercased() {
        case "flac":
            return try readFLAC(candidate)
        case "m4a":
            return try readM4A(candidate)
        default:
            throw NativePlaybackEngineError(
                "The fast metadata reader does not support \(candidate.url.pathExtension)."
            )
        }
    }

    // MARK: - Shared metadata

    private struct ParsedMetadata {
        var tags: [String: [String]] = [:]
        var codec: String
        var bitDepth: Int?
        var sampleRate: Double = 0
        var bitrate: Double?
        var channels = 0
        var duration: TimeInterval?
    }

    private static func scannedFile(
        candidate: LocalAudioFileCandidate,
        parsed: ParsedMetadata
    ) -> ScannedAudioFile {
        let tags = parsed.tags
        let fallbackTitle = candidate.url.deletingPathExtension().lastPathComponent
        let date = first(tags, "date", "©day")
        return ScannedAudioFile(
            relativePath: candidate.relativePath,
            fileSize: candidate.fileSize,
            modificationDate: candidate.modificationDate,
            title: first(tags, "title", "©nam") ?? fallbackTitle,
            artist: first(tags, "albumartist", "aart", "artist", "©art") ?? "",
            albumTitle: first(tags, "album", "©alb") ?? "",
            releaseMBID: first(
                tags,
                "musicbrainz_albumid",
                "musicbrainz album id"
            ),
            recordingMBID: first(
                tags,
                "musicbrainz_trackid",
                "musicbrainz track id"
            ),
            releaseTrackMBID: first(
                tags,
                "musicbrainz_releasetrackid",
                "musicbrainz release track id"
            ),
            releaseYear: date.map { String($0.prefix(4)) },
            country: first(
                tags,
                "releasecountry",
                "musicbrainz album release country"
            ),
            label: first(tags, "label", "organization"),
            mediaFormat: first(tags, "media"),
            codec: parsed.codec,
            bitDepth: parsed.bitDepth,
            sampleRate: parsed.sampleRate,
            bitrate: parsed.bitrate,
            channelCount: parsed.channels,
            duration: parsed.duration
        )
    }

    private static func first(
        _ tags: [String: [String]],
        _ names: String...
    ) -> String? {
        for name in names {
            if let value = tags[name.lowercased()]?.first, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func appendTag(
        name: String,
        value: String,
        to tags: inout [String: [String]]
    ) {
        guard !value.isEmpty else { return }
        tags[name.lowercased(), default: []].append(value)
    }

    // MARK: - FLAC

    private static func readFLAC(
        _ candidate: LocalAudioFileCandidate
    ) throws -> ScannedAudioFile {
        let reader = try BinaryReader(url: candidate.url)
        guard try reader.read(count: 4) == Data("fLaC".utf8) else {
            throw NativePlaybackEngineError("Invalid FLAC header")
        }

        var parsed = ParsedMetadata(codec: "FLAC")
        var reachedLastBlock = false
        while !reachedLastBlock {
            let header = try reader.read(count: 4)
            reachedLastBlock = (header[0] & 0x80) != 0
            let blockType = header[0] & 0x7f
            let blockLength = Int(header.uint24BE(at: 1))
            let blockEnd = reader.offset + UInt64(blockLength)

            switch blockType {
            case 0:
                let streamInfo = try reader.read(count: blockLength)
                if streamInfo.count >= 18 {
                    let packed = streamInfo.uint64BE(at: 10)
                    let sampleRate = Double((packed >> 44) & 0xfffff)
                    let channels = Int((packed >> 41) & 0x7) + 1
                    let bitDepth = Int((packed >> 36) & 0x1f) + 1
                    let totalSamples = packed & 0xfffffffff
                    parsed.sampleRate = sampleRate
                    parsed.channels = channels
                    parsed.bitDepth = bitDepth
                    if sampleRate > 0, totalSamples > 0 {
                        let duration = Double(totalSamples) / sampleRate
                        parsed.duration = duration
                        parsed.bitrate = Double(candidate.fileSize * 8) / duration
                    }
                }
            case 4:
                let vendorLength = Int(try reader.readUInt32LE())
                try reader.skip(UInt64(vendorLength))
                let commentCount = Int(try reader.readUInt32LE())
                for _ in 0..<commentCount {
                    let length = Int(try reader.readUInt32LE())
                    let data = try reader.read(count: length)
                    guard let comment = String(data: data, encoding: .utf8),
                          let separator = comment.firstIndex(of: "=") else {
                        continue
                    }
                    appendTag(
                        name: String(comment[..<separator]),
                        value: String(comment[comment.index(after: separator)...]),
                        to: &parsed.tags
                    )
                }
            default:
                // Includes PICTURE (6): never materialize its payload.
                try reader.seek(to: blockEnd)
            }
            try reader.seek(to: blockEnd)
        }
        return scannedFile(candidate: candidate, parsed: parsed)
    }

    // MARK: - MP4 / M4A

    private struct MP4Box {
        let type: Data
        let payloadStart: UInt64
        let end: UInt64
    }

    private static let moov = Data("moov".utf8)
    private static let udta = Data("udta".utf8)
    private static let meta = Data("meta".utf8)
    private static let ilst = Data("ilst".utf8)
    private static let trak = Data("trak".utf8)
    private static let mdia = Data("mdia".utf8)
    private static let hdlr = Data("hdlr".utf8)
    private static let minf = Data("minf".utf8)
    private static let stbl = Data("stbl".utf8)
    private static let stsd = Data("stsd".utf8)
    private static let alac = Data("alac".utf8)
    private static let mp4a = Data("mp4a".utf8)
    private static let btrt = Data("btrt".utf8)
    private static let freeform = Data("----".utf8)
    private static let name = Data("name".utf8)
    private static let dataAtom = Data("data".utf8)
    private static let cover = Data("covr".utf8)
    private static let copyrightName = Data([0xa9, 0x6e, 0x61, 0x6d])
    private static let copyrightAlbum = Data([0xa9, 0x61, 0x6c, 0x62])
    private static let albumArtist = Data("aART".utf8)
    private static let copyrightArtist = Data([0xa9, 0x41, 0x52, 0x54])
    private static let copyrightDay = Data([0xa9, 0x64, 0x61, 0x79])

    private static func readM4A(
        _ candidate: LocalAudioFileCandidate
    ) throws -> ScannedAudioFile {
        let reader = try BinaryReader(url: candidate.url)
        guard let moovBox = try childBox(
            reader: reader,
            start: 0,
            end: reader.fileSize,
            type: moov
        ) else {
            throw NativePlaybackEngineError("M4A file has no moov atom")
        }

        var parsed = ParsedMetadata(codec: "M4A")
        try readM4ATechnicalMetadata(
            reader: reader,
            moovBox: moovBox,
            parsed: &parsed
        )

        if let ilstBox = try findILST(
            reader: reader,
            start: moovBox.payloadStart,
            end: moovBox.end,
            containerType: moov
        ) {
            try readILST(reader: reader, box: ilstBox, tags: &parsed.tags)
        }
        return scannedFile(candidate: candidate, parsed: parsed)
    }

    private static func readM4ATechnicalMetadata(
        reader: BinaryReader,
        moovBox: MP4Box,
        parsed: inout ParsedMetadata
    ) throws {
        for trackBox in try boxes(
            reader: reader,
            start: moovBox.payloadStart,
            end: moovBox.end
        ) where trackBox.type == trak {
            guard let mediaBox = try childBox(
                reader: reader,
                start: trackBox.payloadStart,
                end: trackBox.end,
                type: mdia
            ), let handlerBox = try childBox(
                reader: reader,
                start: mediaBox.payloadStart,
                end: mediaBox.end,
                type: hdlr
            ) else { continue }

            try reader.seek(to: handlerBox.payloadStart)
            let handler = try reader.read(count: min(12, Int(handlerBox.end - handlerBox.payloadStart)))
            guard handler.count >= 12,
                  handler.subdata(in: 8..<12) == Data("soun".utf8),
                  let mediaInfo = try childBox(
                    reader: reader,
                    start: mediaBox.payloadStart,
                    end: mediaBox.end,
                    type: minf
                  ), let sampleTable = try childBox(
                    reader: reader,
                    start: mediaInfo.payloadStart,
                    end: mediaInfo.end,
                    type: stbl
                  ), let sampleDescription = try childBox(
                    reader: reader,
                    start: sampleTable.payloadStart,
                    end: sampleTable.end,
                    type: stsd
                  ) else { continue }

            let entriesStart = sampleDescription.payloadStart + 8
            guard let sampleEntry = try boxes(
                reader: reader,
                start: entriesStart,
                end: sampleDescription.end
            ).first else { continue }

            parsed.codec = sampleEntry.type == alac
                ? "ALAC"
                : sampleEntry.type == mp4a ? "AAC" : fourCC(sampleEntry.type)
            try reader.seek(to: sampleEntry.payloadStart)
            let header = try reader.read(
                count: min(28, Int(sampleEntry.end - sampleEntry.payloadStart))
            )
            if header.count >= 28 {
                parsed.channels = Int(header.uint16BE(at: 16))
                parsed.bitDepth = Int(header.uint16BE(at: 18))
                parsed.sampleRate = Double(header.uint32BE(at: 24) >> 16)
            }

            let childStart = sampleEntry.payloadStart + 28
            if sampleEntry.type == alac,
               let configBox = try childBox(
                reader: reader,
                start: childStart,
                end: sampleEntry.end,
                type: alac
               ) {
                try reader.seek(to: configBox.payloadStart)
                let config = try reader.read(
                    count: min(28, Int(configBox.end - configBox.payloadStart))
                )
                if config.count >= 28, config[8] == 0 {
                    parsed.bitDepth = Int(config[9])
                    parsed.channels = Int(config[13])
                    parsed.bitrate = Double(config.uint32BE(at: 20))
                    parsed.sampleRate = Double(config.uint32BE(at: 24))
                }
            } else if sampleEntry.type == mp4a,
                      let bitrateBox = try childBox(
                        reader: reader,
                        start: childStart,
                        end: sampleEntry.end,
                        type: btrt
                      ) {
                try reader.seek(to: bitrateBox.payloadStart)
                let bitrateData = try reader.read(
                    count: min(12, Int(bitrateBox.end - bitrateBox.payloadStart))
                )
                if bitrateData.count >= 12 {
                    parsed.bitrate = Double(bitrateData.uint32BE(at: 8))
                }
            }
            return
        }
    }

    private static func findILST(
        reader: BinaryReader,
        start: UInt64,
        end: UInt64,
        containerType: Data
    ) throws -> MP4Box? {
        let childStart = containerType == meta ? start + 4 : start
        for box in try boxes(reader: reader, start: childStart, end: end) {
            if box.type == ilst { return box }
            if box.type == moov || box.type == udta || box.type == meta,
               let found = try findILST(
                reader: reader,
                start: box.payloadStart,
                end: box.end,
                containerType: box.type
               ) {
                return found
            }
        }
        return nil
    }

    private static func readILST(
        reader: BinaryReader,
        box: MP4Box,
        tags: inout [String: [String]]
    ) throws {
        let textAtoms: [Data: String] = [
            copyrightName: "©nam",
            copyrightAlbum: "©alb",
            albumArtist: "aart",
            copyrightArtist: "©art",
            copyrightDay: "©day"
        ]

        for item in try boxes(reader: reader, start: box.payloadStart, end: box.end) {
            if item.type == cover { continue }
            if let tagName = textAtoms[item.type],
               let payload = try childPayload(
                reader: reader,
                start: item.payloadStart,
                end: item.end,
                type: dataAtom
               ), let value = decodeMP4Data(payload) {
                appendTag(name: tagName, value: value, to: &tags)
                continue
            }
            guard item.type == freeform,
                  let namePayload = try childPayload(
                    reader: reader,
                    start: item.payloadStart,
                    end: item.end,
                    type: name
                  ), namePayload.count >= 4,
                  let dataPayload = try childPayload(
                    reader: reader,
                    start: item.payloadStart,
                    end: item.end,
                    type: dataAtom
                  ), let tagName = String(
                    data: namePayload.dropFirst(4),
                    encoding: .utf8
                  )?.trimmingCharacters(in: .controlCharacters),
                  let value = decodeMP4Data(dataPayload) else { continue }
            appendTag(name: tagName, value: value, to: &tags)
        }
    }

    private static func decodeMP4Data(_ payload: Data) -> String? {
        guard payload.count >= 8 else { return nil }
        let value = payload.dropFirst(8)
        return (String(data: value, encoding: .utf8)
            ?? String(data: value, encoding: .utf16))?
            .trimmingCharacters(in: .controlCharacters)
    }

    private static func childPayload(
        reader: BinaryReader,
        start: UInt64,
        end: UInt64,
        type: Data
    ) throws -> Data? {
        guard let box = try childBox(
            reader: reader,
            start: start,
            end: end,
            type: type
        ) else { return nil }
        try reader.seek(to: box.payloadStart)
        return try reader.read(count: Int(box.end - box.payloadStart))
    }

    private static func childBox(
        reader: BinaryReader,
        start: UInt64,
        end: UInt64,
        type: Data
    ) throws -> MP4Box? {
        try boxes(reader: reader, start: start, end: end).first { $0.type == type }
    }

    private static func boxes(
        reader: BinaryReader,
        start: UInt64,
        end: UInt64
    ) throws -> [MP4Box] {
        guard start <= end, end <= reader.fileSize else {
            throw NativePlaybackEngineError("Invalid MP4 container range")
        }
        var result: [MP4Box] = []
        var position = start
        while position + 8 <= end {
            try reader.seek(to: position)
            let header = try reader.read(count: 8)
            let size32 = UInt64(header.uint32BE(at: 0))
            let type = header.subdata(in: 4..<8)
            let headerSize: UInt64
            let boxSize: UInt64
            if size32 == 1 {
                headerSize = 16
                boxSize = try reader.readUInt64BE()
            } else if size32 == 0 {
                headerSize = 8
                boxSize = end - position
            } else {
                headerSize = 8
                boxSize = size32
            }
            guard boxSize >= headerSize, boxSize <= end - position else {
                throw NativePlaybackEngineError("Invalid MP4 box structure")
            }
            let boxEnd = position + boxSize
            result.append(
                MP4Box(
                    type: type,
                    payloadStart: position + headerSize,
                    end: boxEnd
                )
            )
            position = boxEnd
        }
        return result
    }

    private static func fourCC(_ data: Data) -> String {
        String(data: data, encoding: .isoLatin1)?.uppercased() ?? "M4A"
    }
}

private nonisolated final class BinaryReader {
    let fileSize: UInt64
    private let handle: FileHandle
    private(set) var offset: UInt64 = 0

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
    }

    deinit {
        try? handle.close()
    }

    func seek(to offset: UInt64) throws {
        guard offset <= fileSize else {
            throw NativePlaybackEngineError("Unexpected end of audio file")
        }
        try handle.seek(toOffset: offset)
        self.offset = offset
    }

    func skip(_ count: UInt64) throws {
        try seek(to: offset + count)
    }

    func read(count: Int) throws -> Data {
        guard count >= 0,
              UInt64(count) <= fileSize - offset,
              let data = try handle.read(upToCount: count),
              data.count == count else {
            throw NativePlaybackEngineError("Unexpected end of audio file")
        }
        offset += UInt64(count)
        return data
    }

    func readUInt32LE() throws -> UInt32 {
        try read(count: 4).uint32LE(at: 0)
    }

    func readUInt64BE() throws -> UInt64 {
        try read(count: 8).uint64BE(at: 0)
    }
}

private nonisolated extension Data {
    func uint16BE(at index: Int) -> UInt16 {
        (UInt16(self[index]) << 8) | UInt16(self[index + 1])
    }

    func uint24BE(at index: Int) -> UInt32 {
        (UInt32(self[index]) << 16)
            | (UInt32(self[index + 1]) << 8)
            | UInt32(self[index + 2])
    }

    func uint32BE(at index: Int) -> UInt32 {
        (UInt32(self[index]) << 24)
            | (UInt32(self[index + 1]) << 16)
            | (UInt32(self[index + 2]) << 8)
            | UInt32(self[index + 3])
    }

    func uint32LE(at index: Int) -> UInt32 {
        UInt32(self[index])
            | (UInt32(self[index + 1]) << 8)
            | (UInt32(self[index + 2]) << 16)
            | (UInt32(self[index + 3]) << 24)
    }

    func uint64BE(at index: Int) -> UInt64 {
        var value: UInt64 = 0
        for byte in self[index..<(index + 8)] {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }
}
