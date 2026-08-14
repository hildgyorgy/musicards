//
//  LibraryConnectionView.swift
//  MusiCards
//

import SwiftUI

struct LibraryConnectionView: View {
    @ObservedObject var localLibrary: LocalLibraryStore
    let onConnectExisting: () -> Void
    let onCreateOrUpdateIndex: (() -> Void)?
    let onDisconnect: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    sectionTitle("MUSIC LIBRARY")
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .background(.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }

                if isConnected {
                    connectedSummary
                } else {
                    Text(disconnectedExplanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                action(
                    title: isConnected
                        ? "CHOOSE ANOTHER LIBRARY"
                        : "CONNECT EXISTING LIBRARY",
                    explanation: "Select a music folder that already contains library.json.",
                    primary: !isConnected,
                    action: onConnectExisting
                )

                #if os(macOS)
                if let onCreateOrUpdateIndex {
                    action(
                        title: "CREATE / UPDATE LIBRARY INDEX",
                        explanation: "Select your music folder. MusiCards scans its tags, creates library.json, and connects it automatically.",
                        primary: isConnected,
                        action: onCreateOrUpdateIndex
                    )
                }
                #else
                Text("To create or update library.json, use MusiCards for Mac in the same music folder, then connect that folder here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                #endif

                if isConnected {
                    Divider()
                    Button("DISCONNECT LIBRARY", role: .destructive) {
                        onDisconnect()
                    }
                    .font(.system(.footnote, design: .monospaced).weight(.semibold))
                    .tracking(1.5)
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }

                if let message = statusMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(
                            localLibrary.connectionErrorMessage == nil
                                ? .secondary : .red
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
        #if os(macOS)
        .frame(width: 480, height: 510)
        #else
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private var connectedSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("CONNECTED")

            if !localLibrary.folderNames.isEmpty {
                Text(localLibrary.folderNames.joined(separator: ", "))
                    .font(.headline)
            }

            let summary = localLibrary.summary
            if let total = summary.totalAlbumCount {
                Text("\(summary.identifiedAlbumCount) / \(total) albums identified as playable")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(summary.identifiedAlbumCount) albums identified as playable")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func action(
        title: String,
        explanation: String,
        primary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Button(action: action) {
                Text(title)
                    .font(.system(.footnote, design: .monospaced).weight(.semibold))
                    .tracking(1.5)
                    .foregroundStyle(
                        primary
                            ? (colorScheme == .dark ? Color.black : Color.white)
                            : Color.primary
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background {
                        Capsule(style: .continuous)
                            .fill(primary ? Color.primary : Color.primary.opacity(0.08))
                    }
            }
            .buttonStyle(.plain)
            .disabled(localLibrary.isScanning)

            Text(explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(.headline, design: .monospaced).weight(.semibold))
            .tracking(2)
    }

    private var isConnected: Bool {
        localLibrary.summary.folderCount > 0
            && localLibrary.connectionErrorMessage == nil
    }

    private var disconnectedExplanation: String {
        #if os(macOS)
        "Connect an indexed music folder, or prepare one here."
        #else
        "Connect an indexed music folder, or prepare one on a Mac."
        #endif
    }

    private var statusMessage: String? {
        localLibrary.connectionErrorMessage ?? (
            localLibrary.isScanning ? localLibrary.statusMessage : nil
        )
    }
}
