//
//  DeckBackgroundView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 14..
//

import SwiftUI
import UniformTypeIdentifiers

struct DeckBackgroundView: View {

    @ObservedObject var localLibrary: LocalLibraryStore
    @ObservedObject var libraryManager: LibraryManager
    @ObservedObject var navidromeConnection: NavidromeConnectionStore
    @Binding var activeLibrarySource: LibrarySource?
    let onSelectMusicFolder: ((URL) -> Void)?
    let onCreateOrUpdateLibraryIndex: ((URL) -> Void)?
    let onDisconnectLibrary: (() -> Void)?
    let onShowAbout: (() -> Void)?
    let onShowLibraryConnection: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingAbout = false
    @State private var isHoveringLogo = false
    @State private var isFolderImporterPresented = false
    @State private var isLibraryActionsPresented = false
    @State private var folderImportAction: FolderImportAction?

    init(
        localLibrary: LocalLibraryStore,
        libraryManager: LibraryManager,
        navidromeConnection: NavidromeConnectionStore,
        activeLibrarySource: Binding<LibrarySource?>,
        onSelectMusicFolder: ((URL) -> Void)? = nil,
        onCreateOrUpdateLibraryIndex: ((URL) -> Void)? = nil,
        onDisconnectLibrary: (() -> Void)? = nil,
        onShowAbout: (() -> Void)? = nil,
        onShowLibraryConnection: (() -> Void)? = nil
    ) {
        self.localLibrary = localLibrary
        self.libraryManager = libraryManager
        self.navidromeConnection = navidromeConnection
        self._activeLibrarySource = activeLibrarySource
        self.onSelectMusicFolder = onSelectMusicFolder
        self.onCreateOrUpdateLibraryIndex = onCreateOrUpdateLibraryIndex
        self.onDisconnectLibrary = onDisconnectLibrary
        self.onShowAbout = onShowAbout
        self.onShowLibraryConnection = onShowLibraryConnection
    }

    var body: some View {
        GeometryReader { proxy in
            #if os(iOS)
            iosHome(
                verticalDeckInset: DeckStyle.verticalDeckInset(
                    viewportSize: proxy.size
                )
            )
            #else
            macHome
            #endif
        }
    }

    #if os(macOS)
    private var macHome: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                Text("MusiCards")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.primary)

                Image("mb_logo")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                    .foregroundStyle(isHoveringLogo ? Color.blue : .primary)
                    .scaleEffect(isHoveringLogo ? 1.05 : 1)
                    .shadow(
                        color: isHoveringLogo
                            ? Color.primary.opacity(0.12)
                            : .clear,
                        radius: 5,
                        y: 5
                    )
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let onShowAbout {
                            onShowAbout()
                        } else {
                            isShowingAbout = true
                        }
                    }
                    .onHover { isHoveringLogo = $0 }
                    .animation(
                        .spring(response: 0.22, dampingFraction: 0.72),
                        value: isHoveringLogo
                    )

                VStack(spacing: 12) {
                    homePrompt(connectionHeading)
                    connectionButton
                    activeLibraryPrompt

                    if let report = compatibilityReport {
                        homePrompt(report)
                            .multilineTextAlignment(.center)
                            .padding(.top, 22)
                    }

                    if let message = connectionMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                            .padding(.top, 6)
                    }
                }
            }
            .padding(.top, 16)

            Spacer(minLength: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(
            isPresented: $isFolderImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleFolderImport
        )
    }
    #endif

    @ViewBuilder
    private var activeLibraryPrompt: some View {
        if isLibraryConnected {
            HStack(spacing: 4) {
                Text(libraryManager.source == .navidrome ? "NAVIDROME" : "LOCAL")
                    .bold()

                Text("MUSIC LIBRARY")
            }
            .font(.caption)
            .tracking(1.5)
        } else {
            homePrompt("YOUR MUSIC LIBRARY")
        }
    }

    #if os(iOS)
    private func iosHome(verticalDeckInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                Text("MusiCards")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.primary)

                Image("mb_logo")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                    .foregroundStyle(.primary)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isShowingAbout = true
                    }

                VStack(spacing: 14) {
                    homePrompt(connectionHeading)

                    Button {
                        isLibraryActionsPresented = true
                    } label: {
                        Text(connectionButtonTitle)
                            .font(.footnote.weight(.semibold))
                            .tracking(4)
                            .foregroundStyle(
                                colorScheme == .dark ? Color.black : .white
                            )
                            .padding(.horizontal, 30)
                            .frame(height: 32)
                            .background {
                                Capsule(style: .continuous)
                                    .fill(Color.primary)
                                    .shadow(
                                        color: .black.opacity(0.22),
                                        radius: 8,
                                        y: 4
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(connectionAccessibilityLabel)

                    activeLibraryPrompt

                    if let report = compatibilityReport {
                        homePrompt(report)
                            .multilineTextAlignment(.center)
                            .padding(.top, 28)
                    }

                    if let message = connectionMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)
                            .padding(.top, 8)
                    }
                }
            }
            .padding(.top, 100)

            Spacer(minLength: 24)

            homePrompt("TO EXPLORE:")
                .padding(
                    .bottom,
                    explorePromptBottomInset + verticalDeckInset
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $isShowingAbout) {
            AboutView()
        }
        .sheet(isPresented: $isLibraryActionsPresented) {
            libraryConnectionView
        }
        .fileImporter(
            isPresented: $isFolderImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in handleFolderImport(result) }
    }

    #endif

    private func homePrompt(_ title: String) -> some View {
        Text(title)
            .font(.system(.footnote, design: .monospaced))
            .tracking(2)
            .foregroundStyle(.primary)
    }

    private var connectionButton: some View {
        Button {
            #if os(macOS)
            if let onShowLibraryConnection {
                onShowLibraryConnection()
            }
            #else
            isLibraryActionsPresented = true
            #endif
        } label: {
            Text(connectionButtonTitle)
                .font(.footnote.weight(.semibold))
                .tracking(4)
                .foregroundStyle(
                    colorScheme == .dark ? Color.black : .white
                )
                .padding(.horizontal, 30)
                .frame(height: 28)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.primary)
                        .shadow(
                            color: .black.opacity(0.22),
                            radius: 8,
                            y: 4
                        )
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(connectionAccessibilityLabel)
    }

    private var isLibraryConnected: Bool {
        switch libraryManager.source {
        case .local:
            localLibrary.summary.folderCount > 0
                && localLibrary.connectionErrorMessage == nil
        case .navidrome:
            navidromeConnection.isConfigured
        }
    }

    private var connectionHeading: String {
        if isActiveLibraryLoading { return "CONNECTING…" }
        return isLibraryConnected ? "YOU HAVE SUCCESSFULLY" : "TO PLAY:"
    }

    private var connectionButtonTitle: String {
        if isActiveLibraryLoading { return "CONNECTING" }
        return isLibraryConnected ? "CONNECTED" : "CONNECT"
    }

    private var connectionAccessibilityLabel: String {
        isLibraryConnected
            ? "Connected music library. Select another library"
            : "Connect your music library"
    }

    private var compatibilityReport: String? {
        guard isLibraryConnected, !isActiveLibraryLoading else { return nil }
        if libraryManager.source == .navidrome,
           libraryManager.catalogState != .ready {
            return nil
        }
        let summary = libraryManager.catalogSummary
        if let total = summary.totalAlbumCount {
            return "\(summary.identifiedAlbumCount) / \(total) ALBUMS\nIDENTIFIED AS PLAYABLE"
        }
        return "\(summary.identifiedAlbumCount) ALBUMS\nIDENTIFIED AS PLAYABLE"
    }

    private var connectionMessage: String? {
        switch libraryManager.source {
        case .local:
            if let error = localLibrary.connectionErrorMessage {
                return error.uppercased()
            }
            guard localLibrary.isScanning else { return nil }
            return localLibrary.statusMessage?.uppercased()
        case .navidrome:
            if case .failed(let message) = libraryManager.catalogState {
                return message.uppercased()
            }
            if libraryManager.catalogState == .loading {
                return "LOADING NAVIDROME CATALOG…"
            }
            return navidromeConnection.errorMessage?.uppercased()
        }
    }

    private var isActiveLibraryLoading: Bool {
        switch libraryManager.source {
        case .local:
            localLibrary.isScanning
        case .navidrome:
            navidromeConnection.isConnecting
                || libraryManager.catalogState == .loading
        }
    }

    private func handleFolderImport(
        _ result: Result<[URL], Error>
    ) {
        defer { folderImportAction = nil }
        guard case .success(let urls) = result,
              let url = urls.first else {
            return
        }
        switch folderImportAction {
        case .connectExisting:
            onSelectMusicFolder?(url)
        case .createOrUpdateIndex:
            onCreateOrUpdateLibraryIndex?(url)
        case nil:
            break
        }

        #if os(iOS)
        Task { @MainActor in
            await Task.yield()
            isLibraryActionsPresented = true
        }
        #endif
    }

    private func beginFolderImport(_ action: FolderImportAction) {
        folderImportAction = action
        isLibraryActionsPresented = false
        Task { @MainActor in
            await Task.yield()
            isFolderImporterPresented = true
        }
    }

    #if os(iOS)
    private var libraryConnectionView: some View {
        LibraryConnectionView(
            localLibrary: localLibrary,
            navidromeConnection: navidromeConnection,
            activeLibrarySource: $activeLibrarySource,
            onConnectExisting: {
                beginFolderImport(.connectExisting)
            },
            onCreateOrUpdateIndex: nil,
            onDisconnect: {
                onDisconnectLibrary?()
            }
        )
    }

    private var explorePromptBottomInset: CGFloat {
        let collapsedCardPeeks = CGFloat(MusiCardID.allCases.count - 2)
            * DeckStyle.peek
        return DeckStyle.cardBottomInset
            + DeckStyle.collapsedPlayerHeight
            + collapsedCardPeeks
            + 24
    }
    #endif
}

private enum FolderImportAction {
    case connectExisting
    case createOrUpdateIndex
}
