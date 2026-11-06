//
//  AudioUnitPlaybackCore.swift
//  MusiCards
//

#if os(macOS) || os(iOS)
import AudioToolbox
import Foundation
import OSLog

enum PlaybackQualityDiagnostics {
    nonisolated static let logger = Logger(
        subsystem: "com.hildgyorgy.MusiCards",
        category: "PlaybackQuality"
    )
}

/// Serialises mutations within a decoder session. Reset ends that session;
/// its retained in-flight decoder may finish, but cannot restart current output.
@MainActor
final class AudioPlaybackOperationCoordinator {
    private enum Intent { case paused, playing }
    private struct PendingSeek {
        let revision: UInt64
        let task: Task<Void, Error>
    }
    private var pendingSeek: PendingSeek?
    private var seekRevision: UInt64 = 0
    private var playRevision: UInt64 = 0
    private var intent: Intent = .paused
    private var waitingPlayRevision: UInt64?
    private var lastStartedSeekRevision: UInt64 = 0

    var hasPendingSeek: Bool { pendingSeek != nil }

    func pause() {
        intent = .paused
        playRevision &+= 1
    }

    func reset() {
        pause()
        seekRevision &+= 1
        // A new decoder need not wait for an old decoder's cancelled I/O.
        // The old task retains its decoder until the mutation has returned.
        pendingSeek = nil
    }

    func play(prepare: () async throws -> Void = {}, start: () throws -> Void) async throws {
        intent = .playing
        playRevision &+= 1
        let revision = playRevision
        waitingPlayRevision = revision
        defer {
            if waitingPlayRevision == revision { waitingPlayRevision = nil }
        }
        do {
            try await waitForPendingSeeks(playRevision: revision)
            guard intent == .playing, revision == playRevision else { throw CancellationError() }
            let seekBeforePreparation = seekRevision
            do {
                try await prepare()
            } catch is CancellationError where !Task.isCancelled
                && revision == playRevision && intent == .playing
                && seekRevision != seekBeforePreparation {
                // A newer user seek superseded the implicit rewind used by
                // replay. Preserve Play intent and wait for that newer seek.
            }
            try await waitForPendingSeeks(playRevision: revision)
            try Task.checkCancellation()
            guard intent == .playing, revision == playRevision else { throw CancellationError() }
            try start()
            lastStartedSeekRevision = seekRevision
        } catch {
            if revision == playRevision { pause() }
            throw error
        }
    }

    func seek(
        operation: @escaping @Sendable () async throws -> Void,
        resume: () throws -> Void
    ) async throws {
        seekRevision &+= 1
        let revision = seekRevision
        let previous = pendingSeek?.task
        let task = Task {
            _ = try? await previous?.value
            try Task.checkCancellation()
            guard revision == self.seekRevision else { throw CancellationError() }
            try await operation()
        }
        pendingSeek = PendingSeek(revision: revision, task: task)
        do {
            try await task.value
            clearPending(revision: revision)
            guard revision == seekRevision else { throw CancellationError() }
            try Task.checkCancellation()
            if intent == .playing, waitingPlayRevision == nil,
               lastStartedSeekRevision != revision {
                try resume()
                lastStartedSeekRevision = revision
            }
        } catch {
            clearPending(revision: revision)
            guard revision == seekRevision else { throw CancellationError() }
            pause()
            throw error
        }
    }

    private func clearPending(revision: UInt64) {
        if pendingSeek?.revision == revision { pendingSeek = nil }
    }

    private func waitForPendingSeeks(playRevision revision: UInt64) async throws {
        while let pending = pendingSeek {
            try await pending.task.value
            clearPending(revision: pending.revision)
            try Task.checkCancellation()
            guard intent == .playing, revision == playRevision else { throw CancellationError() }
        }
    }
}

/// Narrow hardware boundary: tests can drive the actual core with an inert
/// output unit, including delayed decoder operations and disposal ordering.
@MainActor
protocol AudioUnitOutputDriving {
    func start(_ unit: AudioUnit) -> OSStatus
    func stop(_ unit: AudioUnit) -> OSStatus
    func dispose(_ unit: AudioUnit)
}

@MainActor
private struct SystemAudioUnitOutputDriver: AudioUnitOutputDriving {
    func start(_ unit: AudioUnit) -> OSStatus { AudioOutputUnitStart(unit) }
    func stop(_ unit: AudioUnit) -> OSStatus { AudioOutputUnitStop(unit) }
    func dispose(_ unit: AudioUnit) {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }
}

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
    private var minimumBufferedFrames: UInt64?
    private var nextQualityReportAt: UInt64 = 0
    private var currentSeekCapability: PlaybackSeekCapability = .supported
    private let operations = AudioPlaybackOperationCoordinator()
    private let outputDriver: any AudioUnitOutputDriving
    private var signalMeteringEnabled = false

    init(outputDriver: (any AudioUnitOutputDriving)? = nil) {
        self.outputDriver = outputDriver ?? SystemAudioUnitOutputDriver()
    }

    var canSeek: Bool {
        currentSeekCapability.isSupported
    }

    func setSignalMeteringEnabled(_ enabled: Bool) {
        signalMeteringEnabled = enabled
        if let decodedPCM {
            MCPPCMRendererSetSignalMeteringEnabled(decodedPCM.renderer, enabled)
            if enabled { eventHandler?(.signalLevelsChanged(.silence)) }
        }
    }

    func beginPreparation(
        beforeStopping: () -> Void = {}
    ) async throws -> UInt64 {
        operations.reset()
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
                    let isFLAC = asset.suffix?.lowercased() == "flac"
                        || asset.contentType?.lowercased()
                            .hasPrefix("audio/flac") == true
                        || asset.contentType?.lowercased()
                            .hasPrefix("audio/x-flac") == true
#if DEBUG
                    RemotePlaybackDiagnostics.logger.notice(
                        "Remote decoder selection codec=\(isFLAC ? "FLAC" : "ALAC", privacy: .public) backend=\(isFLAC ? "libFLAC" : "ExtAudioFile", privacy: .public) seek=supported"
                    )
#endif
                    if isFLAC {
                        return try LibFLACRemoteAudioDecoder.decode(
                            asset: asset,
                            byteSource: byteSource
                        )
                    } else {
                        return try RemoteAudioFileDecoder.decode(
                            asset: asset,
                            byteSource: byteSource
                        )
                    }
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
        seekCapability: PlaybackSeekCapability,
        audioFormatHint: PlaybackAudioFormat?
    ) {
        self.decodedPCM = decodedPCM
        MCPPCMRendererSetSignalMeteringEnabled(decodedPCM.renderer, signalMeteringEnabled)
        currentSeekCapability = decodedPCM.seekCapabilityOverride
            ?? seekCapability
        reportedUnderrunCount = 0
        #if DEBUG
        if decodedPCM.isRemote {
            RemotePlaybackDiagnostics.logger.notice(
                "Remote prepare completed; decoder session is recoverable"
            )
        }
        #endif
        let audioFormat = decodedPCM.sourceCodec.map { codec in
            PlaybackAudioFormat(
                codec: codec,
                bitDepth: decodedPCM.sourceBitDepth
                    ?? audioFormatHint?.bitDepth,
                sampleRate: decodedPCM.sampleRate,
                bitrate: audioFormatHint?.bitrate,
                channelCount: Int(decodedPCM.channelCount)
            )
        } ?? audioFormatHint
        eventHandler?(.prepared(
            duration: duration(of: decodedPCM),
            audioFormat: audioFormat
        ))
        if signalMeteringEnabled { eventHandler?(.signalLevelsChanged(.silence)) }
    }

    func pause() {
        operations.pause()
        guard let decodedPCM else { return }
        MCPPCMRendererSetPlaying(decodedPCM.renderer, false)
        stopOutputUnit()
        cancelProgressUpdates()
        eventHandler?(.paused)
    }

    func stop(beforeStopping: () -> Void = {}) async {
        operations.reset()
        preparationGeneration &+= 1
        let generation = preparationGeneration
        preparingRemoteByteSource?.cancel()
        preparingRemoteByteSource = nil
        beforeStopping()
        await stopPlayback()
        guard generation == preparationGeneration else { return }
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
        resumePlayback: () throws -> Void
    ) async throws {
        guard position.isFinite else {
            throw NativePlaybackEngineError("The playback position must be finite")
        }
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
        let boundedFrame = !requestedFrame.isFinite || requestedFrame >= Double(decodedPCM.frameCount)
            ? decodedPCM.frameCount : UInt64(max(requestedFrame, 0))
        MCPPCMRendererSetPlaying(decodedPCM.renderer, false)
        stopOutputUnit()
        do {
            try await operations.seek(operation: {
                try await Task.detached(priority: .userInitiated) {
                    try decodedPCM.seek(to: boundedFrame)
                }.value
            }, resume: {
                guard self.isCurrent(decodedPCM, generation: generation) else {
                    throw CancellationError()
                }
                try resumePlayback()
            })
        } catch {
            if !(error is CancellationError), isCurrent(decodedPCM, generation: generation) {
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
        eventHandler?(
            .positionChanged(Double(boundedFrame) / decodedPCM.sampleRate)
        )
    }

    func play(startOutput: () throws -> Void) async throws {
        try await operations.play(prepare: {
            if let decodedPCM = self.decodedPCM,
               MCPPCMRendererDidFinish(decodedPCM.renderer),
               !self.operations.hasPendingSeek {
                try await self.seek(to: 0, resumePlayback: {})
            }
        }, start: startOutput)
    }

    func installOutputUnit(_ outputUnit: AudioUnit) {
        self.outputUnit = outputUnit
    }

    func startOutputUnit(
        _ outputUnit: AudioUnit,
        failureMessage: String
    ) throws {
        guard !isOutputRunning else { return }
        let status = outputDriver.start(outputUnit)
        guard status == noErr else {
            PlaybackQualityDiagnostics.logger.error(
                "Audio output start failed status=\(status, privacy: .public) remote=\(self.decodedPCM?.isRemote ?? false, privacy: .public)"
            )
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
        _ = outputDriver.stop(outputUnit)
        isOutputRunning = false
    }

    func disposeOutputUnit() {
        stopOutputUnit()
        if let outputUnit {
            outputDriver.dispose(outputUnit)
        }
        outputUnit = nil
    }

    func suspendOutputForLifecycleEvent(preservePlaybackIntent: Bool = false) {
        if !preservePlaybackIntent { operations.pause() }
        if let decodedPCM {
            MCPPCMRendererSetPlaying(decodedPCM.renderer, false)
        }
        stopOutputUnit()
        cancelProgressUpdates()
        if signalMeteringEnabled { eventHandler?(.signalLevelsChanged(.silence)) }
    }

    func startProgressUpdates() {
        cancelProgressUpdates()
        minimumBufferedFrames = nil
        nextQualityReportAt = DispatchTime.now().uptimeNanoseconds
            + 15_000_000_000
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, let decodedPCM = self.decodedPCM else {
                    return
                }

                if let error = decodedPCM.takeFeederError() {
                    PlaybackQualityDiagnostics.logger.error(
                        "PCM feeder failed remote=\(decodedPCM.isRemote, privacy: .public)"
                    )
                    self.stopOutputUnit()
                    self.eventHandler?(.failed(PlaybackFailure(error)))
                    return
                }

                let frame = MCPPCMRendererCurrentFrame(decodedPCM.renderer)
                self.eventHandler?(
                    .positionChanged(Double(frame) / decodedPCM.sampleRate)
                )
                guard self.decodedPCM === decodedPCM,
                      !Task.isCancelled else { return }

                if self.signalMeteringEnabled {
                    let signal = MCPPCMRendererSignalLevels(decodedPCM.renderer)
                    self.eventHandler?(.signalLevelsChanged(PlaybackSignalLevels(
                        left: Double(signal.left), right: Double(signal.right)
                    )))
                }

                let underrunCount = MCPPCMRendererUnderrunCount(
                    decodedPCM.renderer
                )
                if underrunCount > self.reportedUnderrunCount {
                    self.reportedUnderrunCount = underrunCount
                    PlaybackQualityDiagnostics.logger.warning(
                        "PCM buffer underrun count=\(underrunCount, privacy: .public) remote=\(decodedPCM.isRemote, privacy: .public)"
                    )
                }

                if MCPPCMRendererDidFinish(decodedPCM.renderer) {
                    self.stopOutputUnit()
                    self.eventHandler?(.finished)
                    return
                }

                let bufferedFrames = decodedPCM.bufferedFrames
                self.minimumBufferedFrames = min(
                    self.minimumBufferedFrames ?? bufferedFrames,
                    bufferedFrames
                )
                let now = DispatchTime.now().uptimeNanoseconds
                if now >= self.nextQualityReportAt {
                    self.reportPlaybackQuality(
                        decodedPCM,
                        bufferedFrames: bufferedFrames,
                        underrunCount: underrunCount
                    )
                    self.minimumBufferedFrames = nil
                    self.nextQualityReportAt = now + 15_000_000_000
                }
            }
        }
    }

    private func reportPlaybackQuality(
        _ decodedPCM: DecodedPCM,
        bufferedFrames: UInt64,
        underrunCount: UInt64
    ) {
        let bufferedNowMilliseconds = Int(
            Double(bufferedFrames) * 1_000 / decodedPCM.sampleRate
        )
        let bufferedMinimumMilliseconds = Int(
            Double(minimumBufferedFrames ?? bufferedFrames) * 1_000
                / decodedPCM.sampleRate
        )
        let feeder = decodedPCM.takeFeederQualityDiagnostics()
        PlaybackQualityDiagnostics.logger.notice(
            "PCM quality remote=\(decodedPCM.isRemote, privacy: .public) bufferNowMs=\(bufferedNowMilliseconds, privacy: .public) bufferMinMs=\(bufferedMinimumMilliseconds, privacy: .public) underruns=\(underrunCount, privacy: .public) feederReads=\(feeder.readCount, privacy: .public) feederMaxMs=\(feeder.maximumReadMilliseconds, privacy: .public) feederSlow100ms=\(feeder.slowReadCount, privacy: .public)"
        )
        if let network = decodedPCM.remoteByteSource?.takeQualityDiagnostics() {
            PlaybackQualityDiagnostics.logger.notice(
                "Range quality requests=\(network.completedCount, privacy: .public) minMs=\(network.minimumMilliseconds, privacy: .public) avgMs=\(network.averageMilliseconds, privacy: .public) maxMs=\(network.maximumMilliseconds, privacy: .public) slow500ms=\(network.slowCount, privacy: .public) failures=\(network.failureCount, privacy: .public) inFlight=\(network.inFlightCount, privacy: .public)"
            )
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
