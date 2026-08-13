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

    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingAbout = false
    @State private var isHoveringLogo = false
    @State private var isFolderImporterPresented = false

    init(
        localLibrary: LocalLibraryStore,
        onSelectMusicFolder: ((URL) -> Void)? = nil
    ) {
        self.localLibrary = localLibrary
        self.onSelectMusicFolder = onSelectMusicFolder
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
                    .onTapGesture { isShowingAbout = true }
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
        .fileImporter(
            isPresented: $isFolderImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleFolderImport
        )
        .overlay {
            if isShowingAbout {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { isShowingAbout = false }
            }
        }
        .overlay {
            if isShowingAbout {
                AboutSheetView { isShowingAbout = false }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.scale.combined(with: .opacity))
                    .onTapGesture {}
            }
        }
        .animation(.spring(duration: 0.35), value: isShowingAbout)
        .onKeyPress(.escape) {
            if isShowingAbout {
                isShowingAbout = false
                return .handled
            }
            return .ignored
        }
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
                        isFolderImporterPresented = true
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
            isFolderImporterPresented = true
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
        guard case .success(let urls) = result,
              let url = urls.first else {
            return
        }
        onSelectMusicFolder?(url)
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
