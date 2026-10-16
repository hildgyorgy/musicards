import Foundation

@MainActor
protocol RendererPlaybackSessionControlling: AnyObject {
    func rendererSnapshot() async throws -> AVTransportSnapshot?
    func adoptRendererSession(
        item: PlaybackQueueItem,
        snapshot: AVTransportSnapshot
    ) async throws
}

enum UPnPPlaybackError: LocalizedError {
    case rendererUnavailable(String)
    case navidromeOnly
    case missingNavidromeConnection
    case rendererSessionMismatch

    var errorDescription: String? {
        switch self {
        case .rendererUnavailable(let name):
            "The selected network renderer, \(name), is not available. Open OUTPUT and search for it again."
        case .navidromeOnly:
            "Network renderer playback currently supports Navidrome tracks only."
        case .missingNavidromeConnection:
            "Connect the Navidrome library before using a network renderer."
        case .rendererSessionMismatch:
            "The renderer changed tracks before MusiCards could adopt its session."
        }
    }
}

@MainActor
final class NavidromeRendererStreamURLProvider {
    private let connection: any NavidromeCatalogConnectionProviding

    init(connection: any NavidromeCatalogConnectionProviding) {
        self.connection = connection
    }

    func streamURL(for asset: RemotePlaybackAsset) throws -> URL {
        guard asset.source == .navidrome else {
            throw UPnPPlaybackError.navidromeOnly
        }
        let credentials: NavidromeCatalogCredentials
        do {
            credentials = try connection.rendererCredentials()
        } catch {
            throw UPnPPlaybackError.missingNavidromeConnection
        }
        let salt = try OpenSubsonicAuthentication.makeSalt()
        return try OpenSubsonicRequestBuilder().rendererStreamURL(
            profile: credentials.profile,
            password: credentials.password,
            salt: salt,
            songID: asset.providerItemID
        )
    }
}

@MainActor
final class UPnPPlaybackEngine: PlaybackEngine {
    typealias ClientFactory = @Sendable (UPnPServiceDescriptor)
        -> any AVTransportControlling
    typealias VolumeClientFactory = @Sendable (UPnPServiceDescriptor)
        -> any RenderingControlControlling

    var eventHandler: ((PlaybackEngineEvent) -> Void)?
    var canSeek: Bool { renderer?.capabilities.supportsSeek != false }

    private let streamURLProvider: NavidromeRendererStreamURLProvider
    private let clientFactory: ClientFactory
    private let volumeClientFactory: VolumeClientFactory
    private var renderer: UPnPRendererDescriptor?
    private var client: (any AVTransportControlling)?
    private var volumeClient: (any RenderingControlControlling)?
    private var preparedItem: PlaybackQueueItem?
    private var pollTask: Task<Void, Never>?
    private var hasObservedPlaying = false
    private var consecutivePollFailures = 0
    private var volumePollCounter = 0
    private var currentStreamURL: URL?
    private var stagedNextItem: PlaybackQueueItem?
    private var stagedNextStreamURL: URL?

    var nextItemProvider: (() async throws -> PlaybackQueueItem?)?

    init(
        streamURLProvider: NavidromeRendererStreamURLProvider,
        clientFactory: @escaping ClientFactory = { service in
            AVTransportClient(service: service)
        },
        volumeClientFactory: @escaping VolumeClientFactory = { service in
            RenderingControlClient(service: service)
        }
    ) {
        self.streamURLProvider = streamURLProvider
        self.clientFactory = clientFactory
        self.volumeClientFactory = volumeClientFactory
    }

    deinit {
        pollTask?.cancel()
    }

    func configure(renderer: UPnPRendererDescriptor) {
        guard self.renderer?.id != renderer.id else { return }
        pollTask?.cancel()
        pollTask = nil
        self.renderer = renderer
        client = clientFactory(renderer.avTransport)
        volumeClient = renderer.renderingControl.map(volumeClientFactory)
        preparedItem = nil
        hasObservedPlaying = false
        volumePollCounter = 0
        currentStreamURL = nil
        stagedNextItem = nil
        stagedNextStreamURL = nil
    }

    func prepare(_ item: PlaybackQueueItem) async throws {
        guard renderer != nil, let client else {
            throw UPnPPlaybackError.rendererUnavailable("network renderer")
        }
        guard case .remoteAudio(let asset) = item.source,
              asset.source == .navidrome else {
            throw UPnPPlaybackError.navidromeOnly
        }

        pollTask?.cancel()
        pollTask = nil
        hasObservedPlaying = false
        consecutivePollFailures = 0
        let streamURL = try streamURLProvider.streamURL(for: asset)
        let metadata = Self.metadata(for: item, streamURL: streamURL, asset: asset)
        try await client.setTransportURI(streamURL, metadata: metadata)
        preparedItem = item
        currentStreamURL = streamURL
        await stageNextItemIfAvailable()
        await publishVolumeStateIfAvailable()
        eventHandler?(
            .prepared(
                duration: item.track.duration,
                audioFormat: item.track.audioFormat
            )
        )
    }

    func play() async throws {
        guard preparedItem != nil, let client else {
            throw UPnPPlaybackError.rendererUnavailable(
                renderer?.friendlyName ?? "network renderer"
            )
        }
        try await client.play()
        eventHandler?(.started)
        startPolling()
    }

    func pause() async {
        guard let client else { return }
        do {
            try await client.pause()
            eventHandler?(.paused)
        } catch {
            eventHandler?(.failed(PlaybackFailure(error)))
        }
    }

    func stop() async {
        pollTask?.cancel()
        pollTask = nil
        hasObservedPlaying = false
        guard let client else { return }
        try? await client.stop()
    }

    func seek(to position: TimeInterval) async throws {
        guard let client else {
            throw UPnPPlaybackError.rendererUnavailable(
                renderer?.friendlyName ?? "network renderer"
            )
        }
        try await client.seek(to: position)
        eventHandler?(.positionChanged(position))
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                await self.pollRenderer()
            }
        }
    }

    private func pollRenderer() async {
        guard let client else { return }
        do {
            let snapshot = try await client.snapshot()
            consecutivePollFailures = 0
            let state = snapshot.transport.state.uppercased()
            if let stagedNextItem,
               let stagedNextStreamURL,
               Self.sameStream(snapshot.position.trackURI, stagedNextStreamURL),
               !Self.sameStream(currentStreamURL, stagedNextStreamURL) {
                preparedItem = stagedNextItem
                currentStreamURL = stagedNextStreamURL
                self.stagedNextItem = nil
                self.stagedNextStreamURL = nil
                eventHandler?(
                    .advancedToNext(
                        itemID: stagedNextItem.id,
                        duration: stagedNextItem.track.duration,
                        audioFormat: stagedNextItem.track.audioFormat,
                        position: snapshot.position.relativeTime ?? 0
                    )
                )
                await stageNextItemIfAvailable()
            }
            if state == "PLAYING" || state == "TRANSITIONING" {
                hasObservedPlaying = true
            }
            if let position = snapshot.position.relativeTime {
                eventHandler?(.positionChanged(position))
            }
            volumePollCounter += 1
            if volumePollCounter >= 2 {
                volumePollCounter = 0
                await publishVolumeStateIfAvailable()
            }
            if hasObservedPlaying,
               state == "STOPPED" || state == "NO_MEDIA_PRESENT" {
                pollTask?.cancel()
                pollTask = nil
                hasObservedPlaying = false
                eventHandler?(.finished)
            }
        } catch is CancellationError {
            return
        } catch {
            consecutivePollFailures += 1
            if consecutivePollFailures >= 3 {
                pollTask?.cancel()
                pollTask = nil
                eventHandler?(.failed(PlaybackFailure(error)))
            }
        }
    }

    private func publishVolumeStateIfAvailable() async {
        guard let volumeClient else { return }
        if let state = try? await volumeClient.volumeState() {
            eventHandler?(.volumeChanged(state))
        }
    }

    private func stageNextItemIfAvailable() async {
        guard renderer?.capabilities.supportsSetNext == true,
              let client else {
            stagedNextItem = nil
            stagedNextStreamURL = nil
            return
        }
        do {
            guard let item = try await nextItemProvider?() else {
                try? await client.setNextTransportURI(nil, metadata: "")
                stagedNextItem = nil
                stagedNextStreamURL = nil
                return
            }
            guard case .remoteAudio(let asset) = item.source,
                  asset.source == .navidrome else {
                stagedNextItem = nil
                stagedNextStreamURL = nil
                return
            }
            let streamURL = try streamURLProvider.streamURL(for: asset)
            let itemMetadata = Self.metadata(
                for: item,
                streamURL: streamURL,
                asset: asset
            )
            try await client.setNextTransportURI(
                streamURL,
                metadata: itemMetadata
            )
            stagedNextItem = item
            stagedNextStreamURL = streamURL
        } catch {
            stagedNextItem = nil
            stagedNextStreamURL = nil
        }
    }

    private static func sameStream(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        if lhs == rhs { return true }
        return navidromeSongID(in: lhs) == navidromeSongID(in: rhs)
    }

    static func navidromeSongID(in url: URL?) -> String? {
        guard let url,
              let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
              ) else { return nil }
        return components.queryItems?.first(where: {
            $0.name.caseInsensitiveCompare("id") == .orderedSame
        })?.value?.nilIfBlank
    }

    private static func metadata(
        for item: PlaybackQueueItem,
        streamURL: URL,
        asset: RemotePlaybackAsset
    ) -> String {
        let track = item.track
        let declaredMimeType = asset.contentType?
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)
        let mimeType = declaredMimeType?.nilIfBlank
            ?? mimeType(for: asset.suffix)
        let duration = track.duration.map(durationString) ?? ""
        let durationAttribute = duration.isEmpty
            ? "" : " duration=\"\(xmlEscaped(duration))\""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
          <item id="\(xmlEscaped(asset.providerItemID))" parentID="0" restricted="1">
            <dc:title>\(xmlEscaped(track.title))</dc:title>
            <upnp:artist>\(xmlEscaped(track.artist))</upnp:artist>
            <upnp:album>\(xmlEscaped(track.albumTitle))</upnp:album>
            <upnp:class>object.item.audioItem.musicTrack</upnp:class>
            <res protocolInfo="http-get:*:\(xmlEscaped(mimeType)):*"\(durationAttribute)>\(xmlEscaped(streamURL.absoluteString))</res>
          </item>
        </DIDL-Lite>
        """
    }

    private static func mimeType(for suffix: String?) -> String {
        switch suffix?.lowercased() {
        case "flac": "audio/flac"
        case "m4a", "mp4": "audio/mp4"
        case "aac": "audio/aac"
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "aif", "aiff": "audio/aiff"
        default: "application/octet-stream"
        }
    }

    private static func durationString(_ interval: TimeInterval) -> String {
        let seconds = max(Int(interval.rounded()), 0)
        return String(
            format: "%d:%02d:%02d",
            seconds / 3_600,
            (seconds % 3_600) / 60,
            seconds % 60
        )
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

extension UPnPPlaybackEngine: PlaybackVolumeControlling {
    var canControlVolume: Bool { volumeClient != nil }

    func outputVolumeState() async throws -> PlaybackVolumeState? {
        try await volumeClient?.volumeState()
    }

    func setOutputVolume(_ level: Double) async throws -> PlaybackVolumeState? {
        guard let volumeClient else { return nil }
        try await volumeClient.setVolume(level)
        // Keep drag updates to one SOAP request. The regular renderer poll
        // confirms the actual value and reflects changes made elsewhere.
        return nil
    }

    func setOutputMuted(_ isMuted: Bool) async throws -> PlaybackVolumeState? {
        guard let volumeClient else { return nil }
        try await volumeClient.setMuted(isMuted)
        return try await volumeClient.volumeState()
    }
}

extension UPnPPlaybackEngine: RendererPlaybackSessionControlling {
    func rendererSnapshot() async throws -> AVTransportSnapshot? {
        try await client?.snapshot()
    }

    func adoptRendererSession(
        item: PlaybackQueueItem,
        snapshot: AVTransportSnapshot
    ) async throws {
        guard case .remoteAudio(let asset) = item.source,
              asset.source == .navidrome else {
            throw UPnPPlaybackError.navidromeOnly
        }
        let streamURL = try streamURLProvider.streamURL(for: asset)
        guard Self.sameStream(snapshot.position.trackURI, streamURL) else {
            throw UPnPPlaybackError.rendererSessionMismatch
        }

        preparedItem = item
        currentStreamURL = snapshot.position.trackURI ?? streamURL
        hasObservedPlaying = snapshot.transport.state.uppercased() == "PLAYING"
        consecutivePollFailures = 0
        volumePollCounter = 0
        eventHandler?(
            .prepared(
                duration: snapshot.position.duration ?? item.track.duration,
                audioFormat: item.track.audioFormat
            )
        )
        eventHandler?(.positionChanged(snapshot.position.relativeTime ?? 0))
        switch snapshot.transport.state.uppercased() {
        case "PLAYING", "TRANSITIONING":
            eventHandler?(.started)
        case "PAUSED_PLAYBACK":
            eventHandler?(.paused)
        default:
            break
        }
        await stageNextItemIfAvailable()
        await publishVolumeStateIfAvailable()
        startPolling()
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
