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
    let onDisconnect: () -> Void
    @Environment(\.dismiss) private var dismiss

    private enum NavidromeField: Hashable {
        case localAddress
        case remoteAddress
        case username
        case password
    }

    @FocusState private var focusedNavidromeField: NavidromeField?
    @State private var selectedSource: LibrarySource = .local
    @State private var isEditingSavedPassword = false

    private var localIsConnected: Bool {
        localLibrary.summary.folderCount > 0
    }

    private var navidromeIsConnected: Bool {
        navidromeConnection.savedProfile != nil
            && navidromeConnection.identity != nil
    }

    var body: some View {
        Group {
            #if os(iOS)
            NavigationStack {
                sourceForm
                    .navigationTitle("Music source")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            #else
            VStack(spacing: 0) {
                MusiCardsSettingsSheetHeader(title: "Music source") {
                    dismiss()
                }
                sourcePicker
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 8)
                sourceForm
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
            }
            .frame(
                width: MacWindowMetrics.contentSize.width - 4,
                height: MacWindowMetrics.contentSize.height * 0.78
            )
            #endif
        }
        .onAppear {
            syncSelectedSource()
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
            syncSelectedSource()
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
            syncSelectedSource()
        }
        .onChange(of: navidromeConnection.isConnecting) { wasConnecting, isConnecting in
            if wasConnecting && !isConnecting && isSavedNavidromeConnectionCurrent {
                isEditingSavedPassword = false
            }
        }
    }

    private var sourceForm: some View {
        Form {
            #if os(iOS)
            Section {
                sourcePicker
                    .listRowBackground(Color.clear)
            }
            #endif

            if selectedSource == .navidrome {
                navidromeContent
            } else {
                localContent
            }
        }
    }

    private var sourcePicker: some View {
        HStack(spacing: 12) {
            sourceButton(.local, title: "This device")
            sourceButton(.navidrome, title: "Navidrome")
        }
    }

    @ViewBuilder
    private func sourceButton(_ source: LibrarySource, title: String) -> some View {
        if selectedSource == source {
            Button {
                selectSource(source)
            } label: {
                Text(title)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        } else {
            Button {
                selectSource(source)
            } label: {
                Text(title)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private func selectSource(_ source: LibrarySource) {
        guard selectedSource != source else { return }
        switch selectedSource {
        case .local:
            localLibrary.cancelPendingFolderConnection()
        case .navidrome:
            navidromeConnection.cancelPendingVerification()
        }
        focusedNavidromeField = nil
        selectedSource = source
        activeLibrarySource = source
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

    @ViewBuilder
    private var localContent: some View {
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
            } else if localIsConnected {
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

            if localIsConnected {
                Button(role: .destructive, action: onDisconnect) {
                    Text("Disconnect library")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                }
                #if os(macOS)
                .buttonStyle(.plain)
                #endif
            }
        } footer: {
            VStack(alignment: .leading, spacing: 12) {
                if let errorMessage = localLibrary.connectionErrorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
                Text("To play music from this device, first prepare your music folder with MusiCards for Mac, then select it here. MusiCards creates the index (\(Text("library.json").bold())) needed to match your files with MusicBrainz; you don’t need to edit it yourself.")
                #if os(macOS)
                Text("Tag your files with MusicBrainz Picard first. Use Create / update library index on the home screen whenever you add or change music.")
                #else
                Text("Tag your files with MusicBrainz Picard first. Use MusiCards for Mac to update the index whenever you add or change music.")
                #endif
            }
            .font(.subheadline)
        }
    }

    @ViewBuilder
    private var navidromeContent: some View {
        Section("Navidrome server") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Local network address")
                TextField(
                    "",
                    text: $navidromeConnection.homeServerURL,
                    prompt: addressPrompt("http://server.local:4533")
                )
                .font(.system(.body, design: .monospaced))
                .accessibilityLabel("Local network address")
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                #else
                .labelsHidden()
                #endif
                .focused($focusedNavidromeField, equals: .localAddress)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Remote address")
                TextField(
                    "",
                    text: $navidromeConnection.remoteServerURL,
                    prompt: addressPrompt("https://")
                )
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Remote address")
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    #else
                    .labelsHidden()
                    #endif
                    .focused($focusedNavidromeField, equals: .remoteAddress)
            }
        }

        Section {
            LabeledContent("Username") {
                TextField(
                    "",
                    text: $navidromeConnection.username,
                    prompt: Text("Username")
                )
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("Username")
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    #else
                    .labelsHidden()
                    #endif
                    .focused($focusedNavidromeField, equals: .username)
            }

            LabeledContent("Password") {
                passwordControl
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
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                }
                #if os(macOS)
                .buttonStyle(.plain)
                #endif
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
                Text("Navidrome provides the music catalog and MusicBrainz IDs, so this source does not need \(Text("library.json").bold()). Tag your files with MusicBrainz Picard and let Navidrome scan them.")
                Text("For playback on \(Text("THIS DEVICE").bold()), enter at least one address.")
                Text("For playback on a \(Text("UPNP RENDERER").bold()), it must be able to reach the Navidrome server. A \(Text("LOCAL").bold()) network address is recommended.")
            }
            .font(.subheadline)
        }
    }

    private func addressPrompt(_ value: String) -> Text {
        Text(verbatim: value)
            .foregroundColor(.secondary)
    }

    @ViewBuilder
    private var passwordControl: some View {
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
                #if os(iOS)
                .textContentType(.password)
                #else
                .labelsHidden()
                #endif
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
}
