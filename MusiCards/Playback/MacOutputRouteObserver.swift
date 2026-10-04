//
//  MacOutputRouteObserver.swift
//  MusiCards
//

import Foundation

#if os(macOS)
import CoreAudio

/// Keeps the home-screen route current without polling while playback is idle.
@MainActor
final class MacOutputRouteObserver {
    private struct Registration {
        let objectID: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private let onChange: @MainActor () -> Void
    private var registrations: [Registration] = []
    private var observedDeviceID: AudioDeviceID?
    private(set) var hasSystemListener = false

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        let systemID = AudioObjectID(kAudioObjectSystemObject)
        hasSystemListener = addListener(
            to: systemID,
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal
        ) { [weak self] in
            self?.observeDefaultDevice()
            self?.onChange()
        }
        observeDefaultDevice()
    }

    isolated deinit {
        for registration in registrations {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(
                registration.objectID,
                &address,
                .main,
                registration.block
            )
        }
    }

    private func observeDefaultDevice() {
        let deviceID = AudioOutputRouteInspector.defaultMacOutputDeviceID()
        guard observedDeviceID != deviceID else { return }

        if let observedDeviceID {
            removeListeners(for: observedDeviceID)
        }
        observedDeviceID = deviceID
        guard let deviceID else { return }

        // AirPlay may change its selected data source without changing the
        // default output device. Names and sample rates can change in place.
        for (selector, scope) in [
            (kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput),
            (kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeGlobal)
        ] {
            _ = addListener(to: deviceID, selector: selector, scope: scope) {
                [weak self] in
                self?.onChange()
            }
        }
    }

    private func addListener(
        to objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        onEvent: @escaping @MainActor () -> Void
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else { return false }

        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in onEvent() }
        }
        guard AudioObjectAddPropertyListenerBlock(
            objectID,
            &address,
            .main,
            block
        ) == noErr else { return false }

        registrations.append(Registration(
            objectID: objectID,
            address: address,
            block: block
        ))
        return true
    }

    private func removeListeners(for objectID: AudioObjectID) {
        for registration in registrations where registration.objectID == objectID {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(
                objectID,
                &address,
                .main,
                registration.block
            )
        }
        registrations.removeAll { $0.objectID == objectID }
    }
}
#endif
