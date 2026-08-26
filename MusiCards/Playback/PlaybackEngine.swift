//
//  PlaybackEngine.swift
//  MusiCards
//

import Foundation

#if os(iOS)
import AVFAudio
#elseif os(macOS)
import CoreAudio
#endif

enum AudioOutputTransport: Equatable {
    case unknown
    case builtIn
    case aggregate
    case virtual
    case pci
    case usb
    case fireWire
    case bluetooth
    case bluetoothLE
    case hdmi
    case displayPort
    case airPlay
    case avb
    case thunderbolt
    case wired
    case wireless
    case carAudio

    var displayName: String? {
        switch self {
        case .unknown: return nil
        case .builtIn: return "BUILT-IN"
        case .aggregate: return "AGGREGATE"
        case .virtual: return "VIRTUAL"
        case .pci: return "PCI"
        case .usb: return "USB"
        case .fireWire: return "FIREWIRE"
        case .bluetooth, .bluetoothLE: return "BLUETOOTH"
        case .hdmi: return "HDMI"
        case .displayPort: return "DISPLAYPORT"
        case .airPlay: return "AIRPLAY"
        case .avb: return "AVB"
        case .thunderbolt: return "THUNDERBOLT"
        case .wired: return "WIRED"
        case .wireless: return "WIRELESS"
        case .carAudio: return "CAR AUDIO"
        }
    }

    var allowsDeviceSampleRateMatching: Bool {
        switch self {
        case .bluetooth, .bluetoothLE, .airPlay, .wireless,
             .aggregate, .virtual, .unknown, .carAudio:
            return false
        default:
            return true
        }
    }
}

struct AudioOutputRoute: Equatable {
    let deviceID: UInt32?
    let deviceName: String
    let transport: AudioOutputTransport
}

enum AudioOutputRouteInspector {
    static func current() -> AudioOutputRoute {
        #if os(iOS)
        guard let output = AVAudioSession.sharedInstance()
            .currentRoute.outputs.first else {
            return AudioOutputRoute(
                deviceID: nil,
                deviceName: "SYSTEM OUTPUT",
                transport: .unknown
            )
        }

        return AudioOutputRoute(
            deviceID: nil,
            deviceName: output.portName.nilIfBlank ?? "SYSTEM OUTPUT",
            transport: transport(for: output.portType)
        )
        #elseif os(macOS)
        guard let deviceID = defaultMacOutputDeviceID() else {
            return AudioOutputRoute(
                deviceID: nil,
                deviceName: "SYSTEM OUTPUT",
                transport: .unknown
            )
        }

        let transport = macTransport(deviceID)
        let deviceName: String
        if transport == .airPlay {
            deviceName = macSelectedDataSourceName(deviceID)
                ?? macDeviceName(deviceID)
                ?? "SYSTEM OUTPUT"
        } else {
            deviceName = macDeviceName(deviceID) ?? "SYSTEM OUTPUT"
        }

        return AudioOutputRoute(
            deviceID: deviceID,
            deviceName: deviceName,
            transport: transport
        )
        #else
        return AudioOutputRoute(
            deviceID: nil,
            deviceName: "SYSTEM OUTPUT",
            transport: .unknown
        )
        #endif
    }

    #if os(iOS)
    private static func transport(
        for port: AVAudioSession.Port
    ) -> AudioOutputTransport {
        switch port {
        case .bluetoothA2DP, .bluetoothHFP:
            return .bluetooth
        case .bluetoothLE:
            return .bluetoothLE
        case .airPlay:
            return .airPlay
        case .usbAudio:
            return .usb
        case .HDMI:
            return .hdmi
        case .builtInSpeaker, .builtInReceiver:
            return .builtIn
        case .headphones, .lineOut:
            return .wired
        case .carAudio:
            return .carAudio
        default:
            return .unknown
        }
    }
    #elseif os(macOS)
    private static func defaultMacOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr,
        deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    private static func macDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &name
        ) == noErr,
        let name = name?.takeUnretainedValue() else {
            return nil
        }
        return name as String
    }

    private static func macSelectedDataSourceName(
        _ deviceID: AudioDeviceID
    ) -> String? {
        for scope in [
            kAudioObjectPropertyScopeOutput,
            kAudioObjectPropertyScopeGlobal
        ] {
            if let name = macSelectedDataSourceName(
                deviceID,
                scope: scope
            ) {
                return name
            }
        }
        return nil
    }

    private static func macSelectedDataSourceName(
        _ deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var sourceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var sourceDataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID,
            &sourceAddress,
            0,
            nil,
            &sourceDataSize
        ) == noErr,
        sourceDataSize >= UInt32(MemoryLayout<UInt32>.size) else {
            return nil
        }

        var sourceIDs = [UInt32](
            repeating: 0,
            count: Int(sourceDataSize) / MemoryLayout<UInt32>.size
        )
        let sourceStatus = sourceIDs.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(
                deviceID,
                &sourceAddress,
                0,
                nil,
                &sourceDataSize,
                buffer.baseAddress!
            )
        }
        guard sourceStatus == noErr, var sourceID = sourceIDs.first else {
            return nil
        }

        var translatedName: Unmanaged<CFString>?
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSourceNameForIDCFString,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var translationSize = UInt32(MemoryLayout<AudioValueTranslation>.size)

        let translationStatus = withUnsafeMutablePointer(to: &sourceID) {
            sourcePointer in
            withUnsafeMutablePointer(to: &translatedName) { namePointer in
                var translation = AudioValueTranslation(
                    mInputData: sourcePointer,
                    mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: namePointer,
                    mOutputDataSize: UInt32(
                        MemoryLayout<Unmanaged<CFString>?>.size
                    )
                )
                return AudioObjectGetPropertyData(
                    deviceID,
                    &nameAddress,
                    0,
                    nil,
                    &translationSize,
                    &translation
                )
            }
        }

        guard translationStatus == noErr,
              let name = translatedName?.takeRetainedValue() else {
            return nil
        }
        return (name as String).nilIfBlank
    }

    private static func macTransport(
        _ deviceID: AudioDeviceID
    ) -> AudioOutputTransport {
        var transportID: UInt32 = kAudioDeviceTransportTypeUnknown
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &transportID
        ) == noErr else {
            return .unknown
        }

        switch transportID {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate: return .aggregate
        case kAudioDeviceTransportTypeVirtual: return .virtual
        case kAudioDeviceTransportTypePCI: return .pci
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeFireWire: return .fireWire
        case kAudioDeviceTransportTypeBluetooth: return .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: return .bluetoothLE
        case kAudioDeviceTransportTypeHDMI: return .hdmi
        case kAudioDeviceTransportTypeDisplayPort: return .displayPort
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        case kAudioDeviceTransportTypeAVB: return .avb
        case kAudioDeviceTransportTypeThunderbolt: return .thunderbolt
        case kAudioDeviceTransportTypeContinuityCaptureWired: return .wired
        case kAudioDeviceTransportTypeContinuityCaptureWireless: return .wireless
        default: return .unknown
        }
    }
    #endif
}

enum PlaybackEngineEvent: Equatable {
    case prepared(
        duration: TimeInterval?,
        audioFormat: PlaybackAudioFormat?
    )
    case started
    case paused
    case positionChanged(TimeInterval)
    case finished
    case failed(PlaybackFailure)
}

/// Main-actor facade for a platform audio implementation.
/// A Core Audio or iOS implementation may keep its realtime work off the main
/// actor, but reports user-facing state through `eventHandler`.
@MainActor
protocol PlaybackEngine: AnyObject {
    var eventHandler: ((PlaybackEngineEvent) -> Void)? { get set }
    var canSeek: Bool { get }

    func prepare(_ item: PlaybackQueueItem) async throws
    func play() async throws
    func pause() async
    func stop() async
    func seek(to position: TimeInterval) async throws
    func restoreOutputConfiguration()
}

extension PlaybackEngine {
    func restoreOutputConfiguration() {}
}

enum PendingPlaybackEngineError: LocalizedError {
    case sourceLoadingNotImplemented

    var errorDescription: String? {
        switch self {
        case .sourceLoadingNotImplemented:
            return "Local audio loading is not connected yet"
        }
    }
}

/// Safe first-stage engine. It makes the architectural boundary real without
/// pretending to play sound before a native audio implementation is attached.
@MainActor
final class PendingPlaybackEngine: PlaybackEngine {
    var eventHandler: ((PlaybackEngineEvent) -> Void)?
    var canSeek: Bool { false }

    func prepare(_ item: PlaybackQueueItem) async throws {
        throw PendingPlaybackEngineError.sourceLoadingNotImplemented
    }

    func play() async throws {
        throw PendingPlaybackEngineError.sourceLoadingNotImplemented
    }

    func pause() async {}
    func stop() async {}

    func seek(to position: TimeInterval) async throws {
        throw PendingPlaybackEngineError.sourceLoadingNotImplemented
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
