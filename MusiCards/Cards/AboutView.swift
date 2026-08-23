//
//  AboutView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 24..
//

import SwiftUI

struct AboutView: View {

    #if os(macOS)
        @AppStorage("glassTransparent") private var glassTransparent = false
    #endif

    @State private var isShowingThirdPartyLicenses = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                findSection

                primaryDivider

                prepareSection

                playSection

            Link(destination: AboutLinks.help) {
                    HStack(spacing: 5) {
                        Text("Detailed help")
                        Image(systemName: "arrow.up.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.callout.weight(.medium))
                }

                primaryDivider

                attributionSection

                Button {
                    isShowingThirdPartyLicenses = true
                } label: {
                    HStack {
                        Text("Third-Party Licenses")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .font(.callout.weight(.medium))
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $isShowingThirdPartyLicenses) {
                    ThirdPartyLicensesView()
                }

                #if os(macOS)
                    glassStylePicker
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .tint(.blue)
        #if os(iOS)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
        #endif
    }

    private var primaryDivider: some View {
        Rectangle()
            .fill(Color.primary)
            .frame(height: 1)
    }

    private var findSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("FIND")

            VStack(alignment: .leading, spacing: 12) {
                SearchRecipeRow(
                    example: "artist",
                    explanation: "Search for an artist"
                )

                SearchRecipeRow(
                    example: ", release",
                    explanation: "Search for releases"
                )

                SearchRecipeRow(
                    example: "artist, release",
                    explanation: "Combined search"
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                helpBullet("Paste a MusicBrainz release MBID")

                #if os(iOS)
                    helpBullet("Scan the barcode of a CD")
                    helpBullet("Use Shazam to identify music")
                #endif
            }
            .padding(.top, 2)
        }
    }

    private var prepareSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("PREPARE")

            VStack(alignment: .leading, spacing: 11) {
                instruction(
                    1,
                    "Tag your albums with [MusicBrainz Picard](https://picard.musicbrainz.org/)."
                )
                instruction(
                    2,
                    "On a Mac, choose CONNECT to create or update the library index."
                )
            }
        }
    }

    private var playSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("PLAY")

            VStack(alignment: .leading, spacing: 11) {
                instruction(
                    1,
                    "Choose an existing indexed music folder with CONNECT if it is not already connected."
                )
                instruction(
                    2,
                    "Play any release or track marked with the blue play symbol."
                )
            }
        }
    }

    private var attributionSection: some View {
        VStack(spacing: 7) {
            Text("Data provided by MusicBrainz")
                .font(.headline)

            Link("musicbrainz.org", destination: AboutLinks.musicBrainz)

            Text("MusicBrainz data is available under the CC0 license.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("Cover art is provided by the Cover Art Archive.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ViewThatFits(in: .horizontal) {
                footerLinks

                VStack(spacing: 5) {
                    HStack(spacing: 5) {
                        Link("Support", destination: AboutLinks.support)
                        Text("•")
                        Link("Privacy", destination: AboutLinks.privacy)
                    }

                    Text("György Hild • 2026")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 5)
        }
        .frame(maxWidth: .infinity)
    }

    private var footerLinks: some View {
        HStack(spacing: 5) {
            Link("Support", destination: AboutLinks.support)
            Text("•")
            Link("Privacy", destination: AboutLinks.privacy)
            Text("|")
            Text("György Hild")
            Text("•")
            Text("2026")
        }
    }

    #if os(macOS)
        @ViewBuilder
        private var glassStylePicker: some View {
            if #available(macOS 26.0, *) {
                HStack(spacing: 8) {
                    Text("FROSTED")
                        .foregroundStyle(
                            glassTransparent ? .secondary : .primary
                        )

                    Toggle("", isOn: $glassTransparent)
                        .toggleStyle(.switch)
                        .labelsHidden()

                    Text("LIQUID")
                        .foregroundStyle(
                            glassTransparent ? .primary : .secondary
                        )
                }
                .font(.caption)
                .tracking(1.5)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
            }
        }
    #endif

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(.headline, design: .monospaced).weight(.semibold))
            .tracking(2)
            .foregroundStyle(.primary)
    }

    private func helpBullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("•")
                .font(.system(.callout, design: .monospaced))

            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
        }
    }

    private func instruction(_ number: Int, _ markdown: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number).")
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .frame(width: 20, alignment: .trailing)

            Text(attributed(markdown))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func attributed(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }
}

private struct SearchRecipeRow: View {
    let example: String
    let explanation: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 11) {
                exampleToken
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.primary)
            }

            VStack(alignment: .leading, spacing: 6) {
                exampleToken
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var exampleToken: some View {
        Text(example)
            .font(.system(.callout, design: .monospaced).weight(.semibold))
            .foregroundStyle(colorScheme == .dark ? Color.black : .white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white : .black)
            }
    }
}

private enum AboutLinks {
    static let musicBrainz = URL(string: "https://musicbrainz.org")!
    static let help = URL(
        string: "https://hildgyorgy.github.io/app-support/musicards/#help"
    )!
    static let support = URL(
        string: "https://hildgyorgy.github.io/app-support/musicards/#support"
    )!
    static let privacy = URL(
        string: "https://hildgyorgy.github.io/app-support/musicards/#privacy"
    )!
}
