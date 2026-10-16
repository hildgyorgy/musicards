import Foundation
import Combine

@MainActor
final class UPnPRendererBrowser: ObservableObject {
    enum DiscoveryMethod: String, CaseIterable, Identifiable {
        case multicast
        case subnetSweep
        case rememberedAddress
        case manualAddress

        var id: String { rawValue }

        var title: String {
            switch self {
            case .multicast: "MULTICAST SSDP"
            case .subnetSweep: "DEEP SEARCH"
            case .rememberedAddress: "STORED ADDRESS"
            case .manualAddress: "MANUAL ADDRESS"
            }
        }

        var explanation: String {
            switch self {
            case .multicast:
                "to 239.255.255.250"
            case .rememberedAddress:
                "saved renderer IP"
            case .subnetSweep:
                "local /24 subnet"
            case .manualAddress:
                "renderer IP"
            }
        }
    }

    enum DiscoveryStageState: Equatable {
        case waiting
        case searching
        case found([UPnPRendererDescriptor])
        case noResult
        case unavailable(String)
        case failed(String)

        var isSearching: Bool {
            if case .searching = self { return true }
            return false
        }
    }

    @Published private(set) var stageStates: [DiscoveryMethod: DiscoveryStageState]
    @Published private(set) var snapshots: [String: AVTransportSnapshot] = [:]
    @Published private(set) var statusErrors: [String: String] = [:]
    @Published private(set) var checkingRendererIDs: Set<String> = []
    @Published private(set) var hasStartedAutomaticDiscovery = false
    @Published private(set) var selectedRenderer: UPnPRendererDescriptor?
    @Published private(set) var selectedRendererDisplayName: String?
    @Published private(set) var draftRendererID: String?

    var isSearching: Bool {
        stageStates.values.contains { $0.isSearching }
    }

    var hasSelectedRendererPreference: Bool {
        selectedRendererID != nil
    }

    var selectionCommitHandler: (() -> Void)?
    var selectedRendererResolvedHandler: (() -> Void)?

    private let discoveryService: UPnPRendererDiscoveryService
    private let userDefaults: UserDefaults
    private var searchTask: Task<Void, Never>?
    private var passiveListeningTask: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0
    private let knownRendererHostsKey = "UPnPKnownRendererHosts"
    private let selectedRendererIDKey = "UPnPSelectedRendererID"
    private let selectedRendererNameKey = "UPnPSelectedRendererName"
    private var selectedRendererID: String?
    private var draftRenderer: UPnPRendererDescriptor?

    init(
        discoveryService: UPnPRendererDiscoveryService = .init(),
        userDefaults: UserDefaults = .standard
    ) {
        self.discoveryService = discoveryService
        self.userDefaults = userDefaults
        self.selectedRendererID = userDefaults.string(
            forKey: selectedRendererIDKey
        )
        self.selectedRendererDisplayName = userDefaults.string(
            forKey: selectedRendererNameKey
        )
        self.stageStates = Dictionary(
            uniqueKeysWithValues: DiscoveryMethod.allCases.map { ($0, .waiting) }
        )
    }

    deinit {
        searchTask?.cancel()
        passiveListeningTask?.cancel()
    }

    func state(for method: DiscoveryMethod) -> DiscoveryStageState {
        stageStates[method] ?? .waiting
    }

    func beginRendererSelection() {
        draftRendererID = selectedRendererID
        draftRenderer = selectedRenderer
    }

    func isDraftSelected(_ renderer: UPnPRendererDescriptor) -> Bool {
        draftRendererID == renderer.id
    }

    func toggleDraftSelection(of renderer: UPnPRendererDescriptor) {
        if isDraftSelected(renderer) {
            draftRendererID = nil
            draftRenderer = nil
        } else {
            draftRendererID = renderer.id
            draftRenderer = renderer
        }
    }

    func clearDraftRendererSelection() {
        draftRendererID = nil
        draftRenderer = nil
    }

    func commitRendererSelection() {
        selectedRendererID = draftRendererID
        if let draftRenderer {
            selectedRenderer = draftRenderer
            selectedRendererDisplayName = draftRenderer.friendlyName
        } else if draftRendererID == nil {
            selectedRenderer = nil
            selectedRendererDisplayName = nil
        }

        if let selectedRendererID,
           let selectedRendererDisplayName {
            userDefaults.set(selectedRendererID, forKey: selectedRendererIDKey)
            userDefaults.set(
                selectedRendererDisplayName,
                forKey: selectedRendererNameKey
            )
        } else {
            userDefaults.removeObject(forKey: selectedRendererIDKey)
            userDefaults.removeObject(forKey: selectedRendererNameKey)
        }

        selectionCommitHandler?()
    }

    func cancelRendererSelection() {
        draftRendererID = selectedRendererID
        draftRenderer = selectedRenderer
    }

    func refresh() {
        beginNewSearch()
        hasStartedAutomaticDiscovery = true
        statusErrors = [:]
        for method in [
            DiscoveryMethod.multicast,
            .rememberedAddress
        ] {
            setState(.waiting, for: method)
        }

        let generation = searchGeneration
        searchTask = Task { [weak self, discoveryService] in
            guard let self else { return }
            guard await self.runStage(
                .multicast,
                mode: .multicast,
                timeout: 2.5,
                generation: generation,
                discoveryService: discoveryService
            ) else { return }

            let knownHosts = self.userDefaults.stringArray(
                forKey: self.knownRendererHostsKey
            ) ?? []
            if knownHosts.isEmpty {
                guard generation == self.searchGeneration else { return }
                self.setState(
                    .unavailable("No successful renderer address is saved yet."),
                    for: .rememberedAddress
                )
            } else {
                guard await self.runStage(
                    .rememberedAddress,
                    mode: .unicast(hosts: knownHosts),
                    timeout: 2.5,
                    generation: generation,
                    discoveryService: discoveryService
                ) else { return }
            }

        }
    }

    func searchMulticast() {
        beginNewSearch()
        let generation = searchGeneration
        searchTask = Task { [weak self, discoveryService] in
            guard let self else { return }
            _ = await self.runStage(
                .multicast,
                mode: .multicast,
                timeout: 2.5,
                generation: generation,
                discoveryService: discoveryService
            )
        }
    }

    func searchRememberedAddresses() {
        beginNewSearch()
        let generation = searchGeneration
        let knownHosts = userDefaults.stringArray(
            forKey: knownRendererHostsKey
        ) ?? []
        guard !knownHosts.isEmpty else {
            setState(
                .unavailable("No successful renderer address is saved yet."),
                for: .rememberedAddress
            )
            return
        }
        searchTask = Task { [weak self, discoveryService] in
            guard let self else { return }
            _ = await self.runStage(
                .rememberedAddress,
                mode: .unicast(hosts: knownHosts),
                timeout: 2.5,
                generation: generation,
                discoveryService: discoveryService
            )
        }
    }

    func startPassiveListening() {
        guard passiveListeningTask == nil else { return }
        passiveListeningTask = Task { [weak self, discoveryService] in
            while !Task.isCancelled {
                do {
                    let renderers = try await discoveryService.discover(
                        timeout: 15,
                        mode: .passive
                    )
                    try Task.checkCancellation()
                    self?.mergePassiveRenderers(renderers)
                } catch is CancellationError {
                    return
                } catch {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    func stopPassiveListening() {
        passiveListeningTask?.cancel()
        passiveListeningTask = nil
    }

    func deepSearch() {
        beginNewSearch()
        let generation = searchGeneration
        searchTask = Task { [weak self, discoveryService] in
            guard let self else { return }
            _ = await self.runStage(
                .subnetSweep,
                mode: .subnetSweep,
                timeout: 4.0,
                generation: generation,
                discoveryService: discoveryService
            )
        }
    }

    func findRenderer(at address: String) {
        let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        beginNewSearch()
        let generation = searchGeneration
        searchTask = Task { [weak self, discoveryService] in
            guard let self else { return }
            _ = await self.runStage(
                .manualAddress,
                mode: .unicast(hosts: [host]),
                timeout: 2.5,
                generation: generation,
                discoveryService: discoveryService
            )
        }
    }

    private func beginNewSearch() {
        searchTask?.cancel()
        searchGeneration &+= 1
        let searchingMethods = stageStates.compactMap { method, state in
            state.isSearching ? method : nil
        }
        for method in searchingMethods {
            setState(.waiting, for: method)
        }
    }

    private func runStage(
        _ method: DiscoveryMethod,
        mode: SSDPDiscoveryMode,
        timeout: TimeInterval,
        generation: UInt64,
        discoveryService: UPnPRendererDiscoveryService
    ) async -> Bool {
        guard generation == searchGeneration else { return false }
        setState(.searching, for: method)
        do {
            let renderers = try await discoveryService.discover(
                timeout: timeout,
                mode: mode
            )
            try Task.checkCancellation()
            guard generation == searchGeneration else { return false }
            setState(renderers.isEmpty ? .noResult : .found(renderers), for: method)
            rememberHosts(from: renderers)
            reconcileSelection(with: renderers)
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard generation == searchGeneration else { return false }
            setState(.failed(error.localizedDescription), for: method)
            return true
        }
    }

    private func setState(
        _ state: DiscoveryStageState,
        for method: DiscoveryMethod
    ) {
        stageStates[method] = state
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

    private func mergePassiveRenderers(
        _ renderers: [UPnPRendererDescriptor]
    ) {
        guard !renderers.isEmpty else { return }
        let existing: [UPnPRendererDescriptor]
        if case let .found(current) = state(for: .multicast) {
            existing = current
        } else {
            existing = []
        }
        var mergedByID = Dictionary(
            uniqueKeysWithValues: existing.map { ($0.id, $0) }
        )
        for renderer in renderers {
            mergedByID[renderer.id] = renderer
        }
        let merged = mergedByID.values.sorted {
            $0.friendlyName.localizedCaseInsensitiveCompare($1.friendlyName)
                == .orderedAscending
        }
        setState(.found(merged), for: .multicast)
        rememberHosts(from: renderers)
        reconcileSelection(with: renderers)
    }

    private func reconcileSelection(
        with renderers: [UPnPRendererDescriptor]
    ) {
        guard let selectedRendererID,
              let renderer = renderers.first(where: {
                  $0.id == selectedRendererID
              }) else { return }
        let didResolveRenderer = selectedRenderer != renderer
        selectedRenderer = renderer
        selectedRendererDisplayName = renderer.friendlyName
        if draftRendererID == renderer.id {
            draftRenderer = renderer
        }
        userDefaults.set(renderer.friendlyName, forKey: selectedRendererNameKey)
        if didResolveRenderer {
            selectedRendererResolvedHandler?()
        }
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
