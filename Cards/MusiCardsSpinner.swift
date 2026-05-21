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
            .frame(width: 44, height: 44)
             .background(
                 Circle().fill(Color(white: 1.0).opacity(0.5))
             .overlay(
                 Circle()
                     .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.1), radius: 10, x: 2, y: 2))
    }
}
