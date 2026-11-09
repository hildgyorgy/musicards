import Combine
import Foundation
import OSLog

nonisolated enum NavidromeEndpointState: Equatable, Sendable {
    case notConfigured, checking, local, remote, unavailable
}

@MainActor
final class NavidromeConnectionStore: ObservableObject {
    nonisolated private static let logger = Logger(
        subsystem: "com.hildgyorgy.MusiCards",
        category: "NavidromeConnection"
    )

    @Published var serverName = ""
    @Published var homeServerURL = ""
    @Published var remoteServerURL = ""
    @Published var username = ""
    @Published var password = ""

    @Published private(set) var savedProfile: NavidromeServerProfile?
    @Published private(set) var identity: NavidromeServerIdentity?
    @Published private(set) var homeBaseURL: URL?
    @Published private(set) var remoteBaseURL: URL?
    @Published private(set) var isConnecting = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasStoredPassword = false
    @Published private(set) var endpointState: NavidromeEndpointState = .notConfigured

    var canUseRenderer: Bool { endpointState == .local && homeBaseURL != nil }

    var activeEndpointURL: URL? {
        switch endpointState {
        case .local, .remote: savedProfile?.baseURL
        default: nil
        }
    }

    private struct PersistedConnection: Codable {
        let profile: NavidromeServerProfile
        let identity: NavidromeServerIdentity
        let homeBaseURL: URL?
        let remoteBaseURL: URL?

        init(
            profile: NavidromeServerProfile,
            identity: NavidromeServerIdentity,
            homeBaseURL: URL?,
            remoteBaseURL: URL?
        ) {
            self.profile = profile
            self.identity = identity
            self.homeBaseURL = homeBaseURL
            self.remoteBaseURL = remoteBaseURL
        }

        private enum CodingKeys: String, CodingKey {
            case profile
            case identity
            case homeBaseURL
            case remoteBaseURL
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            profile = try container.decode(
                NavidromeServerProfile.self,
                forKey: .profile
            )
            identity = try container.decode(
                NavidromeServerIdentity.self,
                forKey: .identity
            )
            homeBaseURL = try container.decodeIfPresent(
                URL.self,
                forKey: .homeBaseURL
            )
            remoteBaseURL = try container.decodeIfPresent(
                URL.self,
                forKey: .remoteBaseURL
            )
        }
    }

    /// Kept only so existing installations can migrate the old OUTPUT setting.
    private struct PersistedRendererConnection: Codable {
        let profileID: UUID
        let baseURL: URL
    }

    private let defaults: UserDefaults
    private let credentialStore: any NavidromeCredentialStoring
    private let client: any NavidromeIdentifying
    private let reachabilityClient: any NavidromeIdentifying
    private let storageKey = "NavidromeServerConnection.v1"
    private let rendererStorageKey = "NavidromeRendererConnection.v1"
    private var pendingVerificationID: UUID?
    private var pendingVerificationTask: Task<Void, Never>?
    private var reachabilityTask: Task<Void, Never>?
    private var reachabilityGeneration: UInt64 = 0
    private var lastReachabilityCheck: Date?

    init(
        defaults: UserDefaults = .standard,
        credentialStore: any NavidromeCredentialStoring = NavidromeCredentialStore(),
        client: any NavidromeIdentifying = OpenSubsonicClient(),
        reachabilityClient: (any NavidromeIdentifying)? = nil
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        self.client = client

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2.5
        configuration.timeoutIntervalForResource = 4
        self.reachabilityClient = reachabilityClient ?? OpenSubsonicClient(
            session: URLSession(configuration: configuration)
        )
        loadSavedConnection()
    }

    var isConfigured: Bool {
        savedProfile != nil && identity != nil && errorMessage == nil
    }

    @discardableResult
    func beginVerification() -> Task<Void, Never>? {
        guard pendingVerificationTask == nil, !isConnecting else { return nil }
        let task = Task { await verifyAndSave() }
        pendingVerificationTask = task
        return task
    }

    func cancelPendingVerification() {
        guard pendingVerificationID != nil || pendingVerificationTask != nil else { return }
        pendingVerificationID = nil
        pendingVerificationTask?.cancel()
        pendingVerificationTask = nil
        isConnecting = false
        statusMessage = nil
        errorMessage = nil
    }

    func verifyAndSave() async {
        guard !isConnecting, !Task.isCancelled else { return }

        let verificationID = UUID()
        pendingVerificationID = verificationID
        isConnecting = true
        statusMessage = nil
        errorMessage = nil
        defer {
            if pendingVerificationID == verificationID {
                pendingVerificationID = nil
                pendingVerificationTask = nil
                isConnecting = false
            }
        }

        do {
            let trimmedUsername = username.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmedUsername.isEmpty else {
                throw NavidromeProfileValidationError.usernameRequired
            }

            let profileID = savedProfile?.id ?? UUID()
            let name = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
            let verifiedHomeURL = try validatedHomeAddress(homeServerURL)
            let verifiedRemoteURL = try validatedRemoteAddress(remoteServerURL)
            guard verifiedHomeURL != nil || verifiedRemoteURL != nil else {
                throw NavidromeConnectionStoreError.addressRequired
            }

            let enteredPassword = password
            let connectionPassword: String
            if !enteredPassword.isEmpty {
                connectionPassword = enteredPassword
            } else if let storedPassword = try credentialStore.password(
                for: profileID
            ) {
                connectionPassword = storedPassword
            } else {
                throw NavidromeConnectionStoreError.passwordRequired
            }

            let configuredAddresses = [verifiedHomeURL, verifiedRemoteURL]
                .compactMap { $0 }
            var verifiedEndpoints: [(URL, NavidromeServerIdentity)] = []
            var firstVerificationError: Error?
            for address in configuredAddresses {
                let profile = makeProfile(
                    id: profileID,
                    name: name,
                    baseURL: address,
                    username: trimmedUsername
                )
                do {
                    let endpointIdentity = try await client.identifyNavidrome(
                        profile: profile,
                        password: connectionPassword,
                        allowsInsecureLocalHTTP: address.scheme?.lowercased() == "http"
                    )
                    try Task.checkCancellation()
                    guard pendingVerificationID == verificationID else { return }
                    verifiedEndpoints.append((address, endpointIdentity))
                } catch {
                    guard pendingVerificationID == verificationID,
                          !Task.isCancelled else { return }
                    if firstVerificationError == nil {
                        firstVerificationError = error
                    }
                    Self.logger.notice(
                        "Navidrome endpoint verification failed host=\(address.host ?? "unknown", privacy: .private) error=\(error.localizedDescription, privacy: .private)"
                    )
                }
            }

            try Task.checkCancellation()
            guard pendingVerificationID == verificationID else { return }
            guard let firstVerifiedEndpoint = verifiedEndpoints.first else {
                throw firstVerificationError
                    ?? NavidromeConnectionStoreError.addressRequired
            }
            guard verifiedEndpoints.dropFirst().allSatisfy({
                $0.1 == firstVerifiedEndpoint.1
            }) else {
                throw NavidromeConnectionStoreError.addressesDoNotMatch
            }

            let activeURL = firstVerifiedEndpoint.0
            let verifiedIdentity = firstVerifiedEndpoint.1
            let profile = makeProfile(
                id: profileID,
                name: name,
                baseURL: activeURL,
                username: trimmedUsername
            )
            let connection = PersistedConnection(
                profile: profile,
                identity: verifiedIdentity,
                homeBaseURL: verifiedHomeURL,
                remoteBaseURL: verifiedRemoteURL
            )

            if !enteredPassword.isEmpty {
                try credentialStore.save(password: enteredPassword, for: profile.id)
            }
            defaults.set(
                try JSONEncoder().encode(connection),
                forKey: storageKey
            )
            defaults.removeObject(forKey: rendererStorageKey)

            invalidateReachability()
            savedProfile = profile
            identity = verifiedIdentity
            homeBaseURL = verifiedHomeURL
            remoteBaseURL = verifiedRemoteURL
            serverName = profile.name
            homeServerURL = verifiedHomeURL?.absoluteString ?? ""
            remoteServerURL = verifiedRemoteURL?.absoluteString ?? ""
            username = profile.username
            password = ""
            hasStoredPassword = true
            endpointState = activeURL == verifiedHomeURL ? .local : .remote
            lastReachabilityCheck = Date()
            statusMessage = verifiedEndpoints.count == configuredAddresses.count
                ? "Navidrome connection verified and saved."
                : "Navidrome connection saved. The other address could not be verified from this network."
        } catch {
            guard pendingVerificationID == verificationID,
                  !Task.isCancelled else { return }
            Self.logger.error(
                "Navidrome connection could not be saved error=\(error.localizedDescription, privacy: .private)"
            )
            errorMessage = error.localizedDescription
        }
    }

    func removeServer() {
        cancelPendingVerification()
        invalidateReachability()
        do {
            if let profileID = savedProfile?.id {
                try credentialStore.deletePassword(for: profileID)
            }
            defaults.removeObject(forKey: storageKey)
            defaults.removeObject(forKey: rendererStorageKey)
            resetFields()
            statusMessage = "Navidrome server removed."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func catalogCredentials() throws -> NavidromeCatalogCredentials {
        guard let profile = savedProfile else {
            throw NavidromeConnectionStoreError.serverNotConfigured
        }
        guard let password = try credentialStore.password(for: profile.id) else {
            throw NavidromeConnectionStoreError.passwordRequired
        }
        guard endpointState != .unavailable else {
            throw NavidromeConnectionStoreError.serverUnavailable
        }
        return NavidromeCatalogCredentials(profile: profile, password: password)
    }

    /// Never substitute the app's remote/VPN address for a local renderer URL.
    func rendererCredentials() throws -> NavidromeCatalogCredentials {
        let credentials = try catalogCredentials()
        guard canUseRenderer, let homeBaseURL else {
            throw NavidromeConnectionStoreError.localConnectionRequired
        }
        return NavidromeCatalogCredentials(
            profile: makeProfile(
                id: credentials.profile.id,
                name: credentials.profile.name,
                baseURL: homeBaseURL,
                username: credentials.profile.username
            ),
            password: credentials.password
        )
    }

    /// Prefer HOME while it is reachable, otherwise use REMOTE. This is called
    /// when the app becomes active, so moving between home Wi-Fi and the road
    /// does not require changing the saved source.
    func refreshReachableEndpoint(force: Bool = true) async {
        if let reachabilityTask {
            await reachabilityTask.value
            return
        }
        // Playback reuses the verified route until a network change or a
        // foreground/SOURCE refresh invalidates it. Probing a failed home
        // address before every remote track would introduce audible gaps.
        if !force, endpointState == .local || endpointState == .remote { return }
        if !force, let lastReachabilityCheck {
            let age = Date().timeIntervalSince(lastReachabilityCheck)
            if age >= 0 && age < 5 { return }
        }
        let generation = reachabilityGeneration
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.checkReachableEndpoint(generation: generation)
        }
        reachabilityTask = task
        await task.value
        if generation == reachabilityGeneration { reachabilityTask = nil }
    }

    func networkDidChange() async {
        invalidateReachability()
        await refreshReachableEndpoint()
    }

    func requirePlaybackConnection() async throws {
        repeat {
            await refreshReachableEndpoint(force: false)
            try Task.checkCancellation()
        } while endpointState == .checking && reachabilityTask != nil
        guard endpointState == .local || endpointState == .remote else {
            throw NavidromeConnectionStoreError.serverUnavailable
        }
    }

    private func invalidateReachability() {
        reachabilityGeneration &+= 1
        reachabilityTask?.cancel()
        reachabilityTask = nil
        lastReachabilityCheck = nil
        endpointState = savedProfile == nil ? .notConfigured : .checking
    }

    private func checkReachableEndpoint(generation: UInt64) async {
        guard let currentProfile = savedProfile,
              let identity,
              let connectionPassword = try? credentialStore.password(
                  for: currentProfile.id
              ) else {
            endpointState = savedProfile == nil ? .notConfigured : .unavailable
            return
        }

        // A routine recheck does not temporarily revoke a working renderer
        // session. Network changes explicitly invalidate the previous result.
        if endpointState != .local && endpointState != .remote {
            endpointState = .checking
        }

        for address in [homeBaseURL, remoteBaseURL].compactMap({ $0 }) {
            let candidate = makeProfile(
                id: currentProfile.id,
                name: currentProfile.name,
                baseURL: address,
                username: currentProfile.username
            )
            do {
                _ = try await reachabilityClient.identifyNavidrome(
                    profile: candidate,
                    password: connectionPassword,
                    allowsInsecureLocalHTTP: address.scheme?.lowercased() == "http"
                )
                guard !Task.isCancelled, generation == reachabilityGeneration,
                      savedProfile?.id == currentProfile.id else { return }
                if candidate.baseURL != currentProfile.baseURL {
                    try persist(
                        profile: candidate,
                        identity: identity,
                        homeBaseURL: homeBaseURL,
                        remoteBaseURL: remoteBaseURL
                    )
                    savedProfile = candidate
                }
                endpointState = address == homeBaseURL ? .local : .remote
                lastReachabilityCheck = Date()
                Self.logger.info(
                    "Selected reachable Navidrome endpoint host=\(address.host ?? "unknown", privacy: .private)"
                )
                return
            } catch {
                guard !Task.isCancelled, generation == reachabilityGeneration else { return }
                Self.logger.debug(
                    "Navidrome endpoint is not reachable host=\(address.host ?? "unknown", privacy: .private) error=\(error.localizedDescription, privacy: .private)"
                )
                continue
            }
        }
        guard !Task.isCancelled, generation == reachabilityGeneration else { return }
        endpointState = .unavailable
        lastReachabilityCheck = Date()
    }

    private func validatedHomeAddress(_ value: String) throws -> URL? {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return try NavidromeRendererServerURL.validated(value)
    }

    private func validatedRemoteAddress(_ value: String) throws -> URL? {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return try NavidromeServerProfile.validated(
            id: savedProfile?.id ?? UUID(),
            name: serverName,
            serverURL: value,
            username: username.isEmpty ? "placeholder" : username
        ).baseURL
    }

    private func makeProfile(
        id: UUID,
        name: String,
        baseURL: URL,
        username: String
    ) -> NavidromeServerProfile {
        NavidromeServerProfile(
            id: id,
            name: name.isEmpty ? (baseURL.host ?? "Navidrome") : name,
            baseURL: baseURL,
            username: username
        )
    }

    private func persist(
        profile: NavidromeServerProfile,
        identity: NavidromeServerIdentity,
        homeBaseURL: URL?,
        remoteBaseURL: URL?
    ) throws {
        defaults.set(
            try JSONEncoder().encode(
                PersistedConnection(
                    profile: profile,
                    identity: identity,
                    homeBaseURL: homeBaseURL,
                    remoteBaseURL: remoteBaseURL
                )
            ),
            forKey: storageKey
        )
    }

    private func loadSavedConnection() {
        guard let data = defaults.data(forKey: storageKey) else { return }

        do {
            let connection = try JSONDecoder().decode(PersistedConnection.self, from: data)
            let legacyRendererURL = loadLegacyRendererConnection(
                for: connection.profile.id
            )
            let hasLegacySingleAddress = connection.homeBaseURL == nil
                && connection.remoteBaseURL == nil
            let migratedHomeURL = connection.homeBaseURL
                ?? legacyRendererURL
                ?? (hasLegacySingleAddress && connection.profile.baseURL.scheme?.lowercased() == "http"
                    ? connection.profile.baseURL : nil)
            let migratedRemoteURL = connection.remoteBaseURL
                ?? (hasLegacySingleAddress && connection.profile.baseURL.scheme?.lowercased() == "https"
                    ? connection.profile.baseURL : nil)

            let activeURL = migratedHomeURL
                ?? migratedRemoteURL
                ?? connection.profile.baseURL
            let activeProfile = makeProfile(
                id: connection.profile.id,
                name: connection.profile.name,
                baseURL: activeURL,
                username: connection.profile.username
            )

            savedProfile = activeProfile
            identity = connection.identity
            homeBaseURL = migratedHomeURL
            remoteBaseURL = migratedRemoteURL
            serverName = activeProfile.name
            homeServerURL = migratedHomeURL?.absoluteString ?? ""
            remoteServerURL = migratedRemoteURL?.absoluteString ?? ""
            username = activeProfile.username
            hasStoredPassword = try credentialStore.password(
                for: activeProfile.id
            ) != nil
            endpointState = .checking

            if connection.homeBaseURL == nil
                || connection.remoteBaseURL == nil
                || legacyRendererURL != nil {
                try persist(
                    profile: activeProfile,
                    identity: connection.identity,
                    homeBaseURL: migratedHomeURL,
                    remoteBaseURL: migratedRemoteURL
                )
                defaults.removeObject(forKey: rendererStorageKey)
            }
        } catch {
            errorMessage = "The saved Navidrome connection could not be read."
        }
    }

    private func loadLegacyRendererConnection(for profileID: UUID) -> URL? {
        guard let data = defaults.data(forKey: rendererStorageKey),
              let connection = try? JSONDecoder().decode(
                  PersistedRendererConnection.self,
                  from: data
              ),
              connection.profileID == profileID else {
            return nil
        }
        return connection.baseURL
    }

    private func resetFields() {
        serverName = ""
        homeServerURL = ""
        remoteServerURL = ""
        username = ""
        password = ""
        savedProfile = nil
        identity = nil
        homeBaseURL = nil
        remoteBaseURL = nil
        isConnecting = false
        hasStoredPassword = false
        endpointState = .notConfigured
        errorMessage = nil
    }
}

extension NavidromeConnectionStore: NavidromeCatalogConnectionProviding {}

nonisolated enum NavidromeConnectionStoreError: LocalizedError, Equatable, Sendable {
    case passwordRequired
    case serverNotConfigured
    case addressRequired
    case addressesDoNotMatch
    case localConnectionRequired
    case serverUnavailable

    var errorDescription: String? {
        switch self {
        case .passwordRequired:
            "Enter your Navidrome password."
        case .serverNotConfigured:
            "Connect a Navidrome server before loading its library."
        case .addressRequired:
            "Enter at least one Navidrome address."
        case .addressesDoNotMatch:
            "The Home and Remote addresses do not identify the same Navidrome server."
        case .localConnectionRequired:
            "UPnP playback requires an active local Navidrome connection. Choose System audio for remote playback."
        case .serverUnavailable:
            "Neither Navidrome address is reachable. Check your network or VPN connection and try again."
        }
    }
}
