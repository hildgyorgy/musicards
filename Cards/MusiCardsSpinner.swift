//
//  MusiCardsSpinner.swift
//  MusiCards Release Viewer
//
//  Created by Hild György on 2026. 05. 14..
//

import SwiftUI

struct MusiCardsSpinner: View {
    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .tint(Color.blue)
            .frame(width: 40, height: 40)
#if os(iOS)
            .background(
                 Circle().fill(Color(white: 1.0).opacity(0.5))
            .shadow(color: Color.black.opacity(0.1), radius: 10, x: 2, y: 2))
#endif
    }
}
