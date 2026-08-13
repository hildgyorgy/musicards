//
//  CollapsedPlayerBar.swift
//  MusiCards
//

import SwiftUI

#if os(macOS)
import AppKit
#endif

struct CollapsedPlayerBar: View {
    @ObservedObject var controller: PlaybackController
    let contentInset: CGFloat?
    let isPlaceholder: Bool

    @State private var scrubPosition: TimeInterval = 0
    @State private var isScrubbing = false

    init(
        controller: PlaybackController,
        contentInset: CGFloat? = nil,
        isPlaceholder: Bool = false
    ) {
        self.controller = controller
        self.contentInset = contentInset
        self.isPlaceholder = isPlaceholder
    }

    var body: some View {
        HStack(spacing: platformSpacing) {
            transportButton(
                systemName: "backward.end.fill",
                accessibilityLabel: "Previous track",
                isEnabled: !isPlaceholder && controller.hasPrevious
            ) {
                await controller.selectPrevious()
            }

            transportButton(
                systemName: isPlaceholder || controller.status.isPlaying
                    ? "pause.fill"
                    : "play.fill",
                accessibilityLabel: controller.status.isPlaying
                    ? "Pause"
                    : "Play",
                isEnabled: !isPlaceholder && controller.status != .loading
            ) {
                await controller.togglePlayback()
            }

            transportButton(
                systemName: "forward.end.fill",
                accessibilityLabel: "Next track",
                isEnabled: !isPlaceholder && controller.hasNext
            ) {
                await controller.selectNext()
            }
            .padding(.trailing, 14)

            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text(isPlaceholder ? "" : controller.currentItem?.track.title ?? "")
                        .font(titleFont)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    Text(isPlaceholder ? "0:00" : remainingTimeText)
                        .font(timeFont)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .allowsHitTesting(false)

                if isPlaceholder {
                    Capsule(style: .continuous)
                        .stroke(Color.secondary.opacity(0.65), lineWidth: 1)
                        .frame(height: idleSeekHeight)
                        .frame(height: seekHitHeight)
                } else {
                    interactiveSeekBar
                        .accessibilityLabel("Playback position")
                        .accessibilityValue(formatTime(displayedPosition))
                }
            }
        }
        .padding(.horizontal, contentInset ?? defaultHorizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityHidden(isPlaceholder)
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

    private var seekUpperBound: TimeInterval {
        max(duration ?? 0, 0.001)
    }

    private var displayedPosition: TimeInterval {
        isScrubbing ? scrubPosition : controller.position
    }

    private var seekProgress: CGFloat {
        guard seekUpperBound > 0 else { return 0 }
        return CGFloat(min(max(displayedPosition / seekUpperBound, 0), 1))
    }

    private var interactiveSeekBar: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)

            ZStack {
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.secondary.opacity(isScrubbing ? 0.30 : 0.20))

                    Capsule(style: .continuous)
                        .fill(Color.primary)
                        .frame(width: width * seekProgress)
                }
                .frame(height: isScrubbing ? activeSeekHeight : idleSeekHeight)
                .animation(.easeOut(duration: 0.12), value: isScrubbing)

                #if os(macOS)
                MacSeekInteractionView(
                    isEnabled: duration != nil,
                    onBegan: beginSeek,
                    onChanged: updateSeek,
                    onEnded: finishSeek
                )
                #else
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let fraction = normalizedFraction(
                                    x: value.location.x,
                                    width: width
                                )
                                if !isScrubbing {
                                    beginSeek(at: fraction)
                                } else {
                                    updateSeek(to: fraction)
                                }
                            }
                            .onEnded { value in
                                finishSeek(
                                    at: normalizedFraction(
                                        x: value.location.x,
                                        width: width
                                    )
                                )
                            }
                    )
                #endif
            }
        }
        .frame(height: seekHitHeight)
        .allowsHitTesting(duration != nil)
    }

    private func beginSeek(at fraction: CGFloat) {
        guard duration != nil else { return }
        isScrubbing = true
        updateSeek(to: fraction)
    }

    private func updateSeek(to fraction: CGFloat) {
        guard isScrubbing else { return }
        scrubPosition = TimeInterval(min(max(fraction, 0), 1)) * seekUpperBound
    }

    private func finishSeek(at fraction: CGFloat) {
        guard isScrubbing else { return }
        updateSeek(to: fraction)

        let requestedPosition = scrubPosition
        Task {
            await controller.seek(to: requestedPosition)
            isScrubbing = false
        }
    }

    private func normalizedFraction(x: CGFloat, width: CGFloat) -> CGFloat {
        min(max(x / max(width, 1), 0), 1)
    }

    private var remainingTimeText: String {
        guard let duration, duration > 0 else {
            return formatTime(controller.position)
        }
        return "−\(formatTime(max(duration - displayedPosition, 0)))"
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let seconds = max(Int(time.rounded(.down)), 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    #if os(macOS)
    private let platformSpacing: CGFloat = 0
    private let defaultHorizontalPadding: CGFloat = DeckStyle.contentHorizontalPadding
    private let buttonSize: CGFloat = 30
    private let controlFont: Font = .body
    private let titleFont: Font = .caption.weight(.medium)
    private let timeFont: Font = .caption
    private let seekHitHeight: CGFloat = 16
    private let idleSeekHeight: CGFloat = 3
    private let activeSeekHeight: CGFloat = 7
    #else
    private let platformSpacing: CGFloat = 0
    private let defaultHorizontalPadding: CGFloat = 0
    private let buttonSize: CGFloat = 44
    private let controlFont: Font = .title3
    private let titleFont: Font = .subheadline.weight(.medium)
    private let timeFont: Font = .caption
    private let seekHitHeight: CGFloat = 20
    private let idleSeekHeight: CGFloat = 3
    private let activeSeekHeight: CGFloat = 7
    #endif
}

#if os(macOS)
private struct MacSeekInteractionView: NSViewRepresentable {
    let isEnabled: Bool
    let onBegan: (CGFloat) -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void

    func makeNSView(context: Context) -> SeekInteractionNSView {
        let view = SeekInteractionNSView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: SeekInteractionNSView, context: Context) {
        update(nsView)
    }

    private func update(_ view: SeekInteractionNSView) {
        view.isEnabled = isEnabled
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
    }
}

private final class SeekInteractionNSView: NSView {
    var isEnabled = true
    var onBegan: ((CGFloat) -> Void)?
    var onChanged: ((CGFloat) -> Void)?
    var onEnded: ((CGFloat) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onBegan?(fraction(for: event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        onChanged?(fraction(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        onEnded?(fraction(for: event))
    }

    private func fraction(for event: NSEvent) -> CGFloat {
        let point = convert(event.locationInWindow, from: nil)
        return min(max(point.x / max(bounds.width, 1), 0), 1)
    }
}
#endif
