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
        GeometryReader { proxy in
            #if os(iOS)
            iosHome
            #else
            ScrollView {
                VStack(spacing: 16) {

                    Text("MusiCards")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.primary)

                    Image("mb_logo")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 52, height: 52)
                        .foregroundStyle(
                            isHoveringLogo ? Color.blue : .primary
                        )
                        .scaleEffect(
                            isHoveringLogo ? 1.05 : 1.0
                        )
                        .shadow(
                            color: isHoveringLogo
                                ? Color.primary.opacity(0.12)
                                : .clear,
                            radius: 5,
                            x: 0,
                            y: 5
                        )
                        .padding(.top, 10)
                        .padding(.bottom, 10)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            isShowingAbout = true
                        }
                        .animation(
                            .spring(
                                response: 0.22,
                                dampingFraction: 0.72
                            ),
                            value: isHoveringLogo
                        )
                        #if os(macOS)
                            .onHover { hovering in
                                isHoveringLogo = hovering
                            }
                        #endif

                    Text("MusicBrainz Release Viewer")
                        .font(.footnote)
                        .foregroundStyle(.primary)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Type artist name to search for artist")
                        codeText("miles davis")
                        Text("")
                        Text("Type comma + release title for releases")
                        codeText(", kind of blue")
                        Text("")
                        Text("Type artist, release title for combined search")
                        codeText("miles davis, kind of blue")
                        Text("")
                        Text("Paste a MusicBrainz release MBID")
                        codeText("353021d1-3d84-4f17-9fe4-66788d785a9d")
                        Text("")
                        #if os(iOS)
                            Text(
                                "Tap \(Image(systemName: "barcode.viewfinder")) to scan the barcode of a CD"
                            )
                            codeText("889853635726")
                        #endif
                        Text("")
                        Text("Tap the logo for app info")
                        Text("")
                        Text("")
                    }
                    #if os(iOS)
                        .font(.footnote)
                        .padding(.horizontal, 40)
                        .frame(
                            maxWidth: UIDevice.current.userInterfaceIdiom == .pad
                                ? DeckStyle.maximumPadCardWidth
                                : .infinity,
                            alignment: .leading
                        )
                        .padding(
                            .horizontal,
                            UIDevice.current.userInterfaceIdiom == .pad
                                ? DeckStyle.minimumPadHorizontalMargin
                                : DeckStyle.horizontalInset
                        )
                    #endif

                    #if os(macOS)
                        .font(.callout)
                        .padding(.horizontal, 0)
                    #endif

                    .foregroundStyle(.primary)
                    .padding(.top, 32)
                    #if os(macOS)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    #endif
                    .multilineTextAlignment(.leading)
                }
                #if os(iOS)
                    .padding(.top, 100)
                #endif
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .bottom)
            .overlay {
                if isShowingAbout {
                    Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isShowingAbout = false
                    }
                }
            }
            .overlay {
                if isShowingAbout {
                    AboutSheetView {
                        isShowingAbout = false
                    }
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
            #endif
        }
    }

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
        ) { result in
            guard case .success(let urls) = result,
                  let url = urls.first else {
                return
            }
            onSelectMusicFolder?(url)
        }
    }

    private func homePrompt(_ title: String) -> some View {
        Text(title)
            .font(.system(.footnote, design: .monospaced))
            .tracking(2)
            .foregroundStyle(.primary)
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

    private var explorePromptBottomInset: CGFloat {
        let collapsedCardPeeks = CGFloat(MusiCardID.allCases.count - 2)
            * DeckStyle.peek
        return DeckStyle.cardBottomInset
            + DeckStyle.collapsedPlayerHeight
            + collapsedCardPeeks
            + 24
    }
    #endif

    private func codeText(_ text: String) -> some View {
        Text(text)
            #if os(iOS)
                .font(.system(.footnote, design: .monospaced))
            #endif
            #if os(macOS)
                .font(.system(.callout, design: .monospaced))
            #endif
            .foregroundStyle(.secondary)
    }
}
