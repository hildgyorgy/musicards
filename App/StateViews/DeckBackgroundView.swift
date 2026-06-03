//
//  DeckBackgroundView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 14..
//

import SwiftUI

struct DeckBackgroundView: View {

    @State private var isShowingAbout = false
    @State private var isHoveringLogo = false

    var body: some View {
        GeometryReader { proxy in
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
                        Text("Type comma + release/track title for releases")
                        codeText(", kind of blue")
                        Text("")
                        Text("Type artist, release/track for combined search")
                        codeText("miles davis, so what")
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
                        .padding(
                            .horizontal,
                            DeckStyle.horizontalInset + 40
                        )
                    #endif

                    #if os(macOS)
                        .font(.callout)
                        .padding(.horizontal, 0)
                    #endif

                    .foregroundStyle(.primary)
                    .padding(.top, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                }
                #if os(iOS)
                    .padding(.top, 100)
                #endif
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
            }
            .overlay(alignment: .bottom) {
                #if os(iOS)
                    Image(systemName: "arrow.up")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .padding(.bottom, 195)
                #endif
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .bottom)
            #if os(iOS)
                .sheet(isPresented: $isShowingAbout) {
                    AboutView()
                }
            #elseif os(macOS)
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
