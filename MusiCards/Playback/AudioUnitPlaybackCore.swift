//
//  AudioUnitPlaybackCore.swift
//  MusiCards
//

#if os(macOS) || os(iOS)
import AudioToolbox
import Foundation
#if DEBUG
import OSLog
#endif

/// Source-independent decoder and Audio Unit lifecycle shared by the platform
/// playback engines. Route, device, and audio-session policy remains owned by
/// the macOS and iOS engines.
@MainActor
final class AudioUnitPlaybackCore {
    var eventHandler: ((PlaybackEngineEvent) -> Void)?

    private(set) var outputUnit: AudioUnit?
    private(set) var decodedPCM: DecodedPCM?
    private(set) var isOutputRunning = false
    private(set) var preparationGeneration: UInt64 = 0

    private var preparingRemoteByteSource: HTTPRandomAccessByteSource?
    private var progressTask: Task<Void, Never>?
    private var reportedUnderrunCount: UInt64 = 0
    private var currentSeekCapability: PlaybackSeekCapability = .supported

    func beginPreparation(
        beforeStopping: () -> Void = {}
    ) async throws -> UInt64 {
        preparationGeneration &+= 1
        let generation = preparationGeneration
        beforeStopping()
        await stopPlayback()
        guard generation == preparationGeneration else {
            throw CancellationError()
        }
        disposeOutputUnit()
        disposeDecoder()
        currentSeekCapability = .supported
        return generation
    }

    func decode(
        _ item: PlaybackQueueItem,
        generation: UInt64
    ) async throws -> DecodedPCM {
        let decodedPCM: DecodedPCM
        switch item.source {
        case .localFile(let url):
            decodedPCM = try await Task.detached(priority: .userInitiated) {
                try LocalAudioFileDecoder.decode(url: url)
            }.value

        case .remoteAudio(let asset):
            #if DEBUG
            RemotePlaybackDiagnostics.logger.notice(
                "Remote prepare started codecHint=\(asset.suffix ?? "unknown", privacy: .public)"
            )
            #endif
            let byteSource = try asset.byteSourceProvider.makeByteSource()
            preparingRemoteByteSource = byteSource
            do {
                decodedPCM = try await Task.detached(
                    priority: .userInitiated
                ) {
                    try RemoteAudioFileDecoder.decode(
                        asset: asset,
                        byteSource: byteSource
                    )
                }.value
            } catch {
                if preparingRemoteByteSource === byteSource {
                    preparingRemoteByteSource = nil
                }
                byteSource.cancel()
                throw error
            }
            if preparingRemoteByteSource === byteSource {
                preparingRemoteByteSource = nil
            }

        case .libraryAsset:
            throw NativePlaybackEngineError("Unsupported audio source")
        }

        guard generation == preparationGeneration, !Task.isCancelled else {
            decodedPCM.cancel()
            throw CancellationError()
        }
        return decodedPCM
    }

    func completePreparation(
        decodedPCM: DecodedPCM,
        seekCapability: PlaybackSeekCapability
    ) {
        self.decodedPCM = decodedPCM
        currentSeekCapability = seekCapability
        reportedUnderrunCount = 0
        #if DEBUG
        if decodedPCM.isRemote {
            RemotePlaybackDiagnostics.logger.notice(
                "Remote prepare completed; decoder session is recoverable"
            )
        }
        #endif
        eventHandler?(.prepared(duration: duration(of: decodedPCM)))
    }

    func pause() {
        guard let decodedPCM else { return }
        MCPPCMRendererSetPlaying(decodedPCM.renderer, false)
        stopOutputUnit()
        cancelProgressUpdates()
        eventHandler?(.paused)
    }

    func stop(beforeStopping: () -> Void = {}) async {
        preparationGeneration &+= 1
        preparingRemoteByteSource?.cancel()
        preparingRemoteByteSource = nil
        beforeStopping()
        await stopPlayback()
        disposeOutputUnit()
        disposeDecoder()
        currentSeekCapability = .supported
    }

    func stopPlayback() async {
        if let decodedPCM {
            MCPPCMRendererSetPlaying(decodedPCM.renderer, false)
        }
        stopOutputUnit()
        cancelProgressUpdates()
    }

    func seek(
        to position: TimeInterval,
        resumePlayback: () async throws -> Void
    ) async throws {
        guard let decodedPCM else {
            throw NativePlaybackEngineError("No decoded track is ready")
        }
        guard currentSeekCapability.isSupported else {
            #if DEBUG
            RemotePlaybackDiagnostics.logger.notice(
                "Remote seek rejected by engine before decoder mutation"
            )
            #endif
            throw PlaybackSeekError.unsupported
        }
        let generation = preparationGeneration

        let requestedFrame = position * decodedPCM.sampleRate
        let boundedFrame = UInt64(
            min(max(requestedFrame, 0), Double(decodedPCM.frameCount))
        )
        let wasPlaying = isOutputRunning
        MCPPCMRendererSetPlaying(decodedPCM.renderer, false)
        stopOutputUnit()
        do {
            try await seekDecoder(decodedPCM, to: boundedFrame)
        } catch {
            if isCurrent(decodedPCM, generation: generation) {
                #if DEBUG
                RemotePlaybackDiagnostics.logger.notice(
                    "Seek failed; tearing down decoder before recovery"
                )
                #endif
                preparationGeneration &+= 1
                disposeOutputUnit()
                disposeDecoder()
                currentSeekCapability = .supported
            }
            throw error
        }
        guard isCurrent(decodedPCM, generation: generation) else {
            throw CancellationError()
        }
        if wasPlaying {
            try await resumePlayback()
        }
        eventHandler?(
            .positionChanged(Double(boundedFrame) / decodedPCM.sampleRate)
        )
    }

    func installOutputUnit(_ outputUnit: AudioUnit) {
        self.outputUnit = outputUnit
    }

    func startOutputUnit(
        _ outputUnit: AudioUnit,
        failureMessage: String
    ) throws {
        guard !isOutputRunning else { return }
        let status = AudioOutputUnitStart(outputUnit)
        guard status == noErr else {
            if let decodedPCM {
                MCPPCMRendererSetPlaying(decodedPCM.renderer, false)
            }
            throw NativePlaybackEngineError(
                failureMessage,
                status: status
            )
        }
        isOutputRunning = true
    }

    func stopOutputUnit() {
        guard isOutputRunning, let outputUnit else { return }
        AudioOutputUnitStop(outputUnit)
        isOutputRunning = false
    }

    func disposeOutputUnit() {
        stopOutputUnit()
        if let outputUnit {
            AudioUnitUninitialize(outputUnit)
            AudioComponentInstanceDispose(outputUnit)
        }
        outputUnit = nil
    }

    func suspendOutputForLifecycleEvent() {
        if let decodedPCM {
            MCPPCMRendererSetPlaying(decodedPCM.renderer, false)
        }
        stopOutputUnit()
        cancelProgressUpdates()
    }

    func startProgressUpdates() {
        cancelProgressUpdates()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, let decodedPCM = self.decodedPCM else {
                    return
                }

                if let error = decodedPCM.takeFeederError() {
                    self.stopOutputUnit()
                    self.eventHandler?(.failed(PlaybackFailure(error)))
                    return
                }

                let frame = MCPPCMRendererCurrentFrame(decodedPCM.renderer)
                self.eventHandler?(
                    .positionChanged(Double(frame) / decodedPCM.sampleRate)
                )

                #if DEBUG
                let underrunCount = MCPPCMRendererUnderrunCount(
                    decodedPCM.renderer
                )
                if decodedPCM.isRemote,
                   underrunCount > self.reportedUnderrunCount {
                    self.reportedUnderrunCount = underrunCount
                    RemotePlaybackDiagnostics.logger.notice(
                        "Remote PCM underrun count=\(underrunCount, privacy: .public); outputting bounded silence while decoding refills"
                    )
                }
                #endif

                if MCPPCMRendererDidFinish(decodedPCM.renderer) {
                    self.stopOutputUnit()
                    self.eventHandler?(.finished)
                    return
                }
            }
        }
    }

    func disposeDecoder() {
        #if DEBUG
        if decodedPCM?.isRemote == true {
            RemotePlaybackDiagnostics.logger.notice(
                "Remote decoder teardown requested"
            )
        }
        #endif
        decodedPCM?.cancel()
        decodedPCM = nil
    }

    func duration(of decodedPCM: DecodedPCM) -> TimeInterval {
        Double(decodedPCM.frameCount) / decodedPCM.sampleRate
    }

    func isCurrent(
        _ decodedPCM: DecodedPCM,
        generation: UInt64
    ) -> Bool {
        generation == preparationGeneration && self.decodedPCM === decodedPCM
    }

    func seekDecoder(
        _ decodedPCM: DecodedPCM,
        to frame: UInt64
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try decodedPCM.seek(to: frame)
        }.value
    }

    static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw NativePlaybackEngineError(operation, status: status)
        }
    }

    static func configureRenderPath(
        on outputUnit: AudioUnit,
        for decodedPCM: DecodedPCM,
        formatFailureMessage: String,
        initializationFailureMessage: String
    ) throws {
        var format = AudioStreamBasicDescription(
            mSampleRate: decodedPCM.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: decodedPCM.channelCount
                * UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: decodedPCM.channelCount
                * UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: decodedPCM.channelCount,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        try withUnsafePointer(to: &format) { pointer in
            try check(
                AudioUnitSetProperty(
                    outputUnit,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Input,
                    0,
                    pointer,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                ),
                operation: formatFailureMessage
            )
        }

        var callback = AURenderCallbackStruct(
            inputProc: MCPPCMRenderCallback,
            inputProcRefCon: UnsafeMutableRawPointer(decodedPCM.renderer)
        )
        try withUnsafePointer(to: &callback) { pointer in
            try check(
                AudioUnitSetProperty(
                    outputUnit,
                    kAudioUnitProperty_SetRenderCallback,
                    kAudioUnitScope_Input,
                    0,
                    pointer,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                ),
                operation: "Could not install the realtime PCM renderer"
            )
        }

        try check(
            AudioUnitInitialize(outputUnit),
            operation: initializationFailureMessage
        )
    }

    private func cancelProgressUpdates() {
        progressTask?.cancel()
        progressTask = nil
    }
}
#endif
