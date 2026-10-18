//
//  AboutSheetView.swift
//  MusiCards Release Viewer
//
//  Created by Hild György on 2026. 05. 29..
//

import SwiftUI

#if os(macOS)
struct AboutSheetView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            MusiCardsSettingsSheetHeader(title: "Help & support") {
                dismiss()
            }
            AboutView()
        }
        .frame(
            width: MacWindowMetrics.contentSize.width - 4,
            height: MacWindowMetrics.contentSize.height * 0.78
        )
    }
}
#endif
