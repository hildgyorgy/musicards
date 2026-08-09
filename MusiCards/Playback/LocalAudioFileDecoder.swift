//
//  LocalAudioFileDecoder.swift
//  MusiCards
//

#if os(macOS) || os(iOS)
import AudioToolbox
import Foundation

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

nonisolated final class DecodedPCM: @unchecked Sendable {
    let renderer: OpaquePointer
    let sampleRate: Double
    let channelCount: UInt32
    let frameCount: UInt64

    private let file: ExtAudioFileRef
    private let feederQueue = DispatchQueue(
        label: "com.hildgyorgy.MusiCards.audio-feeder",
        qos: .userInitiated
    )
    private let feederTimer: DispatchSourceTimer
    private let decodeBuffer: UnsafeMutablePointer<Float>
    private let decodeChunkFrames: UInt32
    private let bytesPerFrame: UInt32
    private let didAccessSecurityScope: Bool
    private let sourceURL: URL
    private let errorLock = NSLock()
    private var feederError: Error?
    private var didReachEndOfStream = false

    init(
        renderer: OpaquePointer,
        sampleRate: Double,
        channelCount: UInt32,
        frameCount: UInt64,
        file: ExtAudioFileRef,
        decodeBuffer: UnsafeMutablePointer<Float>,
        decodeChunkFrames: UInt32,
        didAccessSecurityScope: Bool,
        sourceURL: URL
    ) {
        self.renderer = renderer
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.file = file
        self.decodeBuffer = decodeBuffer
        self.decodeChunkFrames = decodeChunkFrames
        self.bytesPerFrame = channelCount * UInt32(MemoryLayout<Float>.size)
        self.didAccessSecurityScope = didAccessSecurityScope
        self.sourceURL = sourceURL
        self.feederTimer = DispatchSource.makeTimerSource(queue: feederQueue)

        feederTimer.setEventHandler { [weak self] in
            self?.fillAvailableSpace()
        }
        feederTimer.schedule(deadline: .now(), repeating: .milliseconds(10))
        feederTimer.resume()
    }

    deinit {
        feederTimer.cancel()
        feederQueue.sync {}
        ExtAudioFileDispose(file)
        decodeBuffer.deallocate()
        MCPPCMRendererDestroy(renderer)
        if didAccessSecurityScope {
            sourceURL.stopAccessingSecurityScopedResource()
        }
    }

    func prime() throws {
        feederQueue.sync {
            while !didReachEndOfStream,
                  MCPPCMRendererWritableFrames(renderer) >= decodeChunkFrames {
                fillOnce()
                if currentFeederError() != nil { break }
            }
        }
        if let error = currentFeederError() {
            throw error
        }
    }

    func seek(to frame: UInt64) throws {
        let boundedFrame = min(frame, frameCount)
        try feederQueue.sync {
            let status = ExtAudioFileSeek(file, Int64(boundedFrame))
            guard status == noErr else {
                throw NativePlaybackEngineError(
                    "Could not seek in the selected audio file",
                    status: status
                )
            }
            errorLock.withLock { feederError = nil }
            didReachEndOfStream = false
            MCPPCMRendererReset(renderer, boundedFrame)
            fillAvailableSpace()
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

    private func fillOnce() {
        var framesToRead = min(
            decodeChunkFrames,
            MCPPCMRendererWritableFrames(renderer)
        )
        guard framesToRead > 0 else { return }

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: channelCount,
                mDataByteSize: framesToRead * bytesPerFrame,
                mData: decodeBuffer
            )
        )
        let status = ExtAudioFileRead(file, &framesToRead, &bufferList)
        guard status == noErr else {
            didReachEndOfStream = true
            setFeederError(
                NativePlaybackEngineError("PCM decoding failed", status: status)
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
        }
    }

    private func setFeederError(_ error: Error) {
        errorLock.withLock { feederError = error }
    }

    private func currentFeederError() -> Error? {
        errorLock.withLock { feederError }
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
        let decodedPCM = DecodedPCM(
            renderer: renderer,
            sampleRate: sourceFormat.mSampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            file: file,
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
