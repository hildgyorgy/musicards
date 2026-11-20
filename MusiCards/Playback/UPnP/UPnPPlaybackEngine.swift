import Foundation
import OSLog

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
        } catch let error as NavidromeConnectionStoreError {
            throw error
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

    private static let logger = Logger(subsystem: "com.hildgyorgy.MusiCards", category: "UPnPPlayback")
    private let pollInterval: Duration
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
    private var lastPlayingPosition: TimeInterval?
    private var lastPlayingDuration: TimeInterval?
    private var pollGeneration: UInt64 = 0
    private var ownsRendererPlaylist = false
    private var playlistEntries: [(item: PlaybackQueueItem, url: URL)] = []
    private var playlistTrackOffset = 0
    private var playlistServer: (any RendererPlaylistServing)?
    private let playlistServerFactory: @Sendable () -> any RendererPlaylistServing

    var releaseQueueProvider: (() async throws -> ReleasePlaybackQueue?)?
    var nextItemProvider: (() async throws -> PlaybackQueueItem?)?

    init(
        streamURLProvider: NavidromeRendererStreamURLProvider,
        clientFactory: @escaping ClientFactory = { service in
            AVTransportClient(service: service)
        },
        volumeClientFactory: @escaping VolumeClientFactory = { service in
            RenderingControlClient(service: service)
        },
        pollInterval: Duration = .seconds(1),
        playlistServerFactory: @escaping @Sendable () -> any RendererPlaylistServing = { RendererPlaylistHTTPServer() }
    ) {
        self.playlistServerFactory = playlistServerFactory
        self.pollInterval = pollInterval
        self.streamURLProvider = streamURLProvider
        self.clientFactory = clientFactory
        self.volumeClientFactory = volumeClientFactory
    }

    deinit {
        pollTask?.cancel()
        if let server = playlistServer { Task { _ = await server.finish() } }
    }

    func configure(renderer: UPnPRendererDescriptor) {
        guard self.renderer != renderer else { return }
        if self.renderer?.id == renderer.id {
            // SSDP identity is stable, but a renderer can change its IP/port.
            // Refresh the clients without discarding an adopted/playing queue.
            self.renderer = renderer
            client = clientFactory(renderer.avTransport)
            volumeClient = renderer.renderingControl.map(volumeClientFactory)
            return
        }
        pollGeneration &+= 1
        if let server = playlistServer {
            playlistServer = nil
            Task { _ = await server.finish() }
        }
        pollTask?.cancel()
        pollTask = nil
        self.renderer = renderer
        client = clientFactory(renderer.avTransport)
        volumeClient = renderer.renderingControl.map(volumeClientFactory)
        preparedItem = nil
        if consecutivePollFailures >= 3 {
            eventHandler?(.rendererConnectionChanged(isReconnecting: false))
        }
        consecutivePollFailures = 0
        hasObservedPlaying = false
        volumePollCounter = 0
        currentStreamURL = nil
        stagedNextItem = nil
        stagedNextStreamURL = nil
        ownsRendererPlaylist = false
        playlistEntries = []
    }

    func prepare(_ item: PlaybackQueueItem) async throws {
        guard renderer != nil, let client else {
            throw UPnPPlaybackError.rendererUnavailable("network renderer")
        }
        guard case .remoteAudio(let asset) = item.source,
              asset.source == .navidrome else {
            throw UPnPPlaybackError.navidromeOnly
        }

        pollGeneration &+= 1
        let generation = pollGeneration
        let previousServer = playlistServer
        playlistServer = nil
        _ = await previousServer?.finish()
        try ensureCurrent(generation)
        ownsRendererPlaylist = false
        playlistEntries = []
        if renderer?.capabilities.supportsDIDLPlaylist == true {
            eventHandler?(.rendererPlaybackNotice(nil))
        }
        lastPlayingPosition = nil
        lastPlayingDuration = nil
        pollTask?.cancel()
        pollTask = nil
        hasObservedPlaying = false
        if consecutivePollFailures >= 3 {
            eventHandler?(.rendererConnectionChanged(isReconnecting: false))
        }
        consecutivePollFailures = 0
        let streamURL = try streamURLProvider.streamURL(for: asset)
        if renderer?.capabilities.supportsDIDLPlaylist == true {
            do {
                if let queue = try await releaseQueueProvider?(),
                   queue.items.indices.contains(queue.selectedIndex),
                   queue.items[queue.selectedIndex].id == item.id,
                   queue.items.count - queue.selectedIndex > 1 {
                    try ensureCurrent(generation)
                    let remaining = Array(queue.items[queue.selectedIndex...])
                    try await handoffPlaylist(remaining, client: client, generation: generation)
                }
            } catch {
                if error is CancellationError { throw error }
                try ensureCurrent(generation)
                Self.logger.notice("Renderer album handoff unavailable; using controller-managed queue")
                eventHandler?(.rendererPlaybackNotice(
                    "Album handoff is unavailable on this renderer. Keep MusiCards open for continuous playback."
                ))
            }
        }
        try ensureCurrent(generation)
        if !ownsRendererPlaylist {
            let metadata = DIDLPlaylistDocument.trackMetadata(for: item, streamURL: streamURL, asset: asset)
            try await client.setTransportURI(streamURL, metadata: metadata)
            try ensureCurrent(generation)
            preparedItem = item
            currentStreamURL = streamURL
            await stageNextItemIfAvailable()
        }
        try ensureCurrent(generation)
        await publishVolumeStateIfAvailable()
        try ensureCurrent(generation)
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
        let generation = pollGeneration
        do {
            try await client.play()
        } catch {
            // A renderer may reject a redundant Play, or start despite the
            // response timing out. Reconcile with the actual matching stream
            // before treating the command as failed; never resend SetURI here.
            let commandError = error
            guard !(error is CancellationError), !Task.isCancelled else { throw error }
            let snapshot = try? await client.snapshot()
            guard generation == pollGeneration, !Task.isCancelled else { throw CancellationError() }
            if snapshot?.transport.state.uppercased() != "PLAYING" ||
                snapshot?.transport.status?.uppercased() == "ERROR_OCCURRED" ||
                !Self.sameStream(snapshot?.position.trackURI, currentStreamURL) {
                // If even verification timed out, don't claim playback started.
                // Keep observing so the UI can recover when the renderer answers.
                if snapshot == nil || (snapshot?.transport.state.uppercased() == "TRANSITIONING" &&
                    Self.sameStream(snapshot?.position.trackURI, currentStreamURL)) {
                    consecutivePollFailures = max(consecutivePollFailures, 3)
                    eventHandler?(.rendererConnectionChanged(isReconnecting: true))
                    startPolling()
                }
                throw commandError
            }
            Self.logger.notice("Play response failed; matching renderer stream confirmed playing")
        }
        guard generation == pollGeneration, !Task.isCancelled else { return }
        eventHandler?(.started)
        startPolling()
    }

    func pause() async {
        guard let client else { return }
        pollGeneration &+= 1
        pollTask?.cancel()
        pollTask = nil
        do {
            try await client.pause()
            eventHandler?(.paused)
        } catch {
            eventHandler?(.failed(PlaybackFailure(error)))
        }
    }

    func stop() async {
        pollGeneration &+= 1
        let generation = pollGeneration
        let stoppedClient = client
        let server = playlistServer
        playlistServer = nil
        ownsRendererPlaylist = false
        playlistEntries = []
        pollTask?.cancel()
        pollTask = nil
        hasObservedPlaying = false
        if consecutivePollFailures >= 3 {
            eventHandler?(.rendererConnectionChanged(isReconnecting: false))
        }
        consecutivePollFailures = 0
        _ = await server?.finish()
        guard generation == pollGeneration, !Task.isCancelled else { return }
        try? await stoppedClient?.stop()
    }

    func seek(to position: TimeInterval) async throws {
        guard let client else {
            throw UPnPPlaybackError.rendererUnavailable(
                renderer?.friendlyName ?? "network renderer"
            )
        }
        try await client.seek(to: position)
        lastPlayingPosition = position
        eventHandler?(.positionChanged(position))
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    // Transient control failures must not abandon a renderer
                    // that is still fetching and playing audio independently.
                    let backoff = 1 << min(max(self.consecutivePollFailures - 2, 0), 3)
                    let interval = self.pollInterval * backoff
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                await self.pollRenderer()
            }
        }
    }

    func pollRenderer() async {
        guard let client else { return }
        let generation = pollGeneration
        do {
            let snapshot = try await client.snapshot()
            guard generation == pollGeneration, !Task.isCancelled else { return }
            let wasReconnecting = consecutivePollFailures >= 3
            consecutivePollFailures = 0
            if wasReconnecting {
                Self.logger.notice("Renderer state polling recovered")
                eventHandler?(.rendererConnectionChanged(isReconnecting: false))
            }
            let state = snapshot.transport.state.uppercased()
            if ownsRendererPlaylist {
                if ["PLAYING", "TRANSITIONING", "PAUSED_PLAYBACK"].contains(state),
                   let entry = playlistEntry(for: snapshot.position) {
                    if entry.item.id != preparedItem?.id {
                        lastPlayingPosition = nil
                        lastPlayingDuration = nil
                    }
                    preparedItem = entry.item
                    currentStreamURL = snapshot.position.trackURI ?? entry.url
                    eventHandler?(.rendererTrackChanged(
                        itemID: entry.item.id, duration: snapshot.position.duration ?? entry.item.track.duration,
                        audioFormat: entry.item.track.audioFormat,
                        position: snapshot.position.relativeTime ?? 0, isPlaying: state != "PAUSED_PLAYBACK"
                    ))
                }
                if state == "STOPPED" || state == "NO_MEDIA_PRESENT" {
                    // Rygel can reset Track/TrackURI to item 1 at playlist EOS.
                    // Never rewind the UI or let .finished requeue the album.
                    if hasObservedPlaying {
                        hasObservedPlaying = false
                        if snapshot.transport.status?.uppercased() == "ERROR_OCCURRED" {
                            eventHandler?(.failed(PlaybackFailure(NativePlaybackEngineError("The renderer reported a playback error."))))
                        } else {
                            eventHandler?(.rendererPlaylistStopped)
                        }
                    }
                    return
                }
            }
            if !ownsRendererPlaylist, let stagedNextItem,
               let stagedNextStreamURL,
               Self.sameStream(snapshot.position.trackURI, stagedNextStreamURL),
               !Self.sameStream(currentStreamURL, stagedNextStreamURL) {
                preparedItem = stagedNextItem
                currentStreamURL = stagedNextStreamURL
                self.stagedNextItem = nil
                self.stagedNextStreamURL = nil
                lastPlayingPosition = nil
                lastPlayingDuration = nil
                eventHandler?(
                    .advancedToNext(
                        itemID: stagedNextItem.id,
                        duration: stagedNextItem.track.duration,
                        audioFormat: stagedNextItem.track.audioFormat,
                        position: snapshot.position.relativeTime ?? 0
                    )
                )
                await stageNextItemIfAvailable()
                guard generation == pollGeneration, !Task.isCancelled else { return }
            }
            if wasReconnecting, let preparedItem,
               Self.sameStream(snapshot.position.trackURI, currentStreamURL),
               snapshot.transport.status?.uppercased() != "ERROR_OCCURRED" {
                if state == "PLAYING" || state == "TRANSITIONING" || state == "PAUSED_PLAYBACK" {
                    eventHandler?(.rendererPlaybackStateConfirmed(
                        itemID: preparedItem.id, isPlaying: state != "PAUSED_PLAYBACK"
                    ))
                }
            }
            if state == "PLAYING" || state == "TRANSITIONING" {
                hasObservedPlaying = true
                if let position = snapshot.position.relativeTime, position.isFinite {
                    lastPlayingPosition = position
                }
                if let duration = snapshot.position.duration, duration.isFinite, duration > 0 {
                    lastPlayingDuration = duration
                }
            }
            if let position = snapshot.position.relativeTime {
                eventHandler?(.positionChanged(position))
            }
            volumePollCounter += 1
            if volumePollCounter >= 2 {
                volumePollCounter = 0
                await publishVolumeStateIfAvailable()
            }
            guard generation == pollGeneration, !Task.isCancelled else { return }
            if hasObservedPlaying,
               state == "STOPPED" || state == "NO_MEDIA_PRESENT" {
                pollTask?.cancel()
                pollTask = nil
                hasObservedPlaying = false
                let duration = lastPlayingDuration ?? preparedItem?.track.duration
                let position = max(lastPlayingPosition ?? 0, snapshot.position.relativeTime ?? 0)
                if snapshot.transport.status?.uppercased() == "ERROR_OCCURRED" {
                    eventHandler?(.failed(PlaybackFailure(NativePlaybackEngineError(
                        "The renderer reported a playback error. Check its connection to Navidrome and try again."
                    ))))
                } else if let duration, duration.isFinite, duration > 0,
                          position >= max(0, duration - min(2, duration * 0.02)) {
                    eventHandler?(.finished)
                } else {
                    // An external Stop or mid-track failure must not consume
                    // the remaining queue. Unknown duration is conservative.
                    eventHandler?(.paused)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == pollGeneration, !Task.isCancelled else { return }
            consecutivePollFailures += 1
            if consecutivePollFailures == 3 {
                // Connection loss is not evidence that playback stopped.
                // Keep the queue and prepared item, and recover without Play
                // or SetAVTransportURI when control responses resume.
                Self.logger.error("Renderer state polling interrupted; retrying")
                eventHandler?(.rendererConnectionChanged(isReconnecting: true))
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
        guard !ownsRendererPlaylist else { return }
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
            let itemMetadata = DIDLPlaylistDocument.trackMetadata(
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
            // Do not log the error text: it can contain an authenticated URL.
            let code = (error as NSError).code
            Self.logger.error("Preparing the next renderer track failed code=\(code, privacy: .public)")
            stagedNextItem = nil
            stagedNextStreamURL = nil
        }
    }

    private func ensureCurrent(_ generation: UInt64) throws {
        guard generation == pollGeneration, !Task.isCancelled else { throw CancellationError() }
    }

    private func handoffPlaylist(_ items: [PlaybackQueueItem], client: any AVTransportControlling, generation: UInt64) async throws {
        guard let renderer else { throw RendererPlaylistError.unavailable }
        let urls = try items.map { item -> URL in
            guard case .remoteAudio(let asset) = item.source else { throw RendererPlaylistError.invalidQueue }
            return try streamURLProvider.streamURL(for: asset)
        }
        let document = try DIDLPlaylistDocument.make(items: items, urls: urls)
        let server = playlistServerFactory()
        playlistServer = server
        do {
            let url = try await server.start(document: document, rendererURL: renderer.descriptionURL)
            try ensureCurrent(generation)
            try await client.stop()
            try ensureCurrent(generation)
            if renderer.capabilities.supportsSetNext {
                try await client.setNextTransportURI(nil, metadata: "")
                try ensureCurrent(generation)
            }
            try await client.setTransportURI(url, metadata: DIDLPlaylistDocument.metadata(title: items[0].track.albumTitle, url: url))
            try ensureCurrent(generation)
            let info = try await client.mediaInfo()
            try ensureCurrent(generation)
            let downloaded = await server.finish()
            if playlistServer === server { playlistServer = nil }
            try ensureCurrent(generation)
            guard downloaded else { throw RendererPlaylistError.notDownloaded }
            guard info.numberOfTracks == items.count, info.currentURI == url, info.nextURI == nil else {
                throw RendererPlaylistError.notConfirmed
            }
            try await client.setNormalPlayMode()
            try ensureCurrent(generation)
            playlistEntries = Array(zip(items, urls)).map { (item: $0.0, url: $0.1) }
            playlistTrackOffset = 0
            ownsRendererPlaylist = true
            stagedNextItem = nil
            stagedNextStreamURL = nil
            preparedItem = items[0]
            currentStreamURL = urls[0]
            Self.logger.notice("Renderer accepted an autonomous album playlist tracks=\(items.count, privacy: .public)")
        } catch {
            _ = await server.finish()
            if playlistServer === server { playlistServer = nil }
            throw error
        }
    }

    private func playlistEntry(for position: AVTransportPosition) -> (item: PlaybackQueueItem, url: URL)? {
        if let number = position.trackNumber {
            let index = playlistTrackOffset + number - 1
            if playlistEntries.indices.contains(index), Self.sameStream(position.trackURI, playlistEntries[index].url) {
                return playlistEntries[index]
            }
        }
        return playlistEntries.first { Self.sameStream(position.trackURI, $0.url) }
    }

    private static func sameStream(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        if lhs == rhs { return true }
        guard let id = navidromeSongID(in: lhs) else { return false }
        return id == navidromeSongID(in: rhs)
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
        guard let client else { return nil }
        var snapshot = try await client.snapshot()
        snapshot.mediaInfo = try? await client.mediaInfo()
        return snapshot
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

        pollGeneration &+= 1
        let generation = pollGeneration
        pollTask?.cancel()
        pollTask = nil
        preparedItem = item
        currentStreamURL = snapshot.position.trackURI ?? streamURL
        lastPlayingPosition = snapshot.position.relativeTime
        lastPlayingDuration = snapshot.position.duration
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
        var media = snapshot.mediaInfo
        if media == nil { media = try? await client?.mediaInfo() }
        try ensureCurrent(generation)
        // A playlist adopted from another controller owns its own end-of-list.
        // An unknown media response on a playlist-capable renderer must not
        // receive a speculative SetNext that could extend an existing album.
        ownsRendererPlaylist = (media?.numberOfTracks ?? 0) > 1 ||
            (media == nil && renderer?.capabilities.supportsDIDLPlaylist == true)
        playlistEntries = []
        if ownsRendererPlaylist, let queue = try await releaseQueueProvider?() {
            try ensureCurrent(generation)
            for entry in queue.items {
                guard case .remoteAudio(let asset) = entry.source else { continue }
                playlistEntries.append((entry, try streamURLProvider.streamURL(for: asset)))
            }
            playlistTrackOffset = max(0, queue.selectedIndex - max(0, (snapshot.position.trackNumber ?? 1) - 1))
        }
        try ensureCurrent(generation)
        await stageNextItemIfAvailable()
        try ensureCurrent(generation)
        await publishVolumeStateIfAvailable()
        try ensureCurrent(generation)
        startPolling()
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
