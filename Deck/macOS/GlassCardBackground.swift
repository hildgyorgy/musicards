//
//  GlassCardBackground.swift
//

import SwiftUI

struct GlassCardBackground: View {
    var body: some View {
        RoundedRectangle(
            cornerRadius: DeckStyle.cornerRadius,
            style: .continuous
        )
        .fill(DeckStyle.glassMaterial)
        .overlay(
            RoundedRectangle(
                cornerRadius: DeckStyle.cornerRadius,
                style: .continuous
            )
            .fill(Color.white.opacity(0.08))
        )
        .overlay(
                    RoundedRectangle(
                        cornerRadius: DeckStyle.cornerRadius,
                        style: .continuous
                    )
                    .fill(
                        LinearGradient(
                            colors: [
                                DeckStyle.glassHighlightColor
                                    .opacity(DeckStyle.glassHighlightStrength),

                                DeckStyle.glassMidColor
                                    .opacity(DeckStyle.glassMidStrength),

                                DeckStyle.glassBottomColor
                                    .opacity(DeckStyle.glassBottomStrength)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
        .overlay(
            RoundedRectangle(
                cornerRadius: DeckStyle.cornerRadius,
                style: .continuous
            )
            .strokeBorder(
                Color.white.opacity(DeckStyle.outerStrokeStrength),
                lineWidth: DeckStyle.strokeWidth
            )
        )
    }
}
