//
//  LocalAudioFileDecoder.swift
//  MusiCards
//

#if os(macOS) || os(iOS)
import AudioToolbox
import Foundation
#if DEBUG
import OSLog
#endif

struct NativePlaybackEngineError: LocalizedError {
    let operation: String
    let status: OSStatus?

    init(_ operation: String, status: OSStatus? = nil) {
        self.operation = operation
        self.status = status
    }

    var errorDescription: String? {
        guard let status else { return operation }
        return "\(operation) (Core Audio \(status))"
    }
}

nonisolated protocol DecodedPCMResourceOwner: AnyObject, Sendable {
    func cancel()
    func disposeAfterExtAudioFile()
    func beginSeek()
    func endSeek(succeeded: Bool)
    func takeReadError() -> Error?
    func didProduceFirstPCM()
}

extension DecodedPCMResourceOwner {
    nonisolated func beginSeek() {}
    nonisolated func endSeek(succeeded: Bool) {}
    nonisolated func takeReadError() -> Error? { nil }
    nonisolated func didProduceFirstPCM() {}
}

nonisolated enum PCMDecoderSampleFormat: Equatable, Sendable {
    case interleavedFloat32
    case interleavedSignedInteger(bitDepth: Int)
}

nonisolated struct PCMDecoderFormat: Equatable, Sendable {
    let sampleRate: Double
    let channelCount: UInt32
    let sampleFormat: PCMDecoderSampleFormat
}

nonisolated protocol PCMDecoderBackend: AnyObject, Sendable {
    var format: PCMDecoderFormat { get }
    var frameCount: UInt64 { get }
    var isRemote: Bool { get }
    var seekCapabilityOverride: PlaybackSeekCapability? { get }
    func read(
        into buffer: UnsafeMutableRawPointer,
        frameCapacity: UInt32
    ) throws -> UInt32
    func seek(to frame: UInt64) throws
    func cancel()
    func beginSeek()
    func endSeek(succeeded: Bool)
    func takeReadError() -> Error?
    func didProduceFirstPCM()
}

nonisolated final class ExtAudioFilePCMDecoderBackend:
    PCMDecoderBackend, @unchecked Sendable
{
    let format: PCMDecoderFormat
    let frameCount: UInt64
    let isRemote: Bool
    let seekCapabilityOverride: PlaybackSeekCapability?

    private let file: ExtAudioFileRef
    private let resourceOwner: (any DecodedPCMResourceOwner)?
    private let bytesPerFrame: UInt32
    private let lock = NSLock()
    private var didDispose = false

    init(
        file: ExtAudioFileRef,
        format: PCMDecoderFormat,
        frameCount: UInt64,
        resourceOwner: (any DecodedPCMResourceOwner)? = nil,
        seekCapabilityOverride: PlaybackSeekCapability? = nil
    ) {
        self.file = file
        self.format = format
        self.frameCount = frameCount
        self.isRemote = resourceOwner != nil
        self.seekCapabilityOverride = seekCapabilityOverride
        self.resourceOwner = resourceOwner
        let bytesPerSample: UInt32
        switch format.sampleFormat {
        case .interleavedFloat32:
            bytesPerSample = UInt32(MemoryLayout<Float>.size)
        case .interleavedSignedInteger(let bitDepth):
            bytesPerSample = UInt32(max((bitDepth + 7) / 8, 1))
        }
        self.bytesPerFrame = format.channelCount * bytesPerSample
    }

    deinit { dispose() }

    func read(
        into buffer: UnsafeMutableRawPointer,
        frameCapacity: UInt32
    ) throws -> UInt32 {
        var framesToRead = frameCapacity
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: format.channelCount,
                mDataByteSize: frameCapacity * bytesPerFrame,
                mData: buffer
            )
        )
        let status = ExtAudioFileRead(file, &framesToRead, &bufferList)
        guard status == noErr else {
            throw NativePlaybackEngineError(
                "PCM decoding failed",
                status: status
            )
        }
        return framesToRead
    }

    func seek(to frame: UInt64) throws {
        let status = ExtAudioFileSeek(file, Int64(frame))
        guard status == noErr else {
            throw NativePlaybackEngineError(
                "Could not seek in the selected audio file",
                status: status
            )
        }
    }

    func cancel() { resourceOwner?.cancel() }
    func beginSeek() { resourceOwner?.beginSeek() }
    func endSeek(succeeded: Bool) {
        resourceOwner?.endSeek(succeeded: succeeded)
    }
    func takeReadError() -> Error? { resourceOwner?.takeReadError() }
    func didProduceFirstPCM() { resourceOwner?.didProduceFirstPCM() }

    private func dispose() {
        let shouldDispose = lock.withLock {
            guard !didDispose else { return false }
            didDispose = true
            return true
        }
        guard shouldDispose else { return }
        resourceOwner?.cancel()
        ExtAudioFileDispose(file)
        resourceOwner?.disposeAfterExtAudioFile()
    }
}

nonisolated final class DecodedPCM: @unchecked Sendable {
    private static let feederQueueKey = DispatchSpecificKey<Void>()

    let renderer: OpaquePointer
    let sampleRate: Double
    let channelCount: UInt32
    let frameCount: UInt64
    let isRemote: Bool
    let seekCapabilityOverride: PlaybackSeekCapability?

    private let decoder: any PCMDecoderBackend
    private let feederQueue = DispatchQueue(
        label: "com.hildgyorgy.MusiCards.audio-feeder",
        qos: .userInitiated
    )
    private let feederTimer: DispatchSourceTimer
    private let decodeBuffer: UnsafeMutablePointer<Float>
    private let decodeChunkFrames: UInt32
    private let bytesPerFrame: UInt32
    private let frameCapacity: UInt64
    private let didAccessSecurityScope: Bool
    private let sourceURL: URL?
    private let errorLock = NSLock()
    private var feederError: Error?
    private var didReachEndOfStream = false
    private var didReportFirstPCM = false

    init(
        renderer: OpaquePointer,
        sampleRate: Double,
        channelCount: UInt32,
        frameCount: UInt64,
        decoder: any PCMDecoderBackend,
        decodeBuffer: UnsafeMutablePointer<Float>,
        decodeChunkFrames: UInt32,
        didAccessSecurityScope: Bool,
        sourceURL: URL?
    ) {
        self.renderer = renderer
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.isRemote = decoder.isRemote
        self.seekCapabilityOverride = decoder.seekCapabilityOverride
        self.decoder = decoder
        self.decodeBuffer = decodeBuffer
        self.decodeChunkFrames = decodeChunkFrames
        self.bytesPerFrame = channelCount * UInt32(MemoryLayout<Float>.size)
        self.frameCapacity = UInt64(
            MCPPCMRendererWritableFrames(renderer)
        )
        self.didAccessSecurityScope = didAccessSecurityScope
        self.sourceURL = sourceURL
        self.feederTimer = DispatchSource.makeTimerSource(queue: feederQueue)
        feederQueue.setSpecific(key: Self.feederQueueKey, value: ())

        feederTimer.setEventHandler { [weak self] in
            self?.fillAvailableSpace()
        }
        feederTimer.schedule(deadline: .distantFuture)
        feederTimer.resume()
    }

    deinit {
        decoder.cancel()
        feederTimer.cancel()
        if DispatchQueue.getSpecific(key: Self.feederQueueKey) == nil {
            feederQueue.sync {}
        }
        decodeBuffer.deallocate()
        MCPPCMRendererDestroy(renderer)
        if didAccessSecurityScope, let sourceURL {
            sourceURL.stopAccessingSecurityScopedResource()
        }
    }

    func prime(minimumFrames: UInt64? = nil) throws {
        let targetFrames = min(
            minimumFrames ?? frameCapacity,
            frameCapacity
        )
        feederQueue.sync {
            fill(toMinimumBufferedFrames: targetFrames)
        }
        if let error = currentFeederError() {
            throw error
        }
        feederTimer.schedule(
            deadline: .now(),
            repeating: .milliseconds(10)
        )
    }

    func cancel() {
        #if DEBUG
        if isRemote {
            RemotePlaybackDiagnostics.logger.notice(
                "Remote feeder cancellation requested"
            )
        }
        #endif
        decoder.cancel()
        feederTimer.cancel()
    }

    func seek(to frame: UInt64) throws {
        let boundedFrame = min(frame, frameCount)
        try feederQueue.sync {
            decoder.beginSeek()
            var seekSucceeded = false
            defer { decoder.endSeek(succeeded: seekSucceeded) }
            try decoder.seek(to: boundedFrame)
            errorLock.withLock { feederError = nil }
            didReachEndOfStream = false
            MCPPCMRendererReset(renderer, boundedFrame)
            fill(
                toMinimumBufferedFrames: min(
                    UInt64(ceil(sampleRate)),
                    frameCapacity
                )
            )
            if let error = currentFeederError() {
                throw error
            }
            guard !isRemote || bufferedFrameCount > 0 else {
                throw NativePlaybackEngineError(
                    "Seeking produced no playable PCM frames"
                )
            }
            seekSucceeded = true
        }
    }

    func takeFeederError() -> Error? {
        errorLock.withLock {
            defer { feederError = nil }
            return feederError
        }
    }

    private func fillAvailableSpace() {
        while !didReachEndOfStream,
              MCPPCMRendererWritableFrames(renderer) >= decodeChunkFrames {
            fillOnce()
            if currentFeederError() != nil { return }
        }
    }

    private func fill(toMinimumBufferedFrames targetFrames: UInt64) {
        while !didReachEndOfStream,
              bufferedFrameCount < targetFrames {
            fillOnce()
            if currentFeederError() != nil { return }
        }
    }

    private func fillOnce() {
        var framesToRead = min(
            decodeChunkFrames,
            MCPPCMRendererWritableFrames(renderer)
        )
        guard framesToRead > 0 else { return }

        do {
            framesToRead = try decoder.read(
                into: UnsafeMutableRawPointer(decodeBuffer),
                frameCapacity: framesToRead
            )
        } catch {
            didReachEndOfStream = true
            setFeederError(
                decoder.takeReadError() ?? error
            )
            MCPPCMRendererMarkEndOfStream(renderer)
            return
        }
        guard framesToRead > 0 else {
            didReachEndOfStream = true
            MCPPCMRendererMarkEndOfStream(renderer)
            return
        }

        let writtenFrames = MCPPCMRendererWrite(
            renderer,
            decodeBuffer,
            framesToRead
        )
        if writtenFrames != framesToRead {
            didReachEndOfStream = true
            setFeederError(
                NativePlaybackEngineError("The PCM feeder could not keep its buffer state")
            )
            MCPPCMRendererMarkEndOfStream(renderer)
        } else if !didReportFirstPCM {
            didReportFirstPCM = true
            decoder.didProduceFirstPCM()
        }
    }

    private func setFeederError(_ error: Error) {
        errorLock.withLock { feederError = error }
    }

    private func currentFeederError() -> Error? {
        errorLock.withLock { feederError }
    }

    private var bufferedFrameCount: UInt64 {
        frameCapacity - UInt64(MCPPCMRendererWritableFrames(renderer))
    }
}

enum LocalAudioFileDecoder {
    nonisolated static func decode(url: URL) throws -> DecodedPCM {
        let didAccess = url.startAccessingSecurityScopedResource()

        var file: ExtAudioFileRef?
        var openStatus: OSStatus = kAudioFileUnspecifiedError
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            openStatus = ExtAudioFileOpenURL(coordinatedURL as CFURL, &file)
        }
        if let coordinationError {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
            throw NativePlaybackEngineError(
                "Could not download the selected audio file: "
                    + coordinationError.localizedDescription
            )
        }
        guard openStatus == noErr, let file else {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
            throw NativePlaybackEngineError(
                "Could not open the selected audio file",
                status: openStatus
            )
        }
        let sourceFormat: AudioStreamBasicDescription
        do {
            sourceFormat = try readSourceFormat(from: file)
        } catch {
            ExtAudioFileDispose(file)
            if didAccess { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        guard sourceFormat.mSampleRate > 0,
              sourceFormat.mChannelsPerFrame > 0,
              sourceFormat.mChannelsPerFrame <= 2 else {
            ExtAudioFileDispose(file)
            if didAccess { url.stopAccessingSecurityScopedResource() }
            throw NativePlaybackEngineError(
                "The first player milestone currently supports mono and stereo audio"
            )
        }

        let channelCount = sourceFormat.mChannelsPerFrame
        let bytesPerFrame = channelCount * UInt32(MemoryLayout<Float>.size)
        let frameCount: UInt64
        do {
            try setClientFormat(
                on: file,
                sampleRate: sourceFormat.mSampleRate,
                channelCount: channelCount,
                bytesPerFrame: bytesPerFrame
            )
            frameCount = try readFrameCount(from: file)
        } catch {
            ExtAudioFileDispose(file)
            if didAccess { url.stopAccessingSecurityScopedResource() }
            throw error
        }

        let bufferDuration: Double = 8
        let frameCapacity = UInt64(ceil(sourceFormat.mSampleRate * bufferDuration))
        let decodeChunkFrames = UInt32(min(frameCapacity, 32_768))
        guard let renderer = MCPPCMRendererCreate(frameCapacity, channelCount) else {
            ExtAudioFileDispose(file)
            if didAccess { url.stopAccessingSecurityScopedResource() }
            throw NativePlaybackEngineError(
                "Not enough memory to create the bounded playback buffer"
            )
        }

        let sampleCapacity = Int(decodeChunkFrames) * Int(channelCount)
        let decodeBuffer = UnsafeMutablePointer<Float>.allocate(capacity: sampleCapacity)
        let decoder = ExtAudioFilePCMDecoderBackend(
            file: file,
            format: PCMDecoderFormat(
                sampleRate: sourceFormat.mSampleRate,
                channelCount: channelCount,
                sampleFormat: .interleavedFloat32
            ),
            frameCount: frameCount
        )
        let decodedPCM = DecodedPCM(
            renderer: renderer,
            sampleRate: sourceFormat.mSampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            decoder: decoder,
            decodeBuffer: decodeBuffer,
            decodeChunkFrames: decodeChunkFrames,
            didAccessSecurityScope: didAccess,
            sourceURL: url
        )
        do {
            try decodedPCM.prime()
            return decodedPCM
        } catch {
            throw error
        }
    }

    nonisolated private static func readSourceFormat(
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
                "Could not read the source audio format",
                status: status
            )
        }
        return format
    }

    nonisolated private static func setClientFormat(
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
                "Could not configure PCM decoding",
                status: status
            )
        }
    }

    nonisolated private static func readFrameCount(
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
                "The selected audio file has no readable PCM frames",
                status: status
            )
        }
        return UInt64(frameCount)
    }
}
#endif
