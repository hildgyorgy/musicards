//
//  PlayerCardContentView.swift
//  MusiCards
//

import SwiftUI
import UniformTypeIdentifiers

struct PlayerCardContentView: View {
    @ObservedObject var controller: PlaybackController
    @ObservedObject var localLibrary: LocalLibraryStore
    let onSelectMusicFolder: (URL) -> Void
    @ObservedObject var detailStore: TrackDetailStore
    let onSelectArtist: (String) -> Void

    @State private var isFolderImporterPresented = false
    @State private var folderSelectionPurpose = FolderSelectionPurpose.connect
    @State private var selectedDetailPage = 1

    var body: some View {
        Group {
            if let item = controller.currentItem {
                expandedPlayer(item)
            } else {
                #if os(iOS)
                idlePlayer
                #else
                libraryControls
                #endif
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: controller.currentItem?.track.recordingID) {
            selectedDetailPage = 1
            if let recordingID = controller.currentItem?.track.recordingID {
                detailStore.fetchIfNeeded(recordingID: recordingID)
            }
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
            switch folderSelectionPurpose {
            case .connect:
                onSelectMusicFolder(url)
            case .createOrUpdateIndex:
                #if os(macOS)
                localLibrary.createOrUpdateLibraryIndex(in: url)
                #endif
            }
        }
    }

    #if os(iOS)
    private var idlePlayer: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("SELECT PLAYABLE TRACKS")
                .font(.footnote)
                .tracking(AppStyle.cardLabelTracking)
                .foregroundStyle(.secondary)

            Spacer()

            idleTransport
                .frame(height: expandedTransportHeight)
        }
    }

    private var idleTransport: some View {
        HStack(spacing: 0) {
            ForEach(
                ["backward.end.fill", "pause.fill", "forward.end.fill"],
                id: \.self
            ) { systemName in
                Image(systemName: systemName)
                    .font(.title3)
                    .foregroundStyle(Color.secondary.opacity(0.65))
                    .frame(width: 44, height: 44)
            }

            Spacer(minLength: 14)

            VStack(spacing: 4) {
                HStack {
                    Spacer()
                    Text("0:00")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Capsule(style: .continuous)
                    .stroke(Color.secondary.opacity(0.65), lineWidth: 1)
                    .frame(height: 3)
            }
        }
        .allowsHitTesting(false)
    }
    #endif

    private func expandedPlayer(_ item: PlaybackQueueItem) -> some View {
        VStack(spacing: 0) {
            releaseIdentity(item.track)
                .padding(.top, releaseIdentityTopInset)

            ScrollView {
                LazyVStack(
                    alignment: .leading,
                    spacing: 0,
                    pinnedViews: [.sectionHeaders]
                ) {
                    playerMetadataLabel(mediumTrackTitle(item.track))
                        .padding(.top, 14)

                    Section {
                        TrackDetailPagerView(
                            selectedPage: $selectedDetailPage,
                            recordingID: item.track.recordingID,
                            detailStore: detailStore,
                            onSelectArtist: onSelectArtist
                        )
                        .padding(.top, 8)
                        .padding(.bottom, 10)
                    } header: {
                        trackTitleRow(item.track)
                    }
                }
            }
            .scrollIndicators(.hidden)

            VStack(spacing: 0) {
                playerMetadataLabel(fileAndOutputTitle(item))
                    .padding(.bottom, playerFooterInfoSpacing)

                CollapsedPlayerBar(
                    controller: controller,
                    contentInset: 0
                )
                .frame(height: expandedTransportHeight)
            }
            #if os(macOS)
            // The macOS deck reserves contentTopSpacing below its expanded
            // header. Move the complete player footer into that space so the
            // transport and its route/format information stay together.
            .offset(y: DeckStyle.contentTopSpacing)
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func releaseIdentity(_ track: PlaybackTrack) -> some View {
        HStack(alignment: .top, spacing: 16) {
            artwork(track.artworkData)
                .frame(width: artworkSize, height: artworkSize)

            VStack(alignment: .leading, spacing: 6) {
                Text(track.albumTitle.isEmpty ? track.title : track.albumTitle)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)

                Text(track.artist)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func playerMetadataLabel(_ title: String) -> some View {
        Text(title)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private func artwork(_ data: Data?) -> some View {
        if let data, let image = PlatformImage(data: data) {
            #if os(iOS)
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            #else
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            #endif
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .overlay {
                    Image(systemName: "music.note")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
        }
    }

    private func trackTitleRow(_ track: PlaybackTrack) -> some View {
        HStack(spacing: 12) {
            Text(track.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(formatTime(controller.preparedDuration ?? track.duration ?? 0))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            Capsule(style: .continuous)
                .fill(Color.gray.opacity(0.15))
        }
    }

    private var libraryControls: some View {
        VStack(spacing: 18) {
            EmptyStateView(
                title: "Playback foundation ready",
                subtitle: "Choose one local lossless track"
            )

            Button("Connect Music Folder") {
                folderSelectionPurpose = .connect
                isFolderImporterPresented = true
            }
            .buttonStyle(.bordered)
            .disabled(localLibrary.isScanning)

            #if os(macOS)
            Button("Create / Update Library Index") {
                folderSelectionPurpose = .createOrUpdateIndex
                isFolderImporterPresented = true
            }
            .buttonStyle(.bordered)
            .disabled(localLibrary.isScanning)
            #endif

        }
    }

    private func mediumTrackTitle(_ track: PlaybackTrack) -> String {
        var components: [String] = []

        if let mediumFormat = track.mediumFormat?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !mediumFormat.isEmpty {
            if let discNumber = track.discNumber {
                components.append("\(mediumFormat) \(discNumber)")
            } else {
                components.append(mediumFormat)
            }
        } else if let discNumber = track.discNumber {
            components.append("DISC \(discNumber)")
        }

        if let trackNumber = track.trackNumber {
            components.append("TRACK \(trackNumber)")
        }

        return components.isEmpty ? "TRACK" : components.joined(separator: " / ").uppercased()
    }

    private func fileAndOutputTitle(_ item: PlaybackQueueItem) -> String {
        let output = AudioOutputRouteInspector.current()
        let routeComponents = ([
            sourceName(item.source),
            output.transport.displayName,
            output.deviceName.nilIfEmpty?.uppercased()
        ] as [String?])
            .compactMap { $0 }
            .reduce(into: [String]()) { result, component in
                if result.last?.caseInsensitiveCompare(component) != .orderedSame {
                    result.append(component)
                }
            }
        let route = routeComponents
            .joined(separator: " → ")
        let format = audioFormatText(item.track.audioFormat)
        return format.isEmpty ? route : "\(route)\n\(format)"
    }

    private func sourceName(_ source: PlaybackSource) -> String {
        switch source {
        case .localFile(let url):
            let path = url.absoluteString.lowercased()
            if path.contains("dropbox") {
                return "DROPBOX"
            }
            if path.contains("icloud") || path.contains("ubiquity") {
                return "ICLOUD"
            }
            return "LOCAL"
        }
    }

    private func audioFormatText(_ format: PlaybackAudioFormat?) -> String {
        guard let format else { return "" }

        var components = [format.codec.uppercased()]

        if let bitrate = format.bitrate, bitrate > 0 {
            components.append("\(Int((bitrate / 1_000).rounded())) kbps")
        }

        let sampleRate = format.sampleRate >= 1_000
            ? String(format: "%.1f kHz", format.sampleRate / 1_000)
            : String(format: "%.0f Hz", format.sampleRate)

        if let bitDepth = format.bitDepth {
            components.append("\(sampleRate) / \(bitDepth) bit")
        } else if format.sampleRate > 0 {
            components.append(sampleRate)
        }

        switch format.channelCount {
        case 1:
            components.append("MONO")
        case 2:
            components.append("STEREO")
        case let count where count > 2:
            components.append("\(count) CHANNELS")
        default:
            break
        }

        return components.joined(separator: " • ")
    }

    #if os(iOS)
    private let artworkSize: CGFloat = 132
    private let expandedTransportHeight: CGFloat = 70
    private let releaseIdentityTopInset: CGFloat = 0
    #else
    private let artworkSize: CGFloat = 116
    private let expandedTransportHeight: CGFloat = 58
    private let releaseIdentityTopInset: CGFloat = -8
    #endif
    private let playerFooterInfoSpacing: CGFloat = 8

    private func formatTime(_ time: TimeInterval) -> String {
        let seconds = max(Int(time.rounded(.down)), 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private enum FolderSelectionPurpose {
    case connect
    case createOrUpdateIndex
}
