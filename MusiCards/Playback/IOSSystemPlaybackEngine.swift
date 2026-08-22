//
//  IOSSystemPlaybackEngine.swift
//  MusiCards
//

#if os(iOS)
import AudioToolbox
import AVFAudio
import Foundation

@MainActor
final class IOSSystemPlaybackEngine: NSObject, PlaybackEngine {
    var eventHandler: ((PlaybackEngineEvent) -> Void)? {
        get { core.eventHandler }
        set { core.eventHandler = newValue }
    }

    private let core = AudioUnitPlaybackCore()
    private var isInterrupted = false
    private var isRouteDisconnectInterruption = false
    private var shouldResumeAfterInterruption = false
    private var needsOutputRebuildAfterInterruption = false
    private var resumeBlockedByRouteDisconnect = false
    override init() {
        super.init()

        let notificationCenter = NotificationCenter.default
        let audioSession = AVAudioSession.sharedInstance()
        notificationCenter.addObserver(
            self,
            selector: #selector(receiveAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: audioSession
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(receiveAudioRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: audioSession
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func prepare(_ item: PlaybackQueueItem) async throws {
        let generation = try await core.beginPreparation {
            self.shouldResumeAfterInterruption = false
            self.resumeBlockedByRouteDisconnect = false
        }
        let decodedPCM = try await core.decode(item, generation: generation)

        try configureAudioSession(sourceSampleRate: decodedPCM.sampleRate)
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

        if isInterrupted, isRouteDisconnectInterruption {
            try recoverFromRouteDisconnectInterruption()
        }

        guard !isInterrupted else {
            throw NativePlaybackEngineError("Audio is temporarily interrupted")
        }
        guard let outputUnit = core.outputUnit else {
            throw NativePlaybackEngineError("No iPhone audio output is ready")
        }

        resumeBlockedByRouteDisconnect = false
        try activateAudioSession()

        if MCPPCMRendererDidFinish(decodedPCM.renderer) {
            try await core.seekDecoder(decodedPCM, to: 0)
        }
        guard core.isCurrent(decodedPCM, generation: generation) else {
            throw CancellationError()
        }

        MCPPCMRendererSetPlaying(decodedPCM.renderer, true)
        try core.startOutputUnit(
            outputUnit,
            failureMessage: "Could not start the iPhone audio output"
        )
        core.startProgressUpdates()
        eventHandler?(.started)
    }

    func pause() async {
        shouldResumeAfterInterruption = false
        core.pause()
    }

    func stop() async {
        await core.stop {
            self.shouldResumeAfterInterruption = false
            self.resumeBlockedByRouteDisconnect = false
        }
    }

    func seek(to position: TimeInterval) async throws {
        try await core.seek(to: position) { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.play()
        }
    }

    private func configureAudioSession(sourceSampleRate: Double) throws {
        let session = AVAudioSession.sharedInstance()

        do {
            try session.setCategory(.playback, mode: .default)
            try session.setPreferredSampleRate(sourceSampleRate)
            // MusiCards handles disconnects explicitly so it can pause before
            // audio unexpectedly falls back to the iPhone speaker.
            try session.setPrefersInterruptionOnRouteDisconnect(false)
            try session.setActive(true)
        } catch {
            throw NativePlaybackEngineError(
                "Could not configure the iPhone audio route: \(error.localizedDescription)"
            )
        }
    }

    private func activateAudioSession() throws {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            throw NativePlaybackEngineError(
                "Could not activate the iPhone audio route: \(error.localizedDescription)"
            )
        }
    }

    private func configureOutputUnit(for decodedPCM: DecodedPCM) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_RemoteIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw NativePlaybackEngineError(
                "The iPhone RemoteIO Audio Unit is unavailable"
            )
        }

        var unit: AudioUnit?
        try AudioUnitPlaybackCore.check(
            AudioComponentInstanceNew(component, &unit),
            operation: "Could not create the iPhone output Audio Unit"
        )

        guard let unit else {
            throw NativePlaybackEngineError(
                "iPhone output Audio Unit creation returned no instance"
            )
        }

        do {
            var outputEnabled: UInt32 = 1
            try AudioUnitPlaybackCore.check(
                AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_EnableIO,
                    kAudioUnitScope_Output,
                    0,
                    &outputEnabled,
                    UInt32(MemoryLayout<UInt32>.size)
                ),
                operation: "Could not enable the iPhone audio output"
            )

            try AudioUnitPlaybackCore.configureRenderPath(
                on: unit,
                for: decodedPCM,
                formatFailureMessage:
                    "Could not set the PCM format on the iPhone output",
                initializationFailureMessage:
                    "Could not initialize the iPhone audio output"
            )
            core.installOutputUnit(unit)
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    private func suspendOutputForLifecycleEvent() {
        core.suspendOutputForLifecycleEvent()
    }

    private func rebuildOutput(resumeWhenReady: Bool) async {
        do {
            try reconfigureOutput()

            if resumeWhenReady, !isInterrupted {
                try await play()
            }
        } catch {
            eventHandler?(.failed(PlaybackFailure(error)))
        }
    }

    private func reconfigureOutput() throws {
        guard let decodedPCM = core.decodedPCM else {
            throw NativePlaybackEngineError("No decoded track is ready")
        }

        suspendOutputForLifecycleEvent()
        core.disposeOutputUnit()
        try configureAudioSession(sourceSampleRate: decodedPCM.sampleRate)
        try configureOutputUnit(for: decodedPCM)
    }

    private func recoverFromRouteDisconnectInterruption() throws {
        isInterrupted = false
        isRouteDisconnectInterruption = false
        shouldResumeAfterInterruption = false
        needsOutputRebuildAfterInterruption = false
        resumeBlockedByRouteDisconnect = false
        try reconfigureOutput()
    }

    @objc
    nonisolated private func receiveAudioSessionInterruption(
        _ notification: Notification
    ) {
        let typeValue = (
            notification.userInfo?[AVAudioSessionInterruptionTypeKey]
                as? NSNumber
        )?.uintValue
        let optionsValue = (
            notification.userInfo?[AVAudioSessionInterruptionOptionKey]
                as? NSNumber
        )?.uintValue ?? 0

        guard let typeValue else { return }

        Task { @MainActor [weak self] in
            await self?.handleAudioSessionInterruption(
                typeValue: typeValue,
                optionsValue: optionsValue
            )
        }
    }

    @objc
    nonisolated private func receiveAudioRouteChange(
        _ notification: Notification
    ) {
        let reasonValue = (
            notification.userInfo?[AVAudioSessionRouteChangeReasonKey]
                as? NSNumber
        )?.uintValue

        guard let reasonValue else { return }

        Task { @MainActor [weak self] in
            await self?.handleAudioRouteChange(reasonValue: reasonValue)
        }
    }

    private func handleAudioSessionInterruption(
        typeValue: UInt,
        optionsValue: UInt
    ) async {
        guard let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else {
            return
        }

        switch type {
        case .began:
            guard !isInterrupted else { return }

            isInterrupted = true
            isRouteDisconnectInterruption = resumeBlockedByRouteDisconnect
            shouldResumeAfterInterruption = core.isOutputRunning
            suspendOutputForLifecycleEvent()

            if shouldResumeAfterInterruption {
                eventHandler?(.paused)
            }

        case .ended:
            guard isInterrupted else { return }

            isInterrupted = false
            let options = AVAudioSession.InterruptionOptions(
                rawValue: optionsValue
            )
            let shouldResume = shouldResumeAfterInterruption
                && options.contains(.shouldResume)
                && !resumeBlockedByRouteDisconnect

            shouldResumeAfterInterruption = false
            isRouteDisconnectInterruption = false
            resumeBlockedByRouteDisconnect = false

            if needsOutputRebuildAfterInterruption {
                needsOutputRebuildAfterInterruption = false
                await rebuildOutput(resumeWhenReady: shouldResume)
            } else if shouldResume {
                do {
                    try await play()
                } catch {
                    eventHandler?(.failed(PlaybackFailure(error)))
                }
            }

        @unknown default:
            return
        }
    }

    private func handleAudioRouteChange(reasonValue: UInt) async {
        guard let reason = AVAudioSession.RouteChangeReason(
            rawValue: reasonValue
        ), core.decodedPCM != nil else {
            return
        }

        switch reason {
        case .oldDeviceUnavailable:
            resumeBlockedByRouteDisconnect = true

            if isInterrupted {
                isRouteDisconnectInterruption = true
                needsOutputRebuildAfterInterruption = true
                return
            }

            let wasPlaying = core.isOutputRunning
            await rebuildOutput(resumeWhenReady: false)
            if wasPlaying {
                eventHandler?(.paused)
            }

        case .newDeviceAvailable, .routeConfigurationChange:
            if isInterrupted {
                if isRouteDisconnectInterruption {
                    do {
                        try recoverFromRouteDisconnectInterruption()
                    } catch {
                        eventHandler?(.failed(PlaybackFailure(error)))
                    }
                    return
                }

                needsOutputRebuildAfterInterruption = true
                return
            }

            let wasPlaying = core.isOutputRunning
            await rebuildOutput(resumeWhenReady: wasPlaying)

        default:
            return
        }
    }

}
#endif
