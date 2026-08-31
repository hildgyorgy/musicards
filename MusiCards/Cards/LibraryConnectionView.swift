//
//  LibraryConnectionView.swift
//  MusiCards
//

import SwiftUI

struct LibraryConnectionView: View {
    @ObservedObject var localLibrary: LocalLibraryStore
    @ObservedObject var navidromeConnection: NavidromeConnectionStore
    @Binding var activeLibrarySource: LibrarySource?
    let onConnectExisting: () -> Void
    let onCreateOrUpdateIndex: (() -> Void)?
    let onDisconnect: () -> Void

    @State private var selectedSource: LibrarySource = .local

    @Environment(\.colorScheme) private var colorScheme

    private var localIsConnected: Bool {
        localLibrary.summary.folderCount > 0
            && localLibrary.connectionErrorMessage == nil
    }

    private var navidromeIsConnected: Bool {
        navidromeConnection.isConfigured
    }

    private func syncSelectedSource() {
        if let activeLibrarySource {
            selectedSource = activeLibrarySource
        } else if navidromeIsConnected && !localIsConnected {
            selectedSource = .navidrome
        } else {
            selectedSource = .local
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                sheetTitle

                HStack(spacing: 8) {
                    Text("LOCAL")
                        .foregroundStyle(
                            selectedSource == .navidrome ? .secondary : .primary
                        )

                    Toggle(
                        "",
                        isOn: Binding(
                            get: {
                                selectedSource == .navidrome
                            },
                            set: { isNavidrome in
                                let newSource: LibrarySource = isNavidrome ? .navidrome : .local
                                selectedSource = newSource

                                if localIsConnected && navidromeIsConnected {
                                    activeLibrarySource = newSource
                                }
                            }
                        )
                    )
                    .toggleStyle(.switch)
                    .tint(.blue)
                    .labelsHidden()

                    Text("NAVIDROME")
                        .foregroundStyle(
                            selectedSource == .navidrome ? .primary : .secondary
                        )
                }
                .font(.caption)
                .tracking(1.5)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)

                if selectedSource == .local {
                    localContent
                } else {
                    navidromeContent
                }
            }
            .padding(24)
            .onAppear {
                syncSelectedSource()
            }
            .onChange(of: navidromeIsConnected) { oldValue, newValue in
                if !oldValue && newValue {
                    selectedSource = .navidrome
                    activeLibrarySource = .navidrome
                } else if oldValue && !newValue {
                    activeLibrarySource = LibrarySourceSelectionPolicy
                        .sourceAfterDisconnect(
                            .navidrome,
                            activeSource: activeLibrarySource,
                            localIsConnected: localIsConnected,
                            navidromeIsConnected: false
                        )
                    syncSelectedSource()
                }
            }
            .onChange(of: localIsConnected) { oldValue, newValue in
                if !oldValue && newValue {
                    selectedSource = .local
                    activeLibrarySource = .local
                } else if oldValue && !newValue {
                    activeLibrarySource = LibrarySourceSelectionPolicy
                        .sourceAfterDisconnect(
                            .local,
                            activeSource: activeLibrarySource,
                            localIsConnected: false,
                            navidromeIsConnected: navidromeIsConnected
                        )
                    syncSelectedSource()
                }
            }
        }
        .scrollIndicators(.hidden)
        #if os(iOS)
        .presentationDetents([.fraction(0.45), .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    @ViewBuilder
    private var localContent: some View {
        if isConnected {
            connectedSummary

            Divider()
        } else {
            #if os(macOS)
            Text(disconnectedExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            #endif
        }

        #if os(macOS)
        action(
            title: localConnectionActionTitle,
            explanation: localConnectionExplanation,
            primary: !isConnected,
            action: onConnectExisting
        )

        if let onCreateOrUpdateIndex {
            action(
                title: "CREATE / UPDATE LIBRARY INDEX",
                explanation: "Select your music folder. MusiCards scans its tags, creates library.json, and connects it automatically.",
                primary: isConnected,
                action: onCreateOrUpdateIndex
            )
        }
        #else
        VStack(alignment: .leading, spacing: 5) {
            action(
                title: localConnectionActionTitle,
                explanation: localConnectionExplanation,
                primary: !isConnected,
                action: onConnectExisting
            )

            Text("Create or update library.json with MusiCards for Mac.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        #endif

        if isConnected {
            Divider()

            Button("DISCONNECT LIBRARY", role: .destructive) {
                onDisconnect()
            }
            .font(.system(.footnote, design: .monospaced).weight(.semibold))
            .tracking(1.5)
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }

        if let message = statusMessage {
            Text(message)
                .font(.footnote)
                .foregroundColor(
                    localLibrary.connectionErrorMessage == nil
                        ? .secondary : .red
                )
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var navidromeContent: some View {
        if navidromeConnection.isConfigured {
            navidromeConnectedContent
        } else {
            navidromeSetupContent
        }
    }

    private var navidromeConnectedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("CONNECTED")

            if let profile = navidromeConnection.savedProfile {
                VStack(alignment: .leading, spacing: 6) {
                    if let displayName = navidromeDisplayName(for: profile) {
                        Text(displayName)
                            .font(.headline)
                    }

                    Text(profile.baseURL.absoluteString)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Text(profile.username)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Button("DISCONNECT NAVIDROME", role: .destructive) {
                navidromeConnection.removeServer()
            }
            .font(.system(.footnote, design: .monospaced).weight(.semibold))
            .tracking(1.5)
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            if let errorMessage = navidromeConnection.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            #if os(macOS)
            if navidromeConnection.errorMessage == nil,
               let statusMessage = navidromeConnection.statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #endif
        }
    }

    private var navidromeSetupContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("SERVER")

            TextField("https://example.com", text: $navidromeConnection.serverURL)
                .textFieldStyle(.roundedBorder)

            Text("Enter the address of your Navidrome server.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField("Username", text: $navidromeConnection.username)
                .textFieldStyle(.roundedBorder)

            SecureField("Password", text: $navidromeConnection.password)
                .textFieldStyle(.roundedBorder)

            Button {
                Task {
                    await navidromeConnection.verifyAndSave()
                }
            } label: {
                Text(navidromeConnection.isConnecting ? "CONNECTING..." : "CONNECT")
                    .font(.system(.footnote, design: .monospaced).weight(.semibold))
                    .tracking(1.5)
                    .foregroundStyle(connectionButtonForeground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background {
                        Capsule(style: .continuous)
                            .fill(connectionButtonBackground)
                    }
            }
            .buttonStyle(.plain)
            .disabled(navidromeConnection.isConnecting)

            if let errorMessage = navidromeConnection.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            #if os(macOS)
            if let statusMessage = navidromeConnection.statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #endif
        }
    }

    private var connectedSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("CONNECTED")
        }
    }

    @ViewBuilder
    private var sheetTitle: some View {
        sectionTitle("MUSIC LIBRARY")
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var localConnectionActionTitle: String {
        isConnected
            ? "CONNECT A MUSIC LIBRARY"
            : "CONNECT EXISTING LIBRARY"
    }

    private var localConnectionExplanation: String {
        #if os(iOS)
        "Select a music library containing a valid library.json."
        #else
        "Select a music folder that already contains library.json."
        #endif
    }

    private func navidromeDisplayName(
        for profile: NavidromeServerProfile
    ) -> String? {
        let name = profile.name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !name.isEmpty else { return nil }

        let host = URLComponents(
            url: profile.baseURL,
            resolvingAgainstBaseURL: false
        )?.host ?? ""
        guard name.caseInsensitiveCompare(
            host
        ) != .orderedSame else {
            return nil
        }

        return name
    }

    private func action(
        title: String,
        explanation: String,
        primary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Button(action: action) {
                Text(title)
                    .font(.system(.footnote, design: .monospaced).weight(.semibold))
                    .tracking(1.5)
                    .foregroundStyle(actionForeground(primary: primary))
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background {
                        Capsule(style: .continuous)
                            .fill(actionBackground(primary: primary))
                    }
            }
            .buttonStyle(.plain)
            .disabled(localLibrary.isScanning)

            Text(explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(.headline, design: .monospaced).weight(.semibold))
            .tracking(2)
    }

    private var connectionButtonForeground: Color {
        #if os(iOS)
        .black
        #else
        colorScheme == .dark ? .black : .white
        #endif
    }

    private var connectionButtonBackground: Color {
        #if os(iOS)
        .white
        #else
        .primary
        #endif
    }

    private func actionForeground(primary: Bool) -> Color {
        #if os(iOS)
        .black
        #else
        primary
            ? (colorScheme == .dark ? .black : .white)
            : .primary
        #endif
    }

    private func actionBackground(primary: Bool) -> Color {
        #if os(iOS)
        .white
        #else
        primary ? .primary : .primary.opacity(0.08)
        #endif
    }

    private var isConnected: Bool {
        localLibrary.summary.folderCount > 0
            && localLibrary.connectionErrorMessage == nil
    }

    private var disconnectedExplanation: String {
        #if os(macOS)
        "Connect an indexed music folder, or prepare one here."
        #else
        "Connect an indexed music folder, or prepare one on a Mac."
        #endif
    }

    private var statusMessage: String? {
        localLibrary.connectionErrorMessage ?? (
            localLibrary.isScanning ? localLibrary.statusMessage : nil
        )
    }
}
