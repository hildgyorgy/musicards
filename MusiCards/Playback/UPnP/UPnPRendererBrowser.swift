import Foundation
import Combine

@MainActor
final class UPnPRendererBrowser: ObservableObject {
    enum State: Equatable {
        case idle
        case searching
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var renderers: [UPnPRendererDescriptor] = []
    @Published private(set) var snapshots: [String: AVTransportSnapshot] = [:]
    @Published private(set) var statusErrors: [String: String] = [:]
    @Published private(set) var checkingRendererIDs: Set<String> = []

    private let discoveryService: UPnPRendererDiscoveryService
    private let userDefaults: UserDefaults
    private var searchTask: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0
    private let knownRendererHostsKey = "UPnPKnownRendererHosts"

    init(
        discoveryService: UPnPRendererDiscoveryService = .init(),
        userDefaults: UserDefaults = .standard
    ) {
        self.discoveryService = discoveryService
        self.userDefaults = userDefaults
    }

    deinit {
        searchTask?.cancel()
    }

    func refresh(rendererAddress: String? = nil) {
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        state = .searching
        statusErrors = [:]
        let enteredHost = rendererAddress?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let knownHosts = userDefaults.stringArray(forKey: knownRendererHostsKey) ?? []
        var requestedHosts = knownHosts
        if let enteredHost, !enteredHost.isEmpty {
            requestedHosts.append(enteredHost)
        }
        let unicastHosts = Array(Set(requestedHosts)).sorted()

        searchTask = Task { [weak self, discoveryService] in
            do {
                let renderers = try await discoveryService.discover(
                    unicastHosts: unicastHosts
                )
                try Task.checkCancellation()
                guard let self, generation == self.searchGeneration else { return }
                self.renderers = renderers
                self.rememberHosts(from: renderers)
                self.state = .ready
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == self.searchGeneration else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private func rememberHosts(from renderers: [UPnPRendererDescriptor]) {
        let discoveredHosts = renderers.compactMap(\.descriptionURL.host)
        guard !discoveredHosts.isEmpty else { return }
        let existing = userDefaults.stringArray(forKey: knownRendererHostsKey) ?? []
        userDefaults.set(
            Array(Set(existing + discoveredHosts)).sorted(),
            forKey: knownRendererHostsKey
        )
    }

    func checkStatus(of renderer: UPnPRendererDescriptor) {
        guard !checkingRendererIDs.contains(renderer.id) else { return }
        checkingRendererIDs.insert(renderer.id)
        statusErrors[renderer.id] = nil

        Task { [weak self] in
            defer { self?.checkingRendererIDs.remove(renderer.id) }
            do {
                let snapshot = try await AVTransportClient(
                    service: renderer.avTransport
                ).snapshot()
                guard !Task.isCancelled else { return }
                self?.snapshots[renderer.id] = snapshot
            } catch is CancellationError {
                return
            } catch {
                self?.statusErrors[renderer.id] = error.localizedDescription
            }
        }
    }
}
