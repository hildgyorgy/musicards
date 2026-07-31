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
    var eventHandler: ((PlaybackEngineEvent) -> Void)?

    private var outputUnit: AudioUnit?
    private var decodedPCM: DecodedPCM?
    private var progressTask: Task<Void, Never>?
    private var isOutputRunning = false
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
        guard case .localFile(let url) = item.source else {
            throw NativePlaybackEngineError("Unsupported audio source")
        }

        await stop()
        disposeOutputUnit()
        decodedPCM = nil

        let decodedPCM = try await Task.detached(priority: .userInitiated) {
            try LocalAudioFileDecoder.decode(url: url)
        }.value

        try configureAudioSession(sourceSampleRate: decodedPCM.sampleRate)
        try configureOutputUnit(for: decodedPCM)
        self.decodedPCM = decodedPCM
        eventHandler?(.prepared(duration: duration(of: decodedPCM)))
    }

    func play() async throws {
        guard let decodedPCM else {
            throw NativePlaybackEngineError("No decoded track is ready")
        }

        if isInterrupted, isRouteDisconnectInterruption {
            try recoverFromRouteDisconnectInterruption()
        }

        guard !isInterrupted else {
            throw NativePlaybackEngineError("Audio is temporarily interrupted")
        }
        guard let outputUnit else {
            throw NativePlaybackEngineError("No iPhone audio output is ready")
        }

        resumeBlockedByRouteDisconnect = false
        try activateAudioSession()

        if MCPPCMRendererDidFinish(decodedPCM.renderer) {
            MCPPCMRendererSeek(decodedPCM.renderer, 0)
        }

        MCPPCMRendererSetPlaying(decodedPCM.renderer, true)

        if !isOutputRunning {
            let status = AudioOutputUnitStart(outputUnit)
            guard status == noErr else {
                MCPPCMRendererSetPlaying(decodedPCM.renderer, false)
                throw NativePlaybackEngineError(
                    "Could not start the iPhone audio output",
                    status: status
                )
            }
            isOutputRunning = true
        }

        startProgressUpdates()
        eventHandler?(.started)
    }

    func pause() async {
        shouldResumeAfterInterruption = false
        guard let decodedPCM else { return }
        MCPPCMRendererSetPlaying(decodedPCM.renderer, false)
        stopOutputUnit()
        progressTask?.cancel()
        progressTask = nil
        eventHandler?(.paused)
    }

    func stop() async {
        shouldResumeAfterInterruption = false
        resumeBlockedByRouteDisconnect = false

        if let decodedPCM {
            MCPPCMRendererSetPlaying(decodedPCM.renderer, false)
            MCPPCMRendererSeek(decodedPCM.renderer, 0)
        }

        stopOutputUnit()
        progressTask?.cancel()
        progressTask = nil
    }

    func seek(to position: TimeInterval) async throws {
        guard let decodedPCM else {
            throw NativePlaybackEngineError("No decoded track is ready")
        }

        let requestedFrame = position * decodedPCM.sampleRate
        let boundedFrame = UInt64(
            min(max(requestedFrame, 0), Double(decodedPCM.frameCount))
        )
        MCPPCMRendererSeek(decodedPCM.renderer, boundedFrame)
        eventHandler?(
            .positionChanged(Double(boundedFrame) / decodedPCM.sampleRate)
        )
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
        try check(
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
            try check(
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
                    operation: "Could not set the PCM format on the iPhone output"
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
                operation: "Could not initialize the iPhone audio output"
            )
            outputUnit = unit
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    private func startProgressUpdates() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, let decodedPCM = self.decodedPCM else {
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

    private func suspendOutputForLifecycleEvent() {
        if let decodedPCM {
            MCPPCMRendererSetPlaying(decodedPCM.renderer, false)
        }
        stopOutputUnit()
        progressTask?.cancel()
        progressTask = nil
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
        guard let decodedPCM else {
            throw NativePlaybackEngineError("No decoded track is ready")
        }

        suspendOutputForLifecycleEvent()
        disposeOutputUnit()
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
            shouldResumeAfterInterruption = isOutputRunning
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
        ), decodedPCM != nil else {
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

            let wasPlaying = isOutputRunning
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

            let wasPlaying = isOutputRunning
            await rebuildOutput(resumeWhenReady: wasPlaying)

        default:
            return
        }
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

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw NativePlaybackEngineError(operation, status: status)
        }
    }
}
#endif
