import SwiftUI

struct RemoteLocationSetupView: View {
    @Environment(\.dismiss) private var dismiss

    let onConnect: @MainActor (DestinationProfile, String) async throws -> Void

    @State private var displayName = ""
    @State private var host = ""
    @State private var username = ""
    @State private var remotePath = ""
    @State private var portText = "22"
    @State private var password = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Add Remote Location")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Connect once with an SSH password. MusiCards Sync installs its public key and uses key-based login afterward.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 13) {
                fieldRow("Name") {
                    TextField("Home Music Server", text: $displayName)
                }
                fieldRow("Hostname or IP") {
                    TextField("music-server.local", text: $host)
                }
                fieldRow("Username") {
                    TextField("music", text: $username)
                }
                fieldRow("Remote folder") {
                    TextField("/srv/music/", text: $remotePath)
                }
                fieldRow("SSH port") {
                    TextField("22", text: $portText)
                        .frame(width: 90)
                }
                fieldRow("SSH password") {
                    SecureField("Only required for first pairing", text: $password)
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(isConnecting)

            Text("The password is used only during pairing and is never saved. Existing paired locations can be added with the password field empty.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Pairing and checking remote rsync…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel") { dismiss() }
                    .disabled(isConnecting)

                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isConnecting || !hasRequiredFields)
            }
        }
        .padding(28)
        .frame(width: 560)
    }

    @ViewBuilder
    private func fieldRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)
            content()
        }
    }

    private var hasRequiredFields: Bool {
        !trimmed(displayName).isEmpty &&
            !trimmed(host).isEmpty &&
            !trimmed(username).isEmpty &&
            trimmed(remotePath).hasPrefix("/") &&
            validPort != nil
    }

    private var validPort: Int? {
        guard let port = Int(trimmed(portText)), (1...65_535).contains(port) else {
            return nil
        }
        return port
    }

    private func connect() {
        guard let port = validPort else { return }
        let path = trimmed(remotePath)
        let profile = DestinationProfile(
            name: trimmed(displayName),
            kind: .remote,
            user: trimmed(username),
            host: trimmed(host),
            port: port,
            path: path.hasSuffix("/") ? path : path + "/"
        )

        isConnecting = true
        errorMessage = nil
        Task {
            do {
                try await onConnect(profile, password)
                password = ""
                dismiss()
            } catch {
                password = ""
                errorMessage = error.localizedDescription
                isConnecting = false
            }
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
