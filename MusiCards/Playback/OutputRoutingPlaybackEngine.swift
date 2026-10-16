import Foundation

@MainActor
final class OutputRoutingPlaybackEngine: PlaybackEngine {
    enum Selection {
        case system
        case renderer(UPnPRendererDescriptor)
        case unavailable(name: String)
    }

    private enum Route: Equatable {
        case system
        case renderer(String)
    }

    var eventHandler: ((PlaybackEngineEvent) -> Void)?

    var canSeek: Bool {
        switch activeRoute {
        case .renderer:
            rendererEngine.canSeek
        case .system, nil:
            systemEngine.canSeek
        }
    }

    private let systemEngine: PlaybackEngine
    private let rendererEngine: UPnPPlaybackEngine
    private let selection: () -> Selection
    private var activeRoute: Route?
    private var preparedItem: PlaybackQueueItem?

    init(
        systemEngine: PlaybackEngine,
        rendererEngine: UPnPPlaybackEngine,
        selection: @escaping () -> Selection
    ) {
        self.systemEngine = systemEngine
        self.rendererEngine = rendererEngine
        self.selection = selection

        systemEngine.eventHandler = { [weak self] event in
            guard let self, self.activeRoute == .system else { return }
            self.eventHandler?(event)
        }
        rendererEngine.eventHandler = { [weak self] event in
            guard let self, case .renderer = self.activeRoute else { return }
            self.eventHandler?(event)
        }
    }

    func prepare(_ item: PlaybackQueueItem) async throws {
        preparedItem = item
        switch selection() {
        case .system:
            if case .renderer = activeRoute {
                await rendererEngine.stop()
            }
            activeRoute = .system
            try await systemEngine.prepare(item)

        case .renderer(let renderer):
            if activeRoute == .system {
                await systemEngine.stop()
            }
            rendererEngine.configure(renderer: renderer)
            activeRoute = .renderer(renderer.id)
            try await rendererEngine.prepare(item)

        case .unavailable(let name):
            throw UPnPPlaybackError.rendererUnavailable(name)
        }
    }

    func play() async throws {
        let desiredRoute = try desiredRoute()
        if activeRoute != desiredRoute {
            guard let preparedItem else {
                throw UPnPPlaybackError.rendererUnavailable("network renderer")
            }
            try await prepare(preparedItem)
        }

        switch activeRoute {
        case .system:
            try await systemEngine.play()
        case .renderer:
            try await rendererEngine.play()
        case nil:
            throw UPnPPlaybackError.rendererUnavailable("network renderer")
        }
    }

    func pause() async {
        switch activeRoute {
        case .system:
            await systemEngine.pause()
        case .renderer:
            await rendererEngine.pause()
        case nil:
            break
        }
    }

    func stop() async {
        switch activeRoute {
        case .system:
            await systemEngine.stop()
        case .renderer:
            await rendererEngine.stop()
        case nil:
            break
        }
        activeRoute = nil
        preparedItem = nil
    }

    func seek(to position: TimeInterval) async throws {
        switch activeRoute {
        case .system:
            try await systemEngine.seek(to: position)
        case .renderer:
            try await rendererEngine.seek(to: position)
        case nil:
            throw UPnPPlaybackError.rendererUnavailable("network renderer")
        }
    }

    func restoreOutputConfiguration() {
        systemEngine.restoreOutputConfiguration()
    }

    private func desiredRoute() throws -> Route {
        switch selection() {
        case .system:
            .system
        case .renderer(let renderer):
            .renderer(renderer.id)
        case .unavailable(let name):
            throw UPnPPlaybackError.rendererUnavailable(name)
        }
    }
}

extension OutputRoutingPlaybackEngine: PlaybackVolumeControlling {
    var canControlVolume: Bool {
        guard case .renderer(let renderer) = selection() else { return false }
        return renderer.renderingControl != nil
    }

    func outputVolumeState() async throws -> PlaybackVolumeState? {
        guard case .renderer(let renderer) = selection() else { return nil }
        rendererEngine.configure(renderer: renderer)
        return try await rendererEngine.outputVolumeState()
    }

    func setOutputVolume(_ level: Double) async throws -> PlaybackVolumeState? {
        guard case .renderer(let renderer) = selection() else { return nil }
        rendererEngine.configure(renderer: renderer)
        return try await rendererEngine.setOutputVolume(level)
    }

    func setOutputMuted(_ isMuted: Bool) async throws -> PlaybackVolumeState? {
        guard case .renderer(let renderer) = selection() else { return nil }
        rendererEngine.configure(renderer: renderer)
        return try await rendererEngine.setOutputMuted(isMuted)
    }
}

extension OutputRoutingPlaybackEngine: RendererPlaybackSessionControlling {
    func rendererSnapshot() async throws -> AVTransportSnapshot? {
        guard case .renderer(let renderer) = selection() else { return nil }
        rendererEngine.configure(renderer: renderer)
        return try await rendererEngine.rendererSnapshot()
    }

    func adoptRendererSession(
        item: PlaybackQueueItem,
        snapshot: AVTransportSnapshot
    ) async throws {
        guard case .renderer(let renderer) = selection() else {
            throw UPnPPlaybackError.rendererUnavailable("network renderer")
        }
        if activeRoute == .system {
            await systemEngine.stop()
        }
        preparedItem = item
        rendererEngine.configure(renderer: renderer)
        activeRoute = .renderer(renderer.id)
        try await rendererEngine.adoptRendererSession(
            item: item,
            snapshot: snapshot
        )
    }
}
