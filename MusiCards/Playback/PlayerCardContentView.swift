//
//  PlayerCardContentView.swift
//  MusiCards
//

import SwiftUI

struct PlayerCardContentView: View {
    @ObservedObject var controller: PlaybackController
    @ObservedObject var detailStore: TrackDetailStore
    let onSelectArtist: (String) -> Void

    @State private var selectedDetailPage = 1

    var body: some View {
        Group {
            if let item = controller.currentItem {
                expandedPlayer(item)
            } else {
                idlePlayer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: controller.currentItem?.track.recordingID) {
            selectedDetailPage = 1
            if let recordingID = controller.currentItem?.track.recordingID {
                detailStore.fetchIfNeeded(recordingID: recordingID)
            }
        }
    }

    private var idlePlayer: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("SELECT PLAYABLE TRACKS")
                .font(.footnote)
                .tracking(AppStyle.cardLabelTracking)
                .foregroundStyle(.secondary)

            Spacer()

            CollapsedPlayerBar(
                controller: controller,
                contentInset: 0,
                isPlaceholder: true
            )
            .frame(height: expandedTransportHeight)
            #if os(macOS)
            .offset(y: DeckStyle.contentTopSpacing)
            #endif
        }
    }

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
                playerMetadataLabel(sourceTitle(item))
                    .padding(.bottom, 4)

                playerMetadataLabel(outputTitle)
                    .padding(.bottom, playerFooterInfoSpacing)

                if controller.canControlOutputVolume {
                    RendererVolumeControl(controller: controller)
                        .padding(.bottom, 6)
                }

                CollapsedPlayerBar(
                    controller: controller,
                    contentInset: 0,
                    showsOutputStatus: false
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
            .fixedSize(horizontal: false, vertical: true)
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

    private func sourceTitle(_ item: PlaybackQueueItem) -> String {
        let source = sourceName(item.source)
        let format = audioFormatText(displayedAudioFormat(for: item))
        return ["SOURCE:", source, format]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private var outputTitle: String {
        let details = [
            controller.outputDisplayName,
            controller.outputSampleRateText
        ]
            .compactMap { $0 }
            .joined(separator: "\n")
        return "OUTPUT:\n\(details)"
    }

    private func displayedAudioFormat(
        for item: PlaybackQueueItem
    ) -> PlaybackAudioFormat? {
        if isNavidromeSource(item.source) {
            return controller.preparedAudioFormat
        }
        return controller.preparedAudioFormat ?? item.track.audioFormat
    }

    private func isNavidromeSource(_ source: PlaybackSource) -> Bool {
        switch source {
        case .remoteAudio(let asset):
            return asset.source == .navidrome
        case .libraryAsset(let reference):
            return reference.source == .navidrome
        case .localFile:
            return false
        }
    }

    private func sourceName(_ source: PlaybackSource) -> String {
        isNavidromeSource(source) ? "Navidrome" : "This device"
    }

    private func audioFormatText(_ format: PlaybackAudioFormat?) -> String {
        guard let format else { return "" }

        var components = [format.codec.uppercased()]

        if let bitDepth = format.bitDepth {
            components.append("\(bitDepth) bit")
        }

        if format.sampleRate > 0 {
            let sampleRate = format.sampleRate >= 1_000
                ? String(format: "%.1f kHz", format.sampleRate / 1_000)
                : String(format: "%.0f Hz", format.sampleRate)
            components.append(sampleRate)
        }

        if let bitrate = format.bitrate, bitrate > 0 {
            components.append("\(Int((bitrate / 1_000).rounded())) kbps")
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

        return components.joined(separator: " / ")
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

private struct RendererVolumeControl: View {
    @ObservedObject var controller: PlaybackController
    @State private var draftLevel = 0.5
    @State private var isAdjusting = false
    @State private var volumeUpdateTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Button {
                    Task {
                        await controller.setOutputMuted(
                            !(controller.outputVolumeState?.isMuted ?? false)
                        )
                    }
                } label: {
                    Image(
                        systemName: controller.outputVolumeState?.isMuted == true
                            ? "speaker.slash.fill" : "speaker.wave.2.fill"
                    )
                    .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(controller.outputVolumeState == nil)
                .accessibilityLabel(
                    controller.outputVolumeState?.isMuted == true
                        ? "Unmute network renderer" : "Mute network renderer"
                )

                Slider(
                    value: $draftLevel,
                    in: 0...1,
                    onEditingChanged: { editing in
                        isAdjusting = editing
                        if !editing {
                            sendFinalVolumeUpdate()
                        }
                    }
                )
                .disabled(controller.outputVolumeState == nil)
                .accessibilityLabel("Network renderer volume")
                .accessibilityValue("\(Int((draftLevel * 100).rounded())) percent")

                Text("\(Int((draftLevel * 100).rounded()))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }

            if let error = controller.outputVolumeErrorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .task(id: controller.externalOutputDisplayName) {
            await controller.refreshOutputVolume()
            synchronizeDraftLevel()
        }
        .onChange(of: controller.outputVolumeState) {
            guard !isAdjusting else { return }
            synchronizeDraftLevel()
        }
        .onChange(of: draftLevel) {
            guard isAdjusting else { return }
            scheduleLiveVolumeUpdate()
        }
        .onDisappear {
            volumeUpdateTask?.cancel()
        }
    }

    private func synchronizeDraftLevel() {
        if let level = controller.outputVolumeState?.level {
            draftLevel = level
        }
    }

    private func scheduleLiveVolumeUpdate() {
        guard volumeUpdateTask == nil else { return }
        volumeUpdateTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let level = draftLevel
            await controller.setOutputVolume(level)
            guard !Task.isCancelled else { return }
            volumeUpdateTask = nil
            if isAdjusting, level != draftLevel {
                scheduleLiveVolumeUpdate()
            }
        }
    }

    private func sendFinalVolumeUpdate() {
        volumeUpdateTask?.cancel()
        let level = draftLevel
        volumeUpdateTask = Task {
            await controller.setOutputVolume(level)
        }
    }
}
