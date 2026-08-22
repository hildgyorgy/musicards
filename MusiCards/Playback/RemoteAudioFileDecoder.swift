#if os(macOS) || os(iOS)
import AudioToolbox
import Foundation
#if DEBUG
import OSLog
#endif

nonisolated enum RemoteAudioFileDecoder {
    static func decode(
        asset: RemotePlaybackAsset,
        byteSource: HTTPRandomAccessByteSource
    ) throws -> DecodedPCM {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let callbackContext = ProductionRemoteAudioCallbackContext(
            source: byteSource
        )
        var audioFile: AudioFileID?
        let openStatus = AudioFileOpenWithCallbacks(
            Unmanaged.passUnretained(callbackContext).toOpaque(),
            productionRemoteAudioRead,
            nil,
            productionRemoteAudioGetSize,
            nil,
            fileTypeHint(for: asset.suffix),
            &audioFile
        )
        guard openStatus == noErr, let audioFile else {
            byteSource.cancel()
            if let callbackError = callbackContext.takeError() {
                throw callbackError
            }
            throw NativePlaybackEngineError(
                "Could not open the remote audio stream",
                status: openStatus
            )
        }

        let resource = RemoteDecodedPCMResource(
            source: byteSource,
            audioFile: audioFile,
            callbackContext: callbackContext,
            suffix: asset.suffix,
            startedAt: startedAt
        )
        var extendedFile: ExtAudioFileRef?
        let wrapStatus = ExtAudioFileWrapAudioFileID(
            audioFile,
            false,
            &extendedFile
        )
        guard wrapStatus == noErr, let extendedFile else {
            resource.cancel()
            resource.disposeAfterExtAudioFile()
            throw NativePlaybackEngineError(
                "Could not create the remote PCM decoder",
                status: wrapStatus
            )
        }

        var ownershipTransferredToDecodedPCM = false
        do {
            let sourceFormat = try readSourceFormat(from: extendedFile)
            guard sourceFormat.mSampleRate > 0,
                  sourceFormat.mChannelsPerFrame > 0,
                  sourceFormat.mChannelsPerFrame <= 2 else {
                throw NativePlaybackEngineError(
                    "Remote playback currently supports mono and stereo audio"
                )
            }

            let channelCount = sourceFormat.mChannelsPerFrame
            let bytesPerFrame = channelCount
                * UInt32(MemoryLayout<Float>.size)
            try setClientFormat(
                on: extendedFile,
                sampleRate: sourceFormat.mSampleRate,
                channelCount: channelCount,
                bytesPerFrame: bytesPerFrame
            )
            let frameCount = try readFrameCount(from: extendedFile)
            #if DEBUG
            let readyElapsed = elapsedSeconds(since: startedAt)
            RemotePlaybackDiagnostics.logger.notice(
                "Remote decoder ready codec=\(formatName(sourceFormat.mFormatID), privacy: .public) sampleRate=\(sourceFormat.mSampleRate, privacy: .public) channels=\(channelCount, privacy: .public) bitDepth=\(sourceBitDepth(sourceFormat).map(String.init) ?? "unknown", privacy: .public) ready=\(readyElapsed, privacy: .public)s"
            )
            #endif
            let bufferDuration: Double = 8
            let frameCapacity = UInt64(
                ceil(sourceFormat.mSampleRate * bufferDuration)
            )
            let decodeChunkFrames = UInt32(
                min(frameCapacity, 32_768)
            )
            guard let renderer = MCPPCMRendererCreate(
                frameCapacity,
                channelCount
            ) else {
                throw NativePlaybackEngineError(
                    "Not enough memory to create the remote playback buffer"
                )
            }

            let sampleCapacity = Int(decodeChunkFrames) * Int(channelCount)
            let decodeBuffer = UnsafeMutablePointer<Float>.allocate(
                capacity: sampleCapacity
            )
            let decoder = ExtAudioFilePCMDecoderBackend(
                file: extendedFile,
                format: PCMDecoderFormat(
                    sampleRate: sourceFormat.mSampleRate,
                    channelCount: channelCount,
                    sampleFormat: .interleavedFloat32
                ),
                frameCount: frameCount,
                resourceOwner: resource
            )
            let decodedPCM = DecodedPCM(
                renderer: renderer,
                sampleRate: sourceFormat.mSampleRate,
                channelCount: channelCount,
                frameCount: frameCount,
                decoder: decoder,
                decodeBuffer: decodeBuffer,
                decodeChunkFrames: decodeChunkFrames,
                didAccessSecurityScope: false,
                sourceURL: nil
            )
            ownershipTransferredToDecodedPCM = true
            let startupFrames = UInt64(
                ceil(sourceFormat.mSampleRate)
            )
            try decodedPCM.prime(minimumFrames: startupFrames)

            #if DEBUG
            let elapsed = elapsedSeconds(since: startedAt)
            let statistics = byteSource.statistics
            RemotePlaybackDiagnostics.logger.notice(
                "Prepared remote codec=\(formatName(sourceFormat.mFormatID), privacy: .public) sampleRate=\(sourceFormat.mSampleRate, privacy: .public) channels=\(channelCount, privacy: .public) startup=\(elapsed, privacy: .public)s requests=\(statistics.rangeRequestCount, privacy: .public) bytes=\(statistics.networkByteCount, privacy: .public)"
            )
            #endif
            return decodedPCM
        } catch {
            if !ownershipTransferredToDecodedPCM {
                ExtAudioFileDispose(extendedFile)
                resource.cancel()
                resource.disposeAfterExtAudioFile()
            }
            throw error
        }
    }

    private static func readSourceFormat(
        from file: ExtAudioFileRef
    ) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = ExtAudioFileGetProperty(
            file,
            kExtAudioFileProperty_FileDataFormat,
            &size,
            &format
        )
        guard status == noErr else {
            throw NativePlaybackEngineError(
                "Could not read the remote source format",
                status: status
            )
        }
        return format
    }

    private static func setClientFormat(
        on file: ExtAudioFileRef,
        sampleRate: Double,
        channelCount: UInt32,
        bytesPerFrame: UInt32
    ) throws {
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let status = ExtAudioFileSetProperty(
            file,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &format
        )
        guard status == noErr else {
            throw NativePlaybackEngineError(
                "Could not configure remote PCM decoding",
                status: status
            )
        }
    }

    private static func readFrameCount(
        from file: ExtAudioFileRef
    ) throws -> UInt64 {
        var frameCount: Int64 = 0
        var size = UInt32(MemoryLayout<Int64>.size)
        let status = ExtAudioFileGetProperty(
            file,
            kExtAudioFileProperty_FileLengthFrames,
            &size,
            &frameCount
        )
        guard status == noErr, frameCount > 0 else {
            throw NativePlaybackEngineError(
                "The remote audio stream has no readable PCM frames",
                status: status
            )
        }
        return UInt64(frameCount)
    }

    private static func fileTypeHint(
        for suffix: String?
    ) -> AudioFileTypeID {
        switch suffix?.lowercased() {
        case "flac": kAudioFileFLACType
        case "m4a", "mp4", "alac": kAudioFileM4AType
        case "aac": kAudioFileAAC_ADTSType
        case "mp3": kAudioFileMP3Type
        case "wav", "wave": kAudioFileWAVEType
        case "aif", "aiff", "aifc": kAudioFileAIFFType
        default: 0
        }
    }

    #if DEBUG
    private static func formatName(_ formatID: AudioFormatID) -> String {
        switch formatID {
        case kAudioFormatFLAC: "FLAC"
        case kAudioFormatAppleLossless: "ALAC"
        case kAudioFormatMPEG4AAC: "AAC"
        case kAudioFormatMPEGLayer3: "MP3"
        default: "OTHER"
        }
    }

    private static func sourceBitDepth(
        _ format: AudioStreamBasicDescription
    ) -> Int? {
        if format.mBitsPerChannel > 0 {
            return Int(format.mBitsPerChannel)
        }
        guard format.mFormatID == kAudioFormatAppleLossless else {
            return nil
        }
        switch format.mFormatFlags {
        case kAppleLosslessFormatFlag_16BitSourceData: return 16
        case kAppleLosslessFormatFlag_20BitSourceData: return 20
        case kAppleLosslessFormatFlag_24BitSourceData: return 24
        case kAppleLosslessFormatFlag_32BitSourceData: return 32
        default: return nil
        }
    }

    private static func elapsedSeconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start)
            / 1_000_000_000
    }
    #endif
}

private nonisolated final class ProductionRemoteAudioCallbackContext:
    @unchecked Sendable
{
    let source: HTTPRandomAccessByteSource
    private let lock = NSLock()
    private var callbackError: Error?

    init(source: HTTPRandomAccessByteSource) {
        self.source = source
    }

    func record(_ error: Error) {
        lock.withLock { callbackError = error }
    }

    func takeError() -> Error? {
        lock.withLock {
            defer { callbackError = nil }
            return callbackError
        }
    }
}

private nonisolated final class RemoteDecodedPCMResource:
    DecodedPCMResourceOwner, @unchecked Sendable
{
    private let source: HTTPRandomAccessByteSource
    private let audioFile: AudioFileID
    private let callbackContext: ProductionRemoteAudioCallbackContext
    private let suffix: String?
    private let startedAt: UInt64
    private let lock = NSLock()
    private var didDispose = false
    private var seekStartStatistics: HTTPRandomAccessStatistics?

    init(
        source: HTTPRandomAccessByteSource,
        audioFile: AudioFileID,
        callbackContext: ProductionRemoteAudioCallbackContext,
        suffix: String?,
        startedAt: UInt64
    ) {
        self.source = source
        self.audioFile = audioFile
        self.callbackContext = callbackContext
        self.suffix = suffix
        self.startedAt = startedAt
    }

    func cancel() {
        source.cancel()
    }

    func disposeAfterExtAudioFile() {
        let shouldDispose = lock.withLock {
            guard !didDispose else { return false }
            didDispose = true
            return true
        }
        if shouldDispose {
            AudioFileClose(audioFile)
        }
    }

    func beginSeek() {
        seekStartStatistics = source.statistics
        source.beginTemporaryNetworkBudget(additionalBytes: 4 * 1_024 * 1_024)
        #if DEBUG
        RemotePlaybackDiagnostics.logger.notice(
            "Remote seek requested codecHint=\(self.suffix ?? "unknown", privacy: .public)"
        )
        #endif
    }

    func endSeek(succeeded: Bool) {
        source.endTemporaryNetworkBudget()
        #if DEBUG
        let before = seekStartStatistics
        let after = source.statistics
        let requests = after.rangeRequestCount - (before?.rangeRequestCount ?? 0)
        let bytes = after.networkByteCount - (before?.networkByteCount ?? 0)
        RemotePlaybackDiagnostics.logger.notice(
            "Remote seek \(succeeded ? "completed" : "failed", privacy: .public) codecHint=\(self.suffix ?? "unknown", privacy: .public) additionalRequests=\(requests, privacy: .public) additionalBytes=\(bytes, privacy: .public)"
        )
        #endif
        seekStartStatistics = nil
    }

    func takeReadError() -> Error? {
        callbackContext.takeError()
    }

    func didProduceFirstPCM() {
        #if DEBUG
        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - startedAt
        ) / 1_000_000_000
        let statistics = source.statistics
        let fetchedPercentage = Double(statistics.networkByteCount)
            / Double(source.length) * 100
        RemotePlaybackDiagnostics.logger.notice(
            "Remote first PCM time=\(elapsed, privacy: .public)s requests=\(statistics.rangeRequestCount, privacy: .public) bytes=\(statistics.networkByteCount, privacy: .public) fetched=\(fetchedPercentage, privacy: .public)%"
        )
        #endif
    }
}

private nonisolated func productionRemoteAudioRead(
    clientData: UnsafeMutableRawPointer,
    position: Int64,
    requestCount: UInt32,
    buffer: UnsafeMutableRawPointer,
    actualCount: UnsafeMutablePointer<UInt32>
) -> OSStatus {
    let context = Unmanaged<ProductionRemoteAudioCallbackContext>
        .fromOpaque(clientData).takeUnretainedValue()
    do {
        let data = try context.source.read(
            offset: position,
            count: Int(requestCount)
        )
        data.copyBytes(
            to: buffer.assumingMemoryBound(to: UInt8.self),
            count: data.count
        )
        actualCount.pointee = UInt32(data.count)
        return noErr
    } catch {
        actualCount.pointee = 0
        context.record(error)
        return kAudioFileUnspecifiedError
    }
}

private nonisolated func productionRemoteAudioGetSize(
    clientData: UnsafeMutableRawPointer
) -> Int64 {
    let context = Unmanaged<ProductionRemoteAudioCallbackContext>
        .fromOpaque(clientData).takeUnretainedValue()
    return context.source.length
}

#if DEBUG
enum RemotePlaybackDiagnostics {
    nonisolated static let logger = Logger(
        subsystem: "com.hildgyorgy.MusiCards",
        category: "NavidromePlayback"
    )
}
#endif
#endif
