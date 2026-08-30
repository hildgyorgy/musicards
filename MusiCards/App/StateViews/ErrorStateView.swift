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
    static func searchRetry(
        for error: Error,
        _ action: @escaping () -> Void
    ) -> ErrorStateView {
        switch musicBrainzErrorCategory(for: error) {
        case .connectivity:
            return ErrorStateView(
                title: "Couldn't reach MusicBrainz",
                subtitle: "Check your connection and try again",
                retryTitle: "Try again",
                onRetry: action
            )
        case .timeout:
            return ErrorStateView(
                title: "MusicBrainz request timed out",
                subtitle: "Please try again",
                retryTitle: "Try again",
                onRetry: action
            )
        case .rateLimited, .serverUnavailable:
            return ErrorStateView(
                title: "MusicBrainz is temporarily unavailable",
                subtitle: "Please try again shortly",
                retryTitle: "Try again",
                onRetry: action
            )
        case .httpFailure, .dataFailure, .invalidRequest, .unexpected, .cancelled:
            return ErrorStateView(
                title: "Couldn't load MusicBrainz results",
                subtitle: "Please try again",
                retryTitle: "Try again",
                onRetry: action
            )
        }
    }

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

    static func wikipediaRetry(
        for error: Error,
        _ action: @escaping () -> Void
    ) -> ErrorStateView {
        let subtitle: String
        switch musicBrainzErrorCategory(for: error) {
        case .connectivity:
            subtitle = "Check your connection and try again"
        case .timeout:
            subtitle = "The request timed out"
        case .rateLimited, .serverUnavailable:
            subtitle = "The service is temporarily unavailable"
        case .cancelled, .httpFailure, .dataFailure, .invalidRequest, .unexpected:
            subtitle = "Please try again"
        }
        return ErrorStateView(
            title: "Couldn't load Wikipedia",
            subtitle: subtitle,
            retryTitle: "Try again",
            onRetry: action
        )
    }

    static func discographyRetry(
        for error: Error,
        _ action: @escaping () -> Void
    ) -> ErrorStateView {
        switch musicBrainzErrorCategory(for: error) {
        case .connectivity:
            return ErrorStateView(
                title: "Couldn't load discography",
                subtitle: "Check your connection and try again",
                retryTitle: "Try again",
                onRetry: action
            )
        case .timeout:
            return ErrorStateView(
                title: "Discography request timed out",
                subtitle: "Please try again",
                retryTitle: "Try again",
                onRetry: action
            )
        case .rateLimited, .serverUnavailable:
            return ErrorStateView(
                title: "MusicBrainz is temporarily unavailable",
                subtitle: "Please try again shortly",
                retryTitle: "Try again",
                onRetry: action
            )
        case .cancelled, .httpFailure, .dataFailure, .invalidRequest, .unexpected:
            return ErrorStateView(
                title: "Couldn't load discography",
                subtitle: "Please try again",
                retryTitle: "Try again",
                onRetry: action
            )
        }
    }
}
