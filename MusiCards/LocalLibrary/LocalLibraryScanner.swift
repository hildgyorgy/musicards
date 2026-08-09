//
//  LocalLibraryScanner.swift
//  MusiCards
//

import AudioToolbox
import AVFoundation
import Foundation

nonisolated struct LocalAudioFileCandidate: Sendable {
    let url: URL
    let relativePath: String
    let fileSize: Int64
    let modificationDate: Date
}

nonisolated struct ScannedAudioFile: Sendable {
    let relativePath: String
    let fileSize: Int64
    let modificationDate: Date
    let title: String
    let artist: String
    let albumTitle: String
    let releaseMBID: String?
    let recordingMBID: String?
    let releaseTrackMBID: String?
    let releaseYear: String?
    let country: String?
    let label: String?
    let mediaFormat: String?
    let codec: String
    let bitDepth: Int?
    let sampleRate: Double
    let bitrate: Double?
    let channelCount: Int
    let duration: TimeInterval?
}

enum LocalLibraryScanner {
    nonisolated private static let supportedExtensions: Set<String> = [
        "aac", "flac", "m4a"
    ]

    nonisolated static func enumerateAudioFiles(
        in rootURL: URL
    ) throws -> [LocalAudioFileCandidate] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw NativePlaybackEngineError("Could not read the selected music folder")
        }

        var candidates: [LocalAudioFileCandidate] = []
        while let url = enumerator.nextObject() as? URL {
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
                continue
            }
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }

            let relativePath = relativePath(from: rootURL, to: url)
            candidates.append(
                LocalAudioFileCandidate(
                    url: url,
                    relativePath: relativePath,
                    fileSize: Int64(values.fileSize ?? 0),
                    modificationDate: values.contentModificationDate ?? .distantPast
                )
            )
        }
        return candidates.sorted { $0.relativePath < $1.relativePath }
    }

    nonisolated static func readMetadata(
        from candidate: LocalAudioFileCandidate,
        timeout: Duration = .seconds(45)
    ) async throws -> ScannedAudioFile {
        try await withThrowingTaskGroup(of: ScannedAudioFile.self) { group in
            group.addTask {
                #if os(macOS)
                do {
                    return try FastAudioMetadataReader.read(candidate)
                } catch {
                    // Raw AAC and unusual containers retain the proven
                    // AVFoundation path instead of failing the whole index.
                    return try await readMetadataWithoutTimeout(from: candidate)
                }
                #else
                try await readMetadataWithoutTimeout(from: candidate)
                #endif
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw NativePlaybackEngineError(
                    "Timed out while reading \(candidate.url.lastPathComponent)"
                )
            }

            guard let result = try await group.next() else {
                throw NativePlaybackEngineError("Could not read audio metadata")
            }
            group.cancelAll()
            return result
        }
    }

    private nonisolated static func readMetadataWithoutTimeout(
        from candidate: LocalAudioFileCandidate
    ) async throws -> ScannedAudioFile {
        let asset = AVURLAsset(url: candidate.url)
        return try await withTaskCancellationHandler {
            async let metadataTask = asset.load(.metadata)
            async let durationTask = asset.load(.duration)
            async let tracksTask = asset.loadTracks(withMediaType: .audio)

            let metadata = try await metadataTask
            let duration = try? await durationTask
            let audioTracks = try await tracksTask
            
            guard let audioTrack = audioTracks.first else {
                throw NativePlaybackEngineError("The indexed file contains no audio track")
            }

            async let descriptionsTask = audioTrack.load(.formatDescriptions)
            async let bitrateTask = audioTrack.load(.estimatedDataRate)
            let descriptions = try await descriptionsTask
            let estimatedBitrate = try? await bitrateTask
            let format = technicalFormat(
                from: descriptions.first,
                url: candidate.url,
                estimatedBitrate: estimatedBitrate
            )
            let tags = await textTags(from: metadata)

            let fallbackTitle = candidate.url.deletingPathExtension().lastPathComponent
            let releaseDate = firstValue(in: tags, matching: ["day", "date"])
            return ScannedAudioFile(
                relativePath: candidate.relativePath,
                fileSize: candidate.fileSize,
                modificationDate: candidate.modificationDate,
                title: firstValue(in: tags, matching: ["nam", "title"]) ?? fallbackTitle,
                artist: firstValue(in: tags, matching: ["aart", "albumartist", "art", "artist"]) ?? "",
                albumTitle: firstValue(in: tags, matching: ["alb", "album"]) ?? "",
                releaseMBID: musicBrainzValue(in: tags, exactName: "musicbrainzalbumid"),
                recordingMBID: musicBrainzValue(in: tags, exactName: "musicbrainztrackid"),
                releaseTrackMBID: musicBrainzValue(in: tags, exactName: "musicbrainzreleasetrackid"),
                releaseYear: releaseDate.map { String($0.prefix(4)) },
                country: firstValue(
                    in: tags,
                    matching: ["musicbrainzalbumreleasecountry", "releasecountry"]
                ),
                label: firstValue(in: tags, matching: ["organization", "label"]),
                mediaFormat: firstValue(in: tags, matching: ["media"]),
                codec: format.codec,
                bitDepth: format.bitDepth,
                sampleRate: format.sampleRate,
                bitrate: format.bitrate,
                channelCount: format.channelCount,
                duration: duration.flatMap { time in
                    let seconds = CMTimeGetSeconds(time)
                    return seconds.isFinite && seconds >= 0 ? seconds : nil
                }
            )
        } onCancel: {
            asset.cancelLoading()
        }
    }

    private nonisolated static func relativePath(
        from rootURL: URL,
        to fileURL: URL
    ) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else {
            return fileURL.lastPathComponent
        }
        return String(filePath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private nonisolated static func textTags(
        from metadata: [AVMetadataItem]
    ) async -> [String: String] {
        var result: [String: String] = [:]
        for item in metadata {
            guard let value = try? await item.load(.stringValue),
                  !value.isEmpty else {
                continue
            }
            let candidates = [
                item.identifier?.rawValue,
                (item.key as? String)
            ].compactMap { $0 }

            for key in candidates {
                result[normalizedTagName(key)] = value
            }
        }
        return result
    }

    private nonisolated static func normalizedTagName(_ value: String) -> String {
        let decoded = value.removingPercentEncoding ?? value
        return decoded
            .lowercased()
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }

    private nonisolated static func firstValue(
        in tags: [String: String],
        matching suffixes: [String]
    ) -> String? {
        for suffix in suffixes {
            if let match = tags.first(where: { $0.key.hasSuffix(suffix) })?.value {
                return match
            }
        }
        return nil
    }

    private nonisolated static func musicBrainzValue(
        in tags: [String: String],
        exactName: String
    ) -> String? {
        tags.first { key, _ in
            key.hasSuffix(exactName)
                && !key.hasSuffix("release\(exactName)")
        }?.value
    }

    private nonisolated static func technicalFormat(
        from description: CMFormatDescription?,
        url: URL,
        estimatedBitrate: Float?
    ) -> (
        codec: String,
        bitDepth: Int?,
        sampleRate: Double,
        bitrate: Double?,
        channelCount: Int
    ) {
        guard let description,
              let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else {
            return (
                url.pathExtension.uppercased(),
                sourceBitDepth(at: url),
                0,
                estimatedBitrate.map(Double.init),
                0
            )
        }

        let stream = pointer.pointee
        return (
            codecName(formatID: stream.mFormatID, fallbackURL: url),
            sourceBitDepth(at: url),
            stream.mSampleRate,
            estimatedBitrate.map(Double.init),
            Int(stream.mChannelsPerFrame)
        )
    }

    private nonisolated static func sourceBitDepth(at url: URL) -> Int? {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr,
              let file else {
            return nil
        }
        defer { AudioFileClose(file) }

        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioFileGetProperty(
            file,
            kAudioFilePropertySourceBitDepth,
            &size,
            &value
        ) == noErr,
        value > 0 else {
            return nil
        }
        return Int(value)
    }

    private nonisolated static func codecName(
        formatID: AudioFormatID,
        fallbackURL: URL
    ) -> String {
        switch formatID {
        case kAudioFormatAppleLossless:
            return "ALAC"
        case kAudioFormatFLAC:
            return "FLAC"
        case kAudioFormatMPEG4AAC,
             kAudioFormatMPEG4AAC_HE,
             kAudioFormatMPEG4AAC_HE_V2:
            return "AAC"
        default:
            return fallbackURL.pathExtension.uppercased()
        }
    }
}
