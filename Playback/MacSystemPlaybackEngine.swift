//
//  MacSystemPlaybackEngine.swift
//  MusiCards
//

#if os(macOS)
import AudioToolbox
import CoreAudio
import Foundation

@MainActor
final class MacSystemPlaybackEngine: PlaybackEngine {
    var eventHandler: ((PlaybackEngineEvent) -> Void)?

    private var outputUnit: AudioUnit?
    private var decodedPCM: DecodedPCM?
    private var progressTask: Task<Void, Never>?
    private var isOutputRunning = false
    private var preparationGeneration: UInt64 = 0
    private var originalSampleRates: [AudioDeviceID: Float64] = [:]
    private var configuredOutputDeviceID: AudioDeviceID?

    func prepare(_ item: PlaybackQueueItem) async throws {
        guard case .localFile(let url) = item.source else {
            throw NativePlaybackEngineError("Unsupported audio source")
        }

        preparationGeneration &+= 1
        let generation = preparationGeneration
        await stopPlayback()
        guard generation == preparationGeneration else {
            throw CancellationError()
        }
        disposeOutputUnit()
        decodedPCM = nil

        let decodedPCM = try await Task.detached(priority: .userInitiated) {
            try LocalAudioFileDecoder.decode(url: url)
        }.value
        guard generation == preparationGeneration, !Task.isCancelled else {
            throw CancellationError()
        }

        matchDefaultOutputSampleRate(decodedPCM.sampleRate)
        try configureOutputUnit(for: decodedPCM)
        self.decodedPCM = decodedPCM
        eventHandler?(.prepared(duration: duration(of: decodedPCM)))
    }

    func play() async throws {
        guard let decodedPCM else {
            throw NativePlaybackEngineError("No decoded track is ready")
        }
        let generation = preparationGeneration

        if MCPPCMRendererDidFinish(decodedPCM.renderer) {
            try await seekDecoder(decodedPCM, to: 0)
        }
        guard isCurrent(decodedPCM, generation: generation),
              let outputUnit else {
            throw CancellationError()
        }

        MCPPCMRendererSetPlaying(decodedPCM.renderer, true)

        if !isOutputRunning {
            let status = AudioOutputUnitStart(outputUnit)
            guard status == noErr else {
                MCPPCMRendererSetPlaying(decodedPCM.renderer, false)
                throw NativePlaybackEngineError(
                    "Could not start the Mac audio output",
                    status: status
                )
            }
            isOutputRunning = true
        }

        startProgressUpdates()
        eventHandler?(.started)
    }

    func pause() async {
        guard let decodedPCM else { return }
        MCPPCMRendererSetPlaying(decodedPCM.renderer, false)
        stopOutputUnit()
        progressTask?.cancel()
        progressTask = nil
        eventHandler?(.paused)
    }

    func stop() async {
        preparationGeneration &+= 1
        await stopPlayback()
    }

    private func stopPlayback() async {
        if let decodedPCM {
            MCPPCMRendererSetPlaying(decodedPCM.renderer, false)
        }

        stopOutputUnit()
        progressTask?.cancel()
        progressTask = nil
        if let decodedPCM {
            try? await seekDecoder(decodedPCM, to: 0)
        }
    }

    func seek(to position: TimeInterval) async throws {
        guard let decodedPCM else {
            throw NativePlaybackEngineError("No decoded track is ready")
        }
        let generation = preparationGeneration

        let requestedFrame = position * decodedPCM.sampleRate
        let boundedFrame = UInt64(
            min(max(requestedFrame, 0), Double(decodedPCM.frameCount))
        )
        let wasPlaying = isOutputRunning
        MCPPCMRendererSetPlaying(decodedPCM.renderer, false)
        stopOutputUnit()
        try await seekDecoder(decodedPCM, to: boundedFrame)
        guard isCurrent(decodedPCM, generation: generation) else {
            throw CancellationError()
        }
        if wasPlaying {
            try await play()
        }
        eventHandler?(
            .positionChanged(Double(boundedFrame) / decodedPCM.sampleRate)
        )
    }

    func restoreOutputConfiguration() {
        let savedRates = originalSampleRates
        var ratesStillToRestore: [AudioDeviceID: Float64] = [:]

        for (deviceID, originalRate) in savedRates {
            if !setNominalSampleRate(originalRate, for: deviceID) {
                ratesStillToRestore[deviceID] = originalRate
            }
        }

        originalSampleRates = ratesStillToRestore
        configuredOutputDeviceID = nil
    }

    private func configureOutputUnit(for decodedPCM: DecodedPCM) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_DefaultOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw NativePlaybackEngineError(
                "Mac default output Audio Unit is unavailable"
            )
        }

        var unit: AudioUnit?
        try check(
            AudioComponentInstanceNew(component, &unit),
            operation: "Could not create the Mac output Audio Unit"
        )

        guard let unit else {
            throw NativePlaybackEngineError(
                "Mac output Audio Unit creation returned no instance"
            )
        }

        do {
            var format = AudioStreamBasicDescription(
                mSampleRate: decodedPCM.sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: decodedPCM.channelCount * UInt32(MemoryLayout<Float>.size),
                mFramesPerPacket: 1,
                mBytesPerFrame: decodedPCM.channelCount * UInt32(MemoryLayout<Float>.size),
                mChannelsPerFrame: decodedPCM.channelCount,
                mBitsPerChannel: 32,
                mReserved: 0
            )

            try withUnsafePointer(to: &format) { pointer in
                try check(
                    AudioUnitSetProperty(
                        unit,
                        kAudioUnitProperty_StreamFormat,
                        kAudioUnitScope_Input,
                        0,
                        pointer,
                        UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                    ),
                    operation: "Could not set the PCM format on the Mac output"
                )
            }

            var callback = AURenderCallbackStruct(
                inputProc: {
                    refCon,
                    actionFlags,
                    timeStamp,
                    busNumber,
                    frameCount,
                    outputData in
                    MCPPCMRenderCallback(
                        refCon,
                        actionFlags,
                        timeStamp,
                        busNumber,
                        frameCount,
                        outputData
                    )
                },
                inputProcRefCon: UnsafeMutableRawPointer(decodedPCM.renderer)
            )

            try withUnsafePointer(to: &callback) { pointer in
                try check(
                    AudioUnitSetProperty(
                        unit,
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
                AudioUnitInitialize(unit),
                operation: "Could not initialize the Mac audio output"
            )
            outputUnit = unit
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    private func matchDefaultOutputSampleRate(_ sampleRate: Double) {
        let route = AudioOutputRouteInspector.current()
        guard let rawDeviceID = route.deviceID else {
            return
        }
        let deviceID = AudioDeviceID(rawDeviceID)

        if let configuredOutputDeviceID,
           configuredOutputDeviceID != deviceID {
            restoreSampleRate(for: configuredOutputDeviceID)
        }

        guard route.transport.allowsDeviceSampleRateMatching else {
            restoreSampleRate(for: deviceID)
            configuredOutputDeviceID = nil
            return
        }

        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isSettable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(
            deviceID,
            &rateAddress,
            &isSettable
        ) == noErr,
        isSettable.boolValue else {
            return
        }

        var currentRate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &rateAddress,
            0,
            nil,
            &size,
            &currentRate
        ) == noErr else {
            return
        }

        configuredOutputDeviceID = deviceID

        guard abs(currentRate - sampleRate) > 0.5 else {
            return
        }

        if setNominalSampleRate(sampleRate, for: deviceID),
           originalSampleRates[deviceID] == nil {
            originalSampleRates[deviceID] = currentRate
        }
    }

    private func restoreSampleRate(for deviceID: AudioDeviceID) {
        guard let originalRate = originalSampleRates[deviceID] else { return }
        if setNominalSampleRate(originalRate, for: deviceID) {
            originalSampleRates.removeValue(forKey: deviceID)
        }
    }

    @discardableResult
    private func setNominalSampleRate(
        _ sampleRate: Float64,
        for deviceID: AudioDeviceID
    ) -> Bool {
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isSettable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(
            deviceID,
            &rateAddress,
            &isSettable
        ) == noErr,
        isSettable.boolValue else {
            return false
        }

        var requestedRate = sampleRate
        return AudioObjectSetPropertyData(
            deviceID,
            &rateAddress,
            0,
            nil,
            UInt32(MemoryLayout<Float64>.size),
            &requestedRate
        ) == noErr
    }

    private func startProgressUpdates() {
        progressTask?.cancel()
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

                if MCPPCMRendererDidFinish(decodedPCM.renderer) {
                    self.stopOutputUnit()
                    self.eventHandler?(.finished)
                    return
                }
            }
        }
    }

    private func stopOutputUnit() {
        guard isOutputRunning, let outputUnit else { return }
        AudioOutputUnitStop(outputUnit)
        isOutputRunning = false
    }

    private func disposeOutputUnit() {
        stopOutputUnit()
        if let outputUnit {
            AudioUnitUninitialize(outputUnit)
            AudioComponentInstanceDispose(outputUnit)
        }
        outputUnit = nil
    }

    private func duration(of decodedPCM: DecodedPCM) -> TimeInterval {
        Double(decodedPCM.frameCount) / decodedPCM.sampleRate
    }

    private func isCurrent(
        _ decodedPCM: DecodedPCM,
        generation: UInt64
    ) -> Bool {
        generation == preparationGeneration && self.decodedPCM === decodedPCM
    }

    private func seekDecoder(
        _ decodedPCM: DecodedPCM,
        to frame: UInt64
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try decodedPCM.seek(to: frame)
        }.value
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw NativePlaybackEngineError(operation, status: status)
        }
    }
}
#endif
