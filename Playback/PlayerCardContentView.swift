//
//  PlayerCardContentView.swift
//  MusiCards
//

import SwiftUI
import UniformTypeIdentifiers

struct PlayerCardContentView: View {
    @ObservedObject var controller: PlaybackController
    let onSelectLocalFile: (URL) -> Void

    @State private var isFileImporterPresented = false

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
