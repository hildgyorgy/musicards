//
//  CollapsedPlayerBar.swift
//  MusiCards
//

import SwiftUI

struct CollapsedPlayerBar: View {
    @ObservedObject var controller: PlaybackController

    var body: some View {
        HStack(spacing: platformSpacing) {
            transportButton(
                systemName: "backward.end.fill",
                accessibilityLabel: "Previous track",
                isEnabled: controller.hasPrevious
            ) {
                await controller.selectPrevious()
            }

            transportButton(
                systemName: controller.status.isPlaying
                    ? "pause.fill"
                    : "play.fill",
                accessibilityLabel: controller.status.isPlaying
                    ? "Pause"
                    : "Play",
                isEnabled: controller.status != .loading
            ) {
                await controller.togglePlayback()
            }

            transportButton(
                systemName: "forward.end.fill",
                accessibilityLabel: "Next track",
                isEnabled: controller.hasNext
            ) {
                await controller.selectNext()
            }
            .padding(.trailing, 14)

            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text(controller.currentItem?.track.title ?? "")
                        .font(titleFont)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    Text(remainingTimeText)
                        .font(timeFont)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.primary)
            }
            .allowsHitTesting(false)
        }
        .padding(.horizontal, horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func transportButton(
        systemName: String,
        accessibilityLabel: String,
        isEnabled: Bool,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: systemName)
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(controlFont)
        .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.35))
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private var duration: TimeInterval? {
        controller.preparedDuration ?? controller.currentItem?.track.duration
    }

    private var progress: Double {
        guard let duration, duration > 0 else { return 0 }
        return min(max(controller.position / duration, 0), 1)
    }

    private var remainingTimeText: String {
        guard let duration, duration > 0 else {
            return formatTime(controller.position)
        }
        return "−\(formatTime(max(duration - controller.position, 0)))"
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let seconds = max(Int(time.rounded(.down)), 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    #if os(macOS)
    private let platformSpacing: CGFloat = 4
    private let horizontalPadding: CGFloat = 14
    private let buttonSize: CGFloat = 30
    private let controlFont: Font = .body
    private let titleFont: Font = .caption.weight(.medium)
    private let timeFont: Font = .caption
    #else
    private let platformSpacing: CGFloat = 0
    private let horizontalPadding: CGFloat = 0
    private let buttonSize: CGFloat = 44
    private let controlFont: Font = .title3
    private let titleFont: Font = .subheadline.weight(.medium)
    private let timeFont: Font = .caption
    #endif
}
