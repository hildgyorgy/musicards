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
    let onSelectMusicFolder: ((URL) -> Void)?
    let onCreateOrUpdateLibraryIndex: ((URL) -> Void)?
    let onDisconnectLibrary: (() -> Void)?
    let onShowAbout: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingAbout = false
    @State private var isHoveringLogo = false
    @State private var isFolderImporterPresented = false
    @State private var isLibraryActionsPresented = false
    @State private var folderImportAction: FolderImportAction?

    init(
        localLibrary: LocalLibraryStore,
        onSelectMusicFolder: ((URL) -> Void)? = nil,
        onCreateOrUpdateLibraryIndex: ((URL) -> Void)? = nil,
        onDisconnectLibrary: (() -> Void)? = nil,
        onShowAbout: (() -> Void)? = nil
    ) {
        self.localLibrary = localLibrary
        self.onSelectMusicFolder = onSelectMusicFolder
        self.onCreateOrUpdateLibraryIndex = onCreateOrUpdateLibraryIndex
        self.onDisconnectLibrary = onDisconnectLibrary
        self.onShowAbout = onShowAbout
    }

    var body: some View {
        GeometryReader { _ in
            #if os(iOS)
            iosHome
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
                    homePrompt("YOUR MUSIC LIBRARY")

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
        .sheet(isPresented: $isLibraryActionsPresented) {
            libraryConnectionView
        }
        .fileImporter(
            isPresented: $isFolderImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleFolderImport
        )
    }
    #endif

    #if os(iOS)
    private var iosHome: some View {
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

                    homePrompt("YOUR MUSIC LIBRARY")

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
                .padding(.bottom, explorePromptBottomInset)
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
            isLibraryActionsPresented = true
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
        localLibrary.summary.folderCount > 0
            && localLibrary.connectionErrorMessage == nil
    }

    private var connectionHeading: String {
        if localLibrary.isScanning { return "CONNECTING…" }
        return isLibraryConnected ? "YOU HAVE SUCCESSFULLY" : "TO PLAY:"
    }

    private var connectionButtonTitle: String {
        if localLibrary.isScanning { return "CONNECTING" }
        return isLibraryConnected ? "CONNECTED" : "CONNECT"
    }

    private var connectionAccessibilityLabel: String {
        isLibraryConnected
            ? "Connected music library. Select another library"
            : "Connect your music library"
    }

    private var compatibilityReport: String? {
        guard isLibraryConnected, !localLibrary.isScanning else { return nil }
        let summary = localLibrary.summary
        if let total = summary.totalAlbumCount {
            return "\(summary.identifiedAlbumCount) / \(total) ALBUMS\nIDENTIFIED AS PLAYABLE"
        }
        return "\(summary.identifiedAlbumCount) ALBUMS\nIDENTIFIED AS PLAYABLE"
    }

    private var connectionMessage: String? {
        if let error = localLibrary.connectionErrorMessage {
            return error.uppercased()
        }
        guard localLibrary.isScanning else { return nil }
        return localLibrary.statusMessage?.uppercased()
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
    }

    private var libraryConnectionView: some View {
        LibraryConnectionView(
            localLibrary: localLibrary,
            onConnectExisting: {
                beginFolderImport(.connectExisting)
            },
            onCreateOrUpdateIndex: {
                beginFolderImport(.createOrUpdateIndex)
            },
            onDisconnect: {
                onDisconnectLibrary?()
                isLibraryActionsPresented = false
            }
        )
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
