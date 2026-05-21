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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SafariView(url: url, onDismiss: { dismiss() })
    }
}
#endif
