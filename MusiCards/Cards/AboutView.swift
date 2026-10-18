//
//  AboutView.swift
//  MusiCards
//

import SwiftUI

struct AboutView: View {
    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    #if os(macOS)
    @AppStorage("glassTransparent") private var glassTransparent = false
    #endif

    @State private var isShowingThirdPartyLicenses = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    #if os(iOS)
                    Text("Help & support")
                        .font(.title2.weight(.semibold))
                    #endif

                    Text("Current version: \(currentVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("Explore MusicBrainz artists, releases, tracks and credits. Connect your own music to play matching tracks.")
                }

                helpSection("Find music") {
                    Text("Type a name or title in Search:")

                    VStack(alignment: .leading, spacing: 12) {
                        searchExample("artist", "Find artists")
                        searchExample(", release", "Find releases by title")
                        searchExample("artist, release", "Find an artist’s release")
                    }

                    Text("Paste a MusicBrainz release ID to open a specific edition.")

                    Text("Use the search switch to look in your library only, or include MusicBrainz.")

                    #if os(iOS)
                    Text("On iPhone, you can scan a CD barcode or use Shazam. When Apple Music is playing, its album may also appear in Search.")
                    #endif
                }

                helpSection("Choose a music source") {
                    Text("Open SOURCE on the home screen and choose This device or Navidrome. This choice affects playback, not MusicBrainz browsing.")

                    Text("For This device, first tag your files with MusicBrainz Picard and prepare the music folder with MusiCards for Mac. MusiCards creates the index (\(Text("library.json").font(.system(.body, design: .monospaced)))) needed to match your files with MusicBrainz; you don’t need to edit it yourself.")

                    #if os(macOS)
                    Text("Use Create / update library index on the home screen, then select the prepared folder in SOURCE. Update the index after adding or changing music.")
                    #else
                    Text("After preparing the folder on Mac, select it from Files in SOURCE. It can also be on supported external storage. Update the index on Mac after adding or changing music.")
                    #endif

                    Link("MusicBrainz Picard", destination: AboutLinks.picard)

                    Text("For Navidrome, no \(Text("library.json").font(.system(.body, design: .monospaced))) is needed: Navidrome provides the catalog and MusicBrainz IDs from your tagged files. Let it scan your music, then enter a reachable server address and your account details in SOURCE. A local network address is recommended for UPnP playback.")
                }

                helpSection("Choose audio output") {
                    Text("Open OUTPUT on the home screen. System audio follows the output chosen on your device, including speakers, headphones, AirPlay, Bluetooth and connected DACs.")

                    Text("You can also search for and select a UPnP renderer on your network. UPnP playback currently works with Navidrome tracks only; the renderer must be able to reach your Navidrome server.")

                    Text("A blue play symbol marks a release or track available from the active music source.")
                }

                helpSection("If playback is unavailable") {
                    Text("No play symbol? Check the active source. For files on this device, check the MusicBrainz tags and update \(Text("library.json").font(.system(.body, design: .monospaced))) after changing your music. For Navidrome, check that its library scan has finished.")

                    Text("No renderer found? Try Deep search or enter its address in OUTPUT. No sound? Check the selected output here and in the system.")
                }

                helpSection("Support & privacy") {
                    Link("Support", destination: AboutLinks.support)
                    Link("Privacy policy", destination: AboutLinks.privacy)
                    Button("Third-party licenses") {
                        isShowingThirdPartyLicenses = true
                    }
                }

                #if os(macOS)
                if #available(macOS 26.0, *) {
                    helpSection("Window appearance") {
                        Toggle("Liquid glass", isOn: $glassTransparent)
                            .toggleStyle(.switch)
                    }
                }
                #endif

                VStack(alignment: .leading, spacing: 6) {
                    Text("Music metadata: MusicBrainz. Cover art: Cover Art Archive.")
                    Link("MusicBrainz", destination: AboutLinks.musicBrainz)
                    Text("György Hild · 2026")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .font(.body)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .tint(.blue)
        .sheet(isPresented: $isShowingThirdPartyLicenses) {
            ThirdPartyLicensesView()
        }
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
        #endif
    }

    private func helpSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func searchExample(
        _ query: String,
        _ explanation: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(query)
                .font(.system(.body, design: .monospaced))
            Text(explanation)
                .foregroundStyle(.secondary)
        }
    }
}

private enum AboutLinks {
    static let musicBrainz = URL(string: "https://musicbrainz.org")!
    static let picard = URL(string: "https://picard.musicbrainz.org/")!
    static let support = URL(
        string: "https://hildgyorgy.github.io/app-support/musicards/#support"
    )!
    static let privacy = URL(
        string: "https://hildgyorgy.github.io/app-support/musicards/#privacy"
    )!
}
