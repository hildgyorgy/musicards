//
//  NowPlayingIndicator.swift
//  MusiCards
//

import SwiftUI

struct NowPlayingIndicator: View {
    let isAnimating: Bool

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 0.16,
                paused: !isAnimating
            )
        ) { context in
            let phase = Int(
                context.date.timeIntervalSinceReferenceDate * 6
            )

            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(Color.primary)
                        .frame(
                            width: 3,
                            height: barHeight(index: index, phase: phase)
                        )
                }
            }
            .frame(width: 16, height: 18)
        }
        .allowsHitTesting(false)
    }

    private func barHeight(index: Int, phase: Int) -> CGFloat {
        guard isAnimating else {
            return [8, 15, 11][index]
        }

        let heights: [[CGFloat]] = [
            [7, 15, 10],
            [12, 8, 16],
            [16, 12, 7],
            [9, 16, 12],
        ]
        return heights[phase % heights.count][index]
    }
}
