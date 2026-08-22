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
        MusiCardsPanelShell(onDismiss: onDismiss) {
            AboutView()
        }
    }
}
#endif
