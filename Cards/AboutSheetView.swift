//
//  AboutSheetView.swift
//  MusiCards Release Viewer
//
//  Created by Hild György on 2026. 05. 29..
//

import SwiftUI

#if os(macOS)
struct AboutSheetView: View {
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AboutView()
                .frame(width: MacWindowMetrics.contentSize.width - 10)
                .frame(height: 160)
                .background {
                    if #available(macOS 26.0, *) {
                        Color.clear
                            .glassEffect(
                                .regular.interactive(),
                                in: RoundedRectangle(
                                    cornerRadius: AppStyle.cornerRadius,
                                    style: .continuous
                                )
                            )
                    } else {
                        RoundedRectangle(
                            cornerRadius: AppStyle.cornerRadius,
                            style: .continuous
                        )
                        .fill(.regularMaterial)
                        .overlay(
                            RoundedRectangle(
                                cornerRadius: AppStyle.cornerRadius,
                                style: .continuous
                            )
                            .stroke(
                                DeckStyle.strokeColor,
                                lineWidth: DeckStyle.strokeWidth
                            )
                        )
                    }
                }
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: AppStyle.cornerRadius,
                        style: .continuous
                    )
                )
                .shadow(
                    color: .black.opacity(0.35),
                    radius: 24,
                    x: 0,
                    y: 8
                )
        }
    }
}
#endif
