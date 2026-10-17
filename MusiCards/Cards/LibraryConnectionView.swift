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
    let onClose: () -> Void
    let initialDraftSource: LibrarySource?
    let onDraftSourceChange: ((LibrarySource) -> Void)?

    @State private var selectedSource: LibrarySource = .local

    #if os(iOS)
    private enum NavidromeField: Hashable {
        case localAddress
        case remoteAddress
        case username
        case password
    }

    @FocusState private var focusedNavidromeField: NavidromeField?
    @State private var isEditingSavedPassword = false
    #endif

    @Environment(\.colorScheme) private var colorScheme

    private var localIsConnected: Bool {
        localLibrary.summary.folderCount > 0
    }

    private var navidromeIsConnected: Bool {
        navidromeConnection.savedProfile != nil
            && navidromeConnection.identity != nil
    }

    private func syncSelectedSource(restoreDraft: Bool = true) {
        if restoreDraft, let initialDraftSource {
            selectedSource = initialDraftSource
        } else if let activeLibrarySource {
            selectedSource = activeLibrarySource
        } else if navidromeIsConnected && !localIsConnected {
            selectedSource = .navidrome
        } else {
            selectedSource = .local
        }
    }

    private func cancelPendingConnection(for source: LibrarySource) {
        switch source {
        case .local:
            localLibrary.cancelPendingFolderConnection()
        case .navidrome:
            navidromeConnection.cancelPendingVerification()
        }
    }

    var body: some View {
        #if os(iOS)
        iosSourceSheet
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

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
                                let nextSource: LibrarySource = isNavidrome
                                    ? .navidrome : .local
                                if selectedSource != nextSource {
                                    cancelPendingConnection(for: selectedSource)
                                }
                                selectedSource = nextSource
                                onDraftSourceChange?(selectedSource)
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
                .padding(.top, 8)
                .padding(.bottom, 16)

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
                    onDraftSourceChange?(selectedSource)
                } else if oldValue && !newValue {
                    activeLibrarySource = LibrarySourceSelectionPolicy
                        .sourceAfterDisconnect(
                            .navidrome,
                            activeSource: activeLibrarySource,
                            localIsConnected: localIsConnected,
                            navidromeIsConnected: false
                        )
                    syncSelectedSource(restoreDraft: false)
                    onDraftSourceChange?(selectedSource)
                }
            }
            .onChange(of: localIsConnected) { oldValue, newValue in
                if !oldValue && newValue {
                    selectedSource = .local
                    onDraftSourceChange?(selectedSource)
                } else if oldValue && !newValue {
                    activeLibrarySource = LibrarySourceSelectionPolicy
                        .sourceAfterDisconnect(
                            .local,
                            activeSource: activeLibrarySource,
                            localIsConnected: false,
                            navidromeIsConnected: navidromeIsConnected
                        )
                    syncSelectedSource(restoreDraft: false)
                    onDraftSourceChange?(selectedSource)
                }
            }
        }
        .scrollIndicators(.hidden)
        #endif
    }

    #if os(iOS)
    private var iosSourceSheet: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        sourceButton(.local, title: "This device")
                        sourceButton(.navidrome, title: "Navidrome")
                    }
                    .listRowBackground(Color.clear)
                }

                if selectedSource == .navidrome {
                    iosNavidromeContent
                } else {
                    iosLocalContent
                }
            }
            .navigationTitle("Music source")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            syncSelectedSource(restoreDraft: false)
            if activeLibrarySource == nil {
                activeLibrarySource = selectedSource
            }
        }
        .onChange(of: navidromeIsConnected) { oldValue, newValue in
            guard oldValue && !newValue else { return }
            activeLibrarySource = LibrarySourceSelectionPolicy
                .sourceAfterDisconnect(
                    .navidrome,
                    activeSource: activeLibrarySource,
                    localIsConnected: localIsConnected,
                    navidromeIsConnected: false
                ) ?? .local
            syncSelectedSource(restoreDraft: false)
        }
        .onChange(of: localIsConnected) { oldValue, newValue in
            guard oldValue && !newValue else { return }
            activeLibrarySource = LibrarySourceSelectionPolicy
                .sourceAfterDisconnect(
                    .local,
                    activeSource: activeLibrarySource,
                    localIsConnected: false,
                    navidromeIsConnected: navidromeIsConnected
                ) ?? .local
            syncSelectedSource(restoreDraft: false)
        }
        .onChange(of: navidromeConnection.isConnecting) { wasConnecting, isConnecting in
            if wasConnecting && !isConnecting && isSavedNavidromeConnectionCurrent {
                isEditingSavedPassword = false
            }
        }
    }

    @ViewBuilder
    private func sourceButton(_ source: LibrarySource, title: String) -> some View {
        if selectedSource == source {
            Button {
                selectSource(source)
            } label: {
                Text(title)
                    .frame(maxWidth: .infinity)
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        } else {
            Button {
                selectSource(source)
            } label: {
                Text(title)
                    .frame(maxWidth: .infinity)
            }
                .buttonStyle(.bordered)
                .controlSize(.regular)
        }
    }

    private func selectSource(_ source: LibrarySource) {
        guard selectedSource != source else { return }
        cancelPendingConnection(for: selectedSource)
        focusedNavidromeField = nil
        selectedSource = source
        activeLibrarySource = source
    }

    @ViewBuilder
    private var iosLocalContent: some View {
        Section {
            Button(action: onConnectExisting) {
                HStack {
                    Text("Select music folder")
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(localLibrary.isScanning)

            if let selectedFolderDisplayPath = localLibrary.selectedFolderDisplayPath {
                Text(selectedFolderDisplayPath)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } else {
                Text("No folder selected")
                    .foregroundStyle(.secondary)
            }
        }

        Section {
            if localLibrary.isScanning {
                Text("Connecting…")
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            } else if localLibrary.summary.folderCount > 0 {
                Text("Connected")
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            } else {
                Text("Not connected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            }

            if localLibrary.summary.folderCount > 0 {
                Button(role: .destructive, action: onDisconnect) {
                    Text("Disconnect library")
                        .frame(maxWidth: .infinity)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 12) {
                if let errorMessage = localLibrary.connectionErrorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
                Text("MusiCards is built around MusicBrainz metadata. To play music files selected through Files, it deliberately requires a valid \(Text("library.json").bold()) in that folder. The index matches your files to MusicBrainz releases and tracks.")
                Text("Create or update \(Text("library.json").bold()) with \(Text("MusiCards for Mac").bold()) from MusicBrainz Picard-tagged files, then select the same folder here.")
            }
            .font(.subheadline)
        }
    }

    @ViewBuilder
    private var iosNavidromeContent: some View {
        Section("Navidrome server") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Local network address")
                TextField(
                    "http://server.local:4533",
                    text: $navidromeConnection.homeServerURL
                )
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                .focused($focusedNavidromeField, equals: .localAddress)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Remote address")
                TextField(
                    "https://",
                    text: $navidromeConnection.remoteServerURL
                )
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                .focused($focusedNavidromeField, equals: .remoteAddress)
            }
        }

        Section {
            LabeledContent("Username") {
                TextField("Username", text: $navidromeConnection.username)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .focused($focusedNavidromeField, equals: .username)
            }

            LabeledContent("Password") {
                iosPasswordControl
            }
        }

        Section {
            if isSavedNavidromeConnectionCurrent {
                Text("Connected")
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            } else if navidromeConnection.isConnecting {
                Text("Connecting…")
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            } else {
                Button {
                    focusedNavidromeField = nil
                    navidromeConnection.beginVerification()
                } label: {
                    Text("Connect")
                        .frame(maxWidth: .infinity)
                }
                .tint(.blue)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            }

            if navidromeConnection.savedProfile != nil {
                Button(role: .destructive) {
                    focusedNavidromeField = nil
                    isEditingSavedPassword = false
                    navidromeConnection.removeServer()
                } label: {
                    Text("Disconnect Navidrome")
                        .frame(maxWidth: .infinity)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 12) {
                if let errorMessage = navidromeConnection.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                } else if let statusMessage = navidromeConnection.statusMessage,
                          statusMessage.contains("other address") {
                    Text(statusMessage)
                }
                Text("For playback on \(Text("THIS DEVICE").bold()), enter at least one address.")
                Text("For playback on a \(Text("UPNP RENDERER").bold()), it must be able to reach the Navidrome server. A \(Text("LOCAL").bold()) network address is recommended.")
            }
            .font(.subheadline)
        }
    }

    @ViewBuilder
    private var iosPasswordControl: some View {
        if navidromeConnection.hasStoredPassword
            && navidromeConnection.password.isEmpty
            && !isEditingSavedPassword {
            Button {
                isEditingSavedPassword = true
                Task { @MainActor in
                    await Task.yield()
                    focusedNavidromeField = .password
                }
            } label: {
                Text("••••••••••••")
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Change saved password")
        } else {
            SecureField("Password", text: $navidromeConnection.password)
                .multilineTextAlignment(.trailing)
                .textContentType(.password)
                .focused($focusedNavidromeField, equals: .password)
        }
    }

    private var isSavedNavidromeConnectionCurrent: Bool {
        guard navidromeConnection.isConfigured,
              let profile = navidromeConnection.savedProfile,
              navidromeConnection.hasStoredPassword,
              navidromeConnection.password.isEmpty else {
            return false
        }
        return navidromeConnection.homeServerURL.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) == (navidromeConnection.homeBaseURL?.absoluteString ?? "")
            && navidromeConnection.remoteServerURL.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) == (navidromeConnection.remoteBaseURL?.absoluteString ?? "")
            && navidromeConnection.username.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) == profile.username
    }
    #endif

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

                    if let homeURL = navidromeConnection.homeBaseURL {
                        endpointRow("HOME", url: homeURL)
                    }

                    if let remoteURL = navidromeConnection.remoteBaseURL {
                        endpointRow("REMOTE", url: remoteURL)
                    }

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
        VStack(alignment: .leading, spacing: 16) {
            Text("CONNECT TO YOUR NAVIDROME SERVER")
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(.blue)
                .padding(.bottom, 12)

            sectionTitle("LOCAL ADDRESS")

            TextField(
                "http://server.local:4533",
                text: $navidromeConnection.homeServerURL
            )
            .popupAddressFieldStyle()

            PopupSectionDivider()
                .padding(.vertical, 10)

            sectionTitle("REMOTE ADDRESS")

            TextField(
                "https://",
                text: $navidromeConnection.remoteServerURL
            )
            .popupAddressFieldStyle()

            PopupSectionDivider()
                .padding(.vertical, 10)

            sectionTitle("ACCOUNT")

            TextField("Username", text: $navidromeConnection.username)
                .popupOutlinedFieldStyle()

            SecureField("Password", text: $navidromeConnection.password)
                .popupOutlinedFieldStyle()

            HStack(alignment: .top, spacing: 12) {
                Text("For playback on \(Text("THIS DEVICE").bold()), enter at least one address.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button {
                    navidromeConnection.beginVerification()
                } label: {
                    Text(navidromeConnection.isConnecting ? "CONNECTING..." : "CONNECT")
                        .font(.system(.footnote, design: .monospaced).weight(.semibold))
                        .tracking(1.5)
                        .foregroundStyle(connectionButtonForeground)
                        .padding(.horizontal, 18)
                        .frame(height: 36)
                        .background(connectionButtonBackground, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(
                    navidromeConnection.isConnecting
                        || !hasEnteredNavidromeAddress
                )
            }

            Text("For controlling playback on a \(Text("UPNP RENDERER").bold()), the renderer must be able to reach the Navidrome address. \(Text("LOCAL").bold()) address is recommended.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

    private func endpointRow(_ label: String, url: URL) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
            Text(url.absoluteString)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var hasEnteredNavidromeAddress: Bool {
        !navidromeConnection.homeServerURL.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
            || !navidromeConnection.remoteServerURL.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
    }

    private var connectedSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("CONNECTED")
        }
    }

    private var header: some View {
        ZStack {
            Text("MUSIC SOURCE")
                .font(.system(.headline, design: .monospaced))
                .tracking(2)

            HStack {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.medium))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")

                Spacer()

                Button("OK") {
                    activeLibrarySource = selectedSource
                    onClose()
                }
                #if os(iOS)
                .buttonStyle(.borderless)
                .tint(.accentColor)
                #else
                .font(.system(.footnote, design: .monospaced).weight(.bold))
                .buttonStyle(.borderedProminent)
                .clipShape(Capsule())
                #endif
                .disabled(
                    selectedSource == .local
                        ? !localIsConnected
                        : !navidromeIsConnected
                )
            }
        }
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
        colorScheme == .dark ? .black : .white
    }

    private var connectionButtonBackground: Color {
        colorScheme == .dark ? .white : .black
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

private extension View {
    func popupOutlinedFieldStyle() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .overlay(Capsule().stroke(Color.primary, lineWidth: 1))
    }

    @ViewBuilder
    func popupAddressFieldStyle() -> some View {
        #if os(iOS)
        popupOutlinedFieldStyle()
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
        #else
        popupOutlinedFieldStyle()
        #endif
    }
}
