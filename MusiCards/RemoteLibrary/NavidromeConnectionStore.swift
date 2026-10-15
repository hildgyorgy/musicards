import Combine
import Foundation

@MainActor
final class NavidromeConnectionStore: ObservableObject {
    @Published var serverName = ""
    @Published var serverURL = ""
    @Published var username = ""
    @Published var password = ""

    @Published private(set) var savedProfile: NavidromeServerProfile?
    @Published private(set) var identity: NavidromeServerIdentity?
    @Published private(set) var isConnecting = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasStoredPassword = false
    @Published private(set) var rendererServerURL: URL?
    @Published private(set) var isVerifyingRendererServer = false
    @Published private(set) var rendererServerStatusMessage: String?
    @Published private(set) var rendererServerErrorMessage: String?

    private struct PersistedConnection: Codable {
        let profile: NavidromeServerProfile
        let identity: NavidromeServerIdentity
    }

    private struct PersistedRendererConnection: Codable {
        let profileID: UUID
        let baseURL: URL
    }

    private let defaults: UserDefaults
    private let credentialStore: NavidromeCredentialStore
    private let client: OpenSubsonicClient
    private let storageKey = "NavidromeServerConnection.v1"
    private let rendererStorageKey = "NavidromeRendererConnection.v1"

    init(
        defaults: UserDefaults = .standard,
        credentialStore: NavidromeCredentialStore = .init(),
        client: OpenSubsonicClient = .init()
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        self.client = client
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
            let profile = try NavidromeServerProfile.validated(
                id: savedProfile?.id ?? UUID(),
                name: serverName,
                serverURL: serverURL,
                username: username
            )

            let enteredPassword = password
            let connectionPassword: String
            if !enteredPassword.isEmpty {
                connectionPassword = enteredPassword
            } else if let storedPassword = try credentialStore.password(for: profile.id) {
                connectionPassword = storedPassword
            } else {
                throw NavidromeConnectionStoreError.passwordRequired
            }

            let verifiedIdentity = try await client.identifyNavidrome(
                profile: profile,
                password: connectionPassword
            )

            let connection = PersistedConnection(
                profile: profile,
                identity: verifiedIdentity
            )
            let encodedConnection = try JSONEncoder().encode(connection)

            if !enteredPassword.isEmpty {
                try credentialStore.save(password: enteredPassword, for: profile.id)
            }
            defaults.set(encodedConnection, forKey: storageKey)

            savedProfile = profile
            identity = verifiedIdentity
            serverName = profile.name
            serverURL = profile.baseURL.absoluteString
            username = profile.username
            password = ""
            hasStoredPassword = true
            statusMessage = "Navidrome connection verified and saved."
        } catch {
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

    func rendererCredentials() throws -> NavidromeCatalogCredentials {
        let credentials = try catalogCredentials()
        guard let rendererServerURL else { return credentials }
        let rendererProfile = NavidromeServerProfile(
            id: credentials.profile.id,
            name: credentials.profile.name,
            baseURL: rendererServerURL,
            username: credentials.profile.username
        )
        return NavidromeCatalogCredentials(
            profile: rendererProfile,
            password: credentials.password
        )
    }

    func verifyAndSaveRendererServerURL(_ value: String) async {
        guard !isVerifyingRendererServer else { return }
        isVerifyingRendererServer = true
        rendererServerStatusMessage = nil
        rendererServerErrorMessage = nil
        defer { isVerifyingRendererServer = false }

        do {
            let credentials = try catalogCredentials()
            let baseURL = try NavidromeRendererServerURL.validated(value)
            let rendererProfile = NavidromeServerProfile(
                id: credentials.profile.id,
                name: credentials.profile.name,
                baseURL: baseURL,
                username: credentials.profile.username
            )
            _ = try await client.identifyNavidrome(
                profile: rendererProfile,
                password: credentials.password,
                allowsInsecureLocalHTTP: true
            )
            let saved = PersistedRendererConnection(
                profileID: credentials.profile.id,
                baseURL: baseURL
            )
            defaults.set(try JSONEncoder().encode(saved), forKey: rendererStorageKey)
            rendererServerURL = baseURL
            rendererServerStatusMessage = "Renderer address verified and saved."
        } catch {
            rendererServerErrorMessage = error.localizedDescription
        }
    }

    func useNormalServerAddressForRenderer() {
        defaults.removeObject(forKey: rendererStorageKey)
        rendererServerURL = nil
        rendererServerErrorMessage = nil
        rendererServerStatusMessage = "The renderer will use the normal Navidrome address."
    }

    private func loadSavedConnection() {
        guard let data = defaults.data(forKey: storageKey) else { return }

        do {
            let connection = try JSONDecoder().decode(PersistedConnection.self, from: data)
            savedProfile = connection.profile
            identity = connection.identity
            serverName = connection.profile.name
            serverURL = connection.profile.baseURL.absoluteString
            username = connection.profile.username
            hasStoredPassword = try credentialStore.password(for: connection.profile.id) != nil
            loadRendererConnection(for: connection.profile.id)

            if connection.profile.baseURL.scheme?.lowercased() != "https" {
                errorMessage = connection.profile.baseURL.scheme?.lowercased() == "http"
                    ? NavidromeProfileValidationError.secureConnectionRequired.localizedDescription
                    : NavidromeProfileValidationError.invalidServerURL.localizedDescription
            }
        } catch {
            errorMessage = "The saved Navidrome connection could not be read."
        }
    }

    private func loadRendererConnection(for profileID: UUID) {
        guard let data = defaults.data(forKey: rendererStorageKey),
              let connection = try? JSONDecoder().decode(
                PersistedRendererConnection.self,
                from: data
              ),
              connection.profileID == profileID else {
            rendererServerURL = nil
            return
        }
        rendererServerURL = connection.baseURL
    }

    private func resetFields() {
        serverName = ""
        serverURL = ""
        username = ""
        password = ""
        savedProfile = nil
        identity = nil
        hasStoredPassword = false
        rendererServerURL = nil
        isVerifyingRendererServer = false
        rendererServerStatusMessage = nil
        rendererServerErrorMessage = nil
        errorMessage = nil
    }
}

extension NavidromeConnectionStore: NavidromeCatalogConnectionProviding {}

nonisolated enum NavidromeConnectionStoreError: LocalizedError, Equatable, Sendable {
    case passwordRequired
    case serverNotConfigured

    var errorDescription: String? {
        switch self {
        case .passwordRequired:
            "Enter your Navidrome password."
        case .serverNotConfigured:
            "Connect a Navidrome server before loading its library."
        }
    }
}
