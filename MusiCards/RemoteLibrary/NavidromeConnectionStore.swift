import Combine
import Foundation
import OSLog

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

    func verifyAndSave() async {
        guard !isConnecting else { return }

        isConnecting = true
        statusMessage = nil
        errorMessage = nil
        defer { isConnecting = false }

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
                    verifiedEndpoints.append((address, endpointIdentity))
                } catch {
                    if firstVerificationError == nil {
                        firstVerificationError = error
                    }
                    Self.logger.notice(
                        "Navidrome endpoint verification failed host=\(address.host ?? "unknown", privacy: .private) error=\(error.localizedDescription, privacy: .private)"
                    )
                }
            }

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
            statusMessage = verifiedEndpoints.count == configuredAddresses.count
                ? "Navidrome connection verified and saved."
                : "Navidrome connection saved. The other address could not be verified from this network."
        } catch {
            Self.logger.error(
                "Navidrome connection could not be saved error=\(error.localizedDescription, privacy: .private)"
            )
            errorMessage = error.localizedDescription
        }
    }

    func removeServer() {
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
        return NavidromeCatalogCredentials(profile: profile, password: password)
    }

    /// UPnP renderers must receive an address reachable from the home network.
    /// If no separate HOME address exists, the normal active address is reused.
    func rendererCredentials() throws -> NavidromeCatalogCredentials {
        let credentials = try catalogCredentials()
        guard let homeBaseURL else { return credentials }
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
    func refreshReachableEndpoint() async {
        guard let currentProfile = savedProfile,
              let identity,
              let connectionPassword = try? credentialStore.password(
                  for: currentProfile.id
              ) else {
            return
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
                guard candidate.baseURL != currentProfile.baseURL else { return }
                try persist(
                    profile: candidate,
                    identity: identity,
                    homeBaseURL: homeBaseURL,
                    remoteBaseURL: remoteBaseURL
                )
                savedProfile = candidate
                Self.logger.info(
                    "Selected reachable Navidrome endpoint host=\(address.host ?? "unknown", privacy: .private)"
                )
                return
            } catch {
                Self.logger.debug(
                    "Navidrome endpoint is not reachable host=\(address.host ?? "unknown", privacy: .private) error=\(error.localizedDescription, privacy: .private)"
                )
                continue
            }
        }
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
            let migratedHomeURL = connection.homeBaseURL
                ?? legacyRendererURL
                ?? (connection.profile.baseURL.scheme?.lowercased() == "http"
                    ? connection.profile.baseURL : nil)
            let migratedRemoteURL = connection.remoteBaseURL
                ?? (connection.profile.baseURL.scheme?.lowercased() == "https"
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
        errorMessage = nil
    }
}

extension NavidromeConnectionStore: NavidromeCatalogConnectionProviding {}

nonisolated enum NavidromeConnectionStoreError: LocalizedError, Equatable, Sendable {
    case passwordRequired
    case serverNotConfigured
    case addressRequired
    case addressesDoNotMatch

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
        }
    }
}
