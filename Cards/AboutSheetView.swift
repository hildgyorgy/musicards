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
                .background(.regularMaterial)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: AppStyle.cornerRadius,
                        style: .continuous
                    )
                )
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
                .shadow(
                    color: .black.opacity(0.35),
                    radius: 24,
                    x: 0,
                    y: 8
                )

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(.regularMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 0, y: -30)
        }
    }
}
#endif
