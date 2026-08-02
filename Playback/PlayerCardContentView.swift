//
//  PlayerCardContentView.swift
//  MusiCards
//

import SwiftUI
import UniformTypeIdentifiers

struct PlayerCardContentView: View {
    @ObservedObject var controller: PlaybackController
    @ObservedObject var localLibrary: LocalLibraryStore
    let onSelectLocalFile: (URL) -> Void
    let onSelectMusicFolder: (URL) -> Void
    let onRefreshLibrary: () -> Void

    @State private var isFileImporterPresented = false
    @State private var isFolderImporterPresented = false
    @State private var folderSelectionPurpose = FolderSelectionPurpose.connect

    var body: some View {
        VStack(spacing: 18) {
            if let item = controller.currentItem {
                VStack(spacing: 6) {
                    Text(item.track.title)
                        .font(.headline)

                    Text(item.track.artist)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 24) {
                    Button {
                        Task { await controller.stop() }
                    } label: {
                        Image(systemName: "stop.fill")
                    }

                    Button {
                        Task { await controller.togglePlayback() }
                    } label: {
                        Image(
                            systemName: controller.status.isPlaying
                                ? "pause.fill"
                                : "play.fill"
                        )
                    }
                }
                .buttonStyle(.plain)
                .font(.title2)

                Text(playbackStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                EmptyStateView(
                    title: "Playback foundation ready",
                    subtitle: "Choose one local lossless track"
                )
            }

            Button(controller.currentItem == nil ? "Choose Audio File" : "Choose Another File") {
                isFileImporterPresented = true
            }
            .buttonStyle(.bordered)

            HStack(spacing: 10) {
                Button("Connect Music Folder") {
                    folderSelectionPurpose = .connect
                    isFolderImporterPresented = true
                }
                .buttonStyle(.bordered)
                .disabled(localLibrary.isScanning)

                Button("Reload Index") {
                    onRefreshLibrary()
                }
                .buttonStyle(.bordered)
                .disabled(localLibrary.summary.folderCount == 0 || localLibrary.isScanning)
            }

            #if os(macOS)
            Button("Create / Update Library Index") {
                folderSelectionPurpose = .createOrUpdateIndex
                isFolderImporterPresented = true
            }
            .buttonStyle(.bordered)
            .disabled(localLibrary.isScanning)
            #endif

            Text(libraryStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result,
                  let url = urls.first else {
                return
            }
            onSelectLocalFile(url)
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

    private var libraryStatusText: String {
        if localLibrary.isScanning {
            return localLibrary.statusMessage?.uppercased()
                ?? "SCANNING MUSIC LIBRARY…"
        }
        if let error = localLibrary.connectionErrorMessage {
            return error.uppercased()
        }
        if localLibrary.summary.folderCount == 0 {
            return localLibrary.statusMessage?.uppercased()
                ?? "NO MUSIC FOLDER"
        }
        let summary = localLibrary.summary
        return "\(summary.releaseCount) RELEASES · \(summary.trackCount) TRACKS"
    }

    private var playbackStatusText: String {
        switch controller.status {
        case .idle:
            return "Ready"
        case .loading:
            return "Preparing lossless PCM…"
        case .ready:
            return "Ready"
        case .playing:
            return timeText
        case .paused:
            return "Paused · \(timeText)"
        case .stopped:
            return "Stopped"
        case .failed(let failure):
            return failure.message
        }
    }

    private var timeText: String {
        let elapsed = formatTime(controller.position)
        guard let duration = controller.preparedDuration else {
            return elapsed
        }
        return "\(elapsed) / \(formatTime(duration))"
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let seconds = max(Int(time.rounded(.down)), 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private enum FolderSelectionPurpose {
    case connect
    case createOrUpdateIndex
}
