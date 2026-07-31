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

    init(
        renderer: OpaquePointer,
        sampleRate: Double,
        channelCount: UInt32,
        frameCount: UInt64
    ) {
        self.renderer = renderer
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
    }

    deinit {
        MCPPCMRendererDestroy(renderer)
    }
}

enum LocalAudioFileDecoder {
    nonisolated static func decode(url: URL) throws -> DecodedPCM {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        var file: ExtAudioFileRef?
        let openStatus = ExtAudioFileOpenURL(url as CFURL, &file)
        guard openStatus == noErr, let file else {
            throw NativePlaybackEngineError(
                "Could not open the selected audio file",
                status: openStatus
            )
        }
        defer { ExtAudioFileDispose(file) }

        let sourceFormat = try readSourceFormat(from: file)
        guard sourceFormat.mSampleRate > 0,
              sourceFormat.mChannelsPerFrame > 0,
              sourceFormat.mChannelsPerFrame <= 2 else {
            throw NativePlaybackEngineError(
                "The first player milestone currently supports mono and stereo audio"
            )
        }

        let channelCount = sourceFormat.mChannelsPerFrame
        let bytesPerFrame = channelCount * UInt32(MemoryLayout<Float>.size)
        try setClientFormat(
            on: file,
            sampleRate: sourceFormat.mSampleRate,
            channelCount: channelCount,
            bytesPerFrame: bytesPerFrame
        )

        let frameCapacity = try readFrameCount(from: file)
        guard let renderer = MCPPCMRendererCreate(frameCapacity, channelCount),
              let samples = MCPPCMRendererMutableSamples(renderer) else {
            throw NativePlaybackEngineError(
                "Not enough memory to prepare the selected audio file"
            )
        }

        do {
            let decodedFrames = try decodeFrames(
                from: file,
                into: samples,
                frameCapacity: frameCapacity,
                channelCount: channelCount,
                bytesPerFrame: bytesPerFrame
            )
            MCPPCMRendererSetFrameCount(renderer, decodedFrames)
            return DecodedPCM(
                renderer: renderer,
                sampleRate: sourceFormat.mSampleRate,
                channelCount: channelCount,
                frameCount: decodedFrames
            )
        } catch {
            MCPPCMRendererDestroy(renderer)
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
                "Could not configure lossless PCM decoding",
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

    nonisolated private static func decodeFrames(
        from file: ExtAudioFileRef,
        into samples: UnsafeMutablePointer<Float>,
        frameCapacity: UInt64,
        channelCount: UInt32,
        bytesPerFrame: UInt32
    ) throws -> UInt64 {
        var totalFramesRead: UInt64 = 0
        let decodeChunkFrames: UInt64 = 32_768

        while totalFramesRead < frameCapacity {
            let remaining = frameCapacity - totalFramesRead
            var framesToRead = UInt32(min(remaining, decodeChunkFrames))
            let destination = samples.advanced(
                by: Int(totalFramesRead) * Int(channelCount)
            )
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: channelCount,
                    mDataByteSize: framesToRead * bytesPerFrame,
                    mData: destination
                )
            )

            let status = ExtAudioFileRead(file, &framesToRead, &bufferList)
            guard status == noErr else {
                throw NativePlaybackEngineError(
                    "Lossless PCM decoding failed",
                    status: status
                )
            }

            if framesToRead == 0 {
                break
            }
            totalFramesRead += UInt64(framesToRead)
        }

        guard totalFramesRead > 0 else {
            throw NativePlaybackEngineError("The selected file decoded to no PCM audio")
        }
        return totalFramesRead
    }
}
#endif
