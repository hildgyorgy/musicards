//
//  SearchCardHeaderView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 07..
//

import SwiftUI
import VisionKit

struct SearchCardHeaderView: View {
    @ObservedObject var viewModel: SearchViewModel
    let onTapCurrentArtist: () -> Void
    let onBarcodeScanned: (String) -> Void

    @FocusState private var isSearchFocused: Bool
    @State private var isShowingBarcodeScanner = false

    @Environment(\.colorScheme) private var colorScheme

    private var isReleaseGroupMode: Bool {
        if case .releaseGroupResults = viewModel.mode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.footnote)

                if isReleaseGroupMode {
                    Button {
                        viewModel.switchToSearch()
                        isSearchFocused = true
                    } label: {
                        HStack {
                            Text("New search")
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                } else {
                    TextField("Artist, release", text: $viewModel.searchQuery)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled(true)
                        .keyboardType(.default)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
                        .focused($isSearchFocused)

                    if !viewModel.searchQuery.isEmpty {
                        Button {
                            viewModel.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }

                Button {
                    isShowingBarcodeScanner = true
                } label: {
                    Image(systemName: "barcode.viewfinder")
                        .foregroundStyle(.tint)
                        .font(.callout)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(
                        colorScheme == .dark
                        ? DeckStyle.boxBackgroundDark
                        : DeckStyle.boxBackgroundLight
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                colorScheme == .dark
                                ? DeckStyle.strokeDark
                                : DeckStyle.strokeLight,
                                lineWidth: 0.5
                            )
                    )
            )

            Spacer().frame(height: 32)

            if isReleaseGroupMode {
                Text(viewModel.displayTitle)
                    .font(.title.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Button {
                    onTapCurrentArtist()
                } label: {
                    Text(viewModel.displayArtist)
                        .font(.body)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .onChange(of: viewModel.searchQuery) { _, _ in
            viewModel.queryDidChange()
        }
        .sheet(isPresented: $isShowingBarcodeScanner) {
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                BarcodeScannerView { code in
                    isShowingBarcodeScanner = false
                    onBarcodeScanned(code)
                }
            } else {
                VStack(spacing: 16) {
                    Text("Barcode scanning is not available on this device.")
                        .multilineTextAlignment(.center)

                    Button("Close") {
                        isShowingBarcodeScanner = false
                    }
                }
                .padding()
            }
        }
    }
}
