#if os(macOS) || os(iOS)
import Foundation
#if DEBUG
import OSLog
#endif

nonisolated enum LibFLACRemoteAudioDecoder {
    static let experimentalUserDefaultsKey =
        "MusiCards.ExperimentalRemoteLibFLAC"

    static var isExperimentEnabled: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: experimentalUserDefaultsKey)
        #else
        false
        #endif
    }

    static func decode(
        asset: RemotePlaybackAsset,
        byteSource: HTTPRandomAccessByteSource
    ) throws -> DecodedPCM {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let backend = try LibFLACPCMDecoderBackend(
            byteSource: byteSource,
            startedAt: startedAt
        )

        let bufferDuration: Double = 8
        let frameCapacity = UInt64(
            ceil(backend.format.sampleRate * bufferDuration)
        )
        let decodeChunkFrames = UInt32(min(frameCapacity, 32_768))
        guard let renderer = MCPPCMRendererCreate(
            frameCapacity,
            backend.format.channelCount
        ) else {
            throw NativePlaybackEngineError(
                "Not enough memory to create the experimental FLAC playback buffer"
            )
        }

        let sampleCapacity = Int(decodeChunkFrames)
            * Int(backend.format.channelCount)
        let decodeBuffer = UnsafeMutablePointer<Float>.allocate(
            capacity: sampleCapacity
        )
        let decodedPCM = DecodedPCM(
            renderer: renderer,
            sampleRate: backend.format.sampleRate,
            channelCount: backend.format.channelCount,
            frameCount: backend.frameCount,
            decoder: backend,
            decodeBuffer: decodeBuffer,
            decodeChunkFrames: decodeChunkFrames,
            didAccessSecurityScope: false,
            sourceURL: nil
        )

        do {
            try decodedPCM.prime(
                minimumFrames: min(
                    UInt64(ceil(backend.format.sampleRate)),
                    UInt64(MCPPCMRendererWritableFrames(renderer))
                )
            )
            #if DEBUG
            let elapsed = elapsedSeconds(since: startedAt)
            let statistics = byteSource.statistics
            RemotePlaybackDiagnostics.logger.notice(
                "Experimental libFLAC ready sampleRate=\(backend.format.sampleRate, privacy: .public) channels=\(backend.format.channelCount, privacy: .public) bitsPerSample=\(backend.bitsPerSample, privacy: .public) totalFrames=\(backend.frameCount, privacy: .public) startup=\(elapsed, privacy: .public)s requests=\(statistics.rangeRequestCount, privacy: .public) bytes=\(statistics.networkByteCount, privacy: .public)"
            )
            #endif
            return decodedPCM
        } catch {
            decodedPCM.cancel()
            throw error
        }
    }

    #if DEBUG
    private static func elapsedSeconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start)
            / 1_000_000_000
    }
    #endif
}

private nonisolated final class LibFLACCallbackContext:
    @unchecked Sendable
{
    let source: HTTPRandomAccessByteSource

    private let lock = NSLock()
    private var byteOffset: Int64 = 0
    private var callbackError: Error?
    private var decoderErrorStatus: Int?
    fileprivate(set) var sampleRate: Double = 0
    fileprivate(set) var channelCount: UInt32 = 0
    fileprivate(set) var bitsPerSample: Int = 0
    fileprivate(set) var totalSamples: UInt64 = 0
    private var pendingSamples = [Int32]()
    private var pendingFrameCount: UInt32 = 0
    private var pendingFrameOffset: UInt32 = 0

    var hasPendingFrames: Bool { pendingFrameCount > 0 }

    init(source: HTTPRandomAccessByteSource) {
        self.source = source
    }

    func read(
        buffer: UnsafeMutablePointer<UInt8>,
        byteCount: UnsafeMutablePointer<Int>
    ) -> Int {
        let offset = lock.withLock { byteOffset }
        do {
            let data = try source.read(offset: offset, count: byteCount.pointee)
            data.copyBytes(to: buffer, count: data.count)
            lock.withLock { byteOffset += Int64(data.count) }
            byteCount.pointee = data.count
            return data.isEmpty ? 1 : 0
        } catch {
            record(error)
            byteCount.pointee = 0
            return 2
        }
    }

    func seek(to offset: UInt64) -> Int {
        guard offset <= UInt64(source.length) else {
            record(HTTPRandomAccessByteSourceError.invalidRead)
            return -1
        }
        lock.withLock { byteOffset = Int64(offset) }
        return 0
    }

    func tell() -> (Int, UInt64) {
        (0, UInt64(lock.withLock { byteOffset }))
    }

    func length() -> (Int, UInt64) {
        (0, UInt64(source.length))
    }

    func isEOF() -> Bool {
        lock.withLock { byteOffset >= source.length }
    }

    func setMetadata(
        sampleRate: UInt32,
        channels: UInt32,
        bitsPerSample: UInt32,
        totalSamples: UInt64
    ) {
        self.sampleRate = Double(sampleRate)
        self.channelCount = channels
        self.bitsPerSample = Int(bitsPerSample)
        self.totalSamples = totalSamples
    }

    func write(
        frameCount: UInt32,
        channels: UInt32,
        bitsPerSample: UInt32,
        interleavedSamples: UnsafePointer<Int32>
    ) -> Int {
        guard pendingFrameCount == 0 else {
            record(NativePlaybackEngineError(
                "The experimental FLAC decoder produced overlapping PCM frames"
            ))
            return -1
        }
        let sampleCount = Int(frameCount) * Int(channels)
        pendingSamples = Array(
            UnsafeBufferPointer(
                start: interleavedSamples,
                count: sampleCount
            )
        )
        pendingFrameCount = frameCount
        pendingFrameOffset = 0
        if Int(bitsPerSample) != self.bitsPerSample {
            record(NativePlaybackEngineError(
                "The FLAC frame format changed unexpectedly"
            ))
            return -1
        }
        return 0
    }

    func copyPending(
        into buffer: UnsafeMutablePointer<Float>,
        frameCapacity: UInt32,
        channelCount: UInt32,
        bitsPerSample: Int
    ) -> UInt32 {
        let available = pendingFrameCount - pendingFrameOffset
        let frames = min(available, frameCapacity)
        let sourceOffset = Int(pendingFrameOffset)
            * Int(channelCount)
        let destinationCount = Int(frames) * Int(channelCount)
        let scale = Float(
            1.0 / pow(2.0, Double(max(bitsPerSample - 1, 1)))
        )
        for index in 0..<destinationCount {
            buffer[index] = Float(pendingSamples[sourceOffset + index]) * scale
        }
        pendingFrameOffset += frames
        if pendingFrameOffset == pendingFrameCount {
            pendingSamples.removeAll(keepingCapacity: true)
            pendingFrameCount = 0
            pendingFrameOffset = 0
        }
        return frames
    }

    func resetPending() {
        pendingSamples.removeAll(keepingCapacity: true)
        pendingFrameCount = 0
        pendingFrameOffset = 0
    }

    func record(_ error: Error) {
        lock.withLock { callbackError = error }
    }

    func recordDecoderError(_ status: Int) {
        lock.withLock { decoderErrorStatus = status }
    }

    func takeError() -> Error? {
        lock.withLock {
            defer {
                callbackError = nil
                decoderErrorStatus = nil
            }
            if let callbackError { return callbackError }
            if let decoderErrorStatus {
                return NativePlaybackEngineError(
                    "The experimental FLAC decoder reported error \(decoderErrorStatus)"
                )
            }
            return nil
        }
    }

    func beginSeek() {
        source.beginTemporaryNetworkBudget(additionalBytes: 4 * 1_024 * 1_024)
    }

    func endSeek() {
        source.endTemporaryNetworkBudget()
    }
}

private nonisolated final class LibFLACPCMDecoderBackend:
    PCMDecoderBackend, @unchecked Sendable
{
    let format: PCMDecoderFormat
    let frameCount: UInt64
    let isRemote = true
    let seekCapabilityOverride: PlaybackSeekCapability? = .supported
    let bitsPerSample: Int

    private let decoder: OpaquePointer
    private let context: LibFLACCallbackContext
    private var didEnd = false

    init(
        byteSource: HTTPRandomAccessByteSource,
        startedAt: UInt64
    ) throws {
        let context = LibFLACCallbackContext(source: byteSource)
        guard let decoder = MCPFLACDecoderCreate() else {
            byteSource.cancel()
            throw NativePlaybackEngineError(
                "Could not create the experimental FLAC decoder"
            )
        }

        let contextPointer = Unmanaged.passUnretained(context).toOpaque()
        let initStatus = MCPFLACDecoderInitialize(
            decoder,
            mcpFLACRead,
            mcpFLACSeek,
            mcpFLACTell,
            mcpFLACLength,
            mcpFLACEof,
            mcpFLACWrite,
            mcpFLACMetadata,
            mcpFLACError,
            contextPointer
        )
        guard initStatus == 0,
              MCPFLACDecoderProcessMetadata(decoder) else {
            MCPFLACDecoderDestroy(decoder)
            byteSource.cancel()
            throw context.takeError()
                ?? NativePlaybackEngineError(
                    "Could not initialize the experimental FLAC decoder"
                )
        }

        guard context.sampleRate > 0,
              context.channelCount > 0,
              context.channelCount <= 2,
              context.bitsPerSample == 16 || context.bitsPerSample == 24,
              context.totalSamples > 0 else {
            MCPFLACDecoderDestroy(decoder)
            byteSource.cancel()
            throw NativePlaybackEngineError(
                "The experimental FLAC decoder supports only mono/stereo 16-bit or 24-bit files with known duration"
            )
        }

        self.decoder = decoder
        self.context = context
        self.bitsPerSample = context.bitsPerSample
        self.format = PCMDecoderFormat(
            sampleRate: context.sampleRate,
            channelCount: context.channelCount,
            sampleFormat: .interleavedFloat32
        )
        self.frameCount = context.totalSamples

        // The metadata callback is complete before the first PCM request.
        _ = startedAt
    }

    deinit {
        MCPFLACDecoderDestroy(decoder)
        context.source.cancel()
    }

    func read(
        into buffer: UnsafeMutableRawPointer,
        frameCapacity: UInt32
    ) throws -> UInt32 {
        let destination = buffer.assumingMemoryBound(to: Float.self)
        var written: UInt32 = 0
        while written < frameCapacity {
            if context.hasPendingFrames {
                written += context.copyPending(
                    into: destination.advanced(by: Int(written) * Int(format.channelCount)),
                    frameCapacity: frameCapacity - written,
                    channelCount: format.channelCount,
                    bitsPerSample: bitsPerSample
                )
                continue
            }

            guard !didEnd else { break }
            guard MCPFLACDecoderProcessSingle(decoder) else {
                didEnd = true
                if let error = context.takeError() { throw error }
                break
            }
            if let error = context.takeError() { throw error }
            if MCPFLACDecoderHasEnded(decoder) { didEnd = true }
        }
        if written == 0, let error = context.takeError() { throw error }
        return written
    }

    func seek(to frame: UInt64) throws {
        context.resetPending()
        didEnd = false
        guard MCPFLACDecoderSeekAbsolute(decoder, frame) else {
            throw context.takeError()
                ?? NativePlaybackEngineError(
                    "Could not seek in the experimental FLAC decoder"
                )
        }
        if let error = context.takeError() { throw error }
    }

    func cancel() {
        context.source.cancel()
    }

    func beginSeek() { context.beginSeek() }
    func endSeek(succeeded: Bool) { _ = succeeded; context.endSeek() }
    func takeReadError() -> Error? { context.takeError() }
    func didProduceFirstPCM() {}
}

private nonisolated func mcpFLACRead(
    _ context: UnsafeMutableRawPointer?,
    _ buffer: UnsafeMutablePointer<UInt8>?,
    _ byteCount: UnsafeMutablePointer<Int>?
) -> Int32 {
    guard let context, let buffer, let byteCount else { return 2 }
    return Int32(Unmanaged<LibFLACCallbackContext>
        .fromOpaque(context)
        .takeUnretainedValue()
        .read(buffer: buffer, byteCount: byteCount))
}

private nonisolated func mcpFLACSeek(
    _ context: UnsafeMutableRawPointer?,
    _ offset: UInt64
) -> Int32 {
    guard let context else { return -1 }
    return Int32(Unmanaged<LibFLACCallbackContext>
        .fromOpaque(context)
        .takeUnretainedValue()
        .seek(to: offset))
}

private nonisolated func mcpFLACTell(
    _ context: UnsafeMutableRawPointer?,
    _ offset: UnsafeMutablePointer<UInt64>?
) -> Int32 {
    guard let context, let offset else { return -1 }
    let result = Unmanaged<LibFLACCallbackContext>
        .fromOpaque(context)
        .takeUnretainedValue()
        .tell()
    offset.pointee = result.1
    return Int32(result.0)
}

private nonisolated func mcpFLACLength(
    _ context: UnsafeMutableRawPointer?,
    _ length: UnsafeMutablePointer<UInt64>?
) -> Int32 {
    guard let context, let length else { return -1 }
    let result = Unmanaged<LibFLACCallbackContext>
        .fromOpaque(context)
        .takeUnretainedValue()
        .length()
    length.pointee = result.1
    return Int32(result.0)
}

private nonisolated func mcpFLACEof(
    _ context: UnsafeMutableRawPointer?
) -> Bool {
    guard let context else { return true }
    return Unmanaged<LibFLACCallbackContext>
        .fromOpaque(context)
        .takeUnretainedValue()
        .isEOF()
}

private nonisolated func mcpFLACMetadata(
    _ context: UnsafeMutableRawPointer?,
    _ sampleRate: UInt32,
    _ channels: UInt32,
    _ bitsPerSample: UInt32,
    _ totalSamples: UInt64
) {
    guard let context else { return }
    Unmanaged<LibFLACCallbackContext>
        .fromOpaque(context)
        .takeUnretainedValue()
        .setMetadata(
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample,
            totalSamples: totalSamples
        )
}

private nonisolated func mcpFLACWrite(
    _ context: UnsafeMutableRawPointer?,
    _ frameCount: UInt32,
    _ channels: UInt32,
    _ bitsPerSample: UInt32,
    _ samples: UnsafePointer<Int32>?
) -> Int32 {
    guard let context, let samples else { return -1 }
    return Int32(Unmanaged<LibFLACCallbackContext>
        .fromOpaque(context)
        .takeUnretainedValue()
        .write(
            frameCount: frameCount,
            channels: channels,
            bitsPerSample: bitsPerSample,
            interleavedSamples: samples
        ))
}

private nonisolated func mcpFLACError(
    _ context: UnsafeMutableRawPointer?,
    _ status: Int32
) {
    guard let context else { return }
    Unmanaged<LibFLACCallbackContext>
        .fromOpaque(context)
        .takeUnretainedValue()
        .recordDecoderError(Int(status))
}
#endif
