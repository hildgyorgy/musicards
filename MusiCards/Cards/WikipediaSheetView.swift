//
//  WikipediaSheetView.swift
//  MusiCards Release Viewer
//
//  Created by Hild György on 2026. 05. 22..
//

import SwiftUI

#if os(macOS)
struct WikipediaSheetView: View {
    let url: URL
    let onDismiss: () -> Void

    private var sheetHeight: CGFloat {
        MacWindowMetrics.contentSize.height * 0.70
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            SafariView(url: url)
                .frame(width: MacWindowMetrics.contentSize.width - 10)
                .frame(height: sheetHeight)
                .clipShape(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                )
                .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 8)

            Button(action: onDismiss) {
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
