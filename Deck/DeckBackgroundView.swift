//
//  DeckBackgroundView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 14..
//

import SwiftUI

struct DeckBackgroundView: View {

    @State private var isShowingAbout = false

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
                        .foregroundStyle(.primary)
                        .padding(.top, 10)
                        .padding(.bottom, 10)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            isShowingAbout = true
                        }

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
                        Text("Tap \(Image(systemName: "barcode.viewfinder")) to scan the barcode of a CD")
                        codeText("889853635726")
#endif
                        Text("")
                        Text("Tap the logo for app info")
                        Text("")
                        Text("")
                    }
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .padding(.top, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 48)

                    Image(systemName: "arrow.up")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .padding(.top, 8)
                        .padding(.bottom, 190)
                }
                .padding(.top, 100)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
            }
                .scrollIndicators(.hidden)
                .ignoresSafeArea(edges: .bottom)
                .sheet(isPresented: $isShowingAbout) {
                    AboutView()
                }
            }
    }
    
    private func codeText(_ text: String) -> some View {
        Text(text)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(.secondary)
    }
}
