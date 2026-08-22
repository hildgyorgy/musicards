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
    var eventHandler: ((PlaybackEngineEvent) -> Void)? {
        get { core.eventHandler }
        set { core.eventHandler = newValue }
    }

    private let core = AudioUnitPlaybackCore()
    private var originalSampleRates: [AudioDeviceID: Float64] = [:]
    private var configuredOutputDeviceID: AudioDeviceID?

    func prepare(_ item: PlaybackQueueItem) async throws {
        let generation = try await core.beginPreparation()
        let decodedPCM = try await core.decode(item, generation: generation)

        matchDefaultOutputSampleRate(decodedPCM.sampleRate)
        try configureOutputUnit(for: decodedPCM)
        core.completePreparation(
            decodedPCM: decodedPCM,
            seekCapability: item.source.seekCapability
        )
    }

    func play() async throws {
        guard let decodedPCM = core.decodedPCM else {
            throw NativePlaybackEngineError("No decoded track is ready")
        }
        let generation = core.preparationGeneration

        if MCPPCMRendererDidFinish(decodedPCM.renderer) {
            try await core.seekDecoder(decodedPCM, to: 0)
        }
        guard core.isCurrent(decodedPCM, generation: generation),
              let outputUnit = core.outputUnit else {
            throw CancellationError()
        }

        MCPPCMRendererSetPlaying(decodedPCM.renderer, true)
        try core.startOutputUnit(
            outputUnit,
            failureMessage: "Could not start the Mac audio output"
        )
        core.startProgressUpdates()
        eventHandler?(.started)
    }

    func pause() async {
        core.pause()
    }

    func stop() async {
        await core.stop()
    }

    func seek(to position: TimeInterval) async throws {
        try await core.seek(to: position) { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.play()
        }
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
        try AudioUnitPlaybackCore.check(
            AudioComponentInstanceNew(component, &unit),
            operation: "Could not create the Mac output Audio Unit"
        )

        guard let unit else {
            throw NativePlaybackEngineError(
                "Mac output Audio Unit creation returned no instance"
            )
        }

        do {
            try AudioUnitPlaybackCore.configureRenderPath(
                on: unit,
                for: decodedPCM,
                formatFailureMessage:
                    "Could not set the PCM format on the Mac output",
                initializationFailureMessage:
                    "Could not initialize the Mac audio output"
            )
            core.installOutputUnit(unit)
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

}
#endif
