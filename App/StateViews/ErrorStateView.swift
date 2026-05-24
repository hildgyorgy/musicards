//
//  ErrorStateView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 18..
//

import SwiftUI

struct ErrorStateView: View {
    let title: String
    let subtitle: String
    let retryTitle: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.footnote)

            Text(subtitle)
                .font(.footnote)

            Button(retryTitle, action: onRetry)
                .font(.footnote.weight(.semibold))
                .padding(.top, 10)
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

extension ErrorStateView {
    static func searchRetry(_ action: @escaping () -> Void) -> ErrorStateView {
        ErrorStateView(
            title: "Couldn't reach MusicBrainz",
            subtitle: "Check your connection and try again",
            retryTitle: "Try again",
            onRetry: action
        )
    }

    static func releaseRetry(_ action: @escaping () -> Void) -> ErrorStateView {
        ErrorStateView(
            title: "Couldn't load release",
            subtitle: "Check your connection",
            retryTitle: "Try again",
            onRetry: action
        )
    }

    static func artistRetry(_ action: @escaping () -> Void) -> ErrorStateView {
        ErrorStateView(
            title: "Couldn't load artist",
            subtitle: "Check your connection",
            retryTitle: "Try again",
            onRetry: action
        )
    }
}
