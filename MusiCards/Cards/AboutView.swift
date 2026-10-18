//
//  AboutView.swift
//  MusiCards
//

import SwiftUI

struct AboutView: View {
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

                    Text("Explore MusicBrainz artists, releases, tracks and credits. You can browse without connecting a music library; connect your own music to play matching tracks.")
                }

                helpSection("Find music") {
                    Text("Type a name or title in Search:")

                    VStack(alignment: .leading, spacing: 12) {
                        searchExample("artist", "Find artists")
                        searchExample(", release", "Find releases by title")
                        searchExample("artist, release", "Find an artist’s release")
                    }

                    Text("Use the search switch to look in your library only, or include MusicBrainz. You can also paste a MusicBrainz release ID to open a specific edition.")

                    #if os(iOS)
                    Text("On iPhone, you can scan a CD barcode or use Shazam. When Apple Music is playing, its album may also appear in Search.")
                    #endif
                }

                helpSection("Choose a music source") {
                    Text("Open SOURCE on the home screen and choose This device or Navidrome. This choice affects playback, not MusicBrainz browsing.")

                    Text("For This device, select a music folder containing a valid \(Text("library.json").font(.system(.body, design: .monospaced))). The index connects your files to MusicBrainz releases and tracks.")

                    #if os(macOS)
                    Text("To prepare a folder, tag its music with MusicBrainz Picard, then use Create / update library index on the home screen. Afterwards, select that folder in SOURCE.")
                    #else
                    Text("Create or update \(Text("library.json").font(.system(.body, design: .monospaced))) with MusiCards for Mac from MusicBrainz Picard-tagged files, then select the same folder here.")
                    #endif

                    Link("MusicBrainz Picard", destination: AboutLinks.picard)

                    Text("For Navidrome, enter a reachable server address and your account details in SOURCE. A local network address is recommended when playing through a UPnP renderer.")
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
